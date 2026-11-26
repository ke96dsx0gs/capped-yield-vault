// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {CappedVault} from "../src/CappedVault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

contract CappedVaultTest is Test {
    MockERC20 internal asset;
    CappedVault internal vault;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal treasury = address(0xFEE);

    uint256 internal constant CAP = 1_000_000e18;

    function setUp() public {
        asset = new MockERC20("Mock USD", "mUSD", 18);
        vault = new CappedVault(IERC20(address(asset)), address(this), treasury, CAP, 1_000);
        asset.mint(alice, CAP);
        asset.mint(bob, CAP);
        vm.prank(alice);
        asset.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        asset.approve(address(vault), type(uint256).max);
    }

    function testDepositMintsProportionalShares() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1_000e18, alice);

        assertEq(shares, 1_000e18, "one-to-one on empty vault");
        assertEq(vault.totalAssets(), 1_000e18);
        assertEq(vault.balanceOf(alice), 1_000e18);
    }

    function testDepositRevertsAboveCap() public {
        vm.prank(alice);
        vault.deposit(CAP, alice);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CappedVault.CapExceeded.selector, uint256(1), uint256(0)));
        vault.deposit(1, bob);
    }

    function testMintRevertsAboveCap() public {
        vm.prank(alice);
        vault.deposit(CAP - 1e18, alice);

        vm.prank(bob);
        vm.expectRevert();
        vault.mint(2e18, bob);
    }

    function testRedeemReturnsAssetsAndBurnsShares() public {
        vm.prank(alice);
        vault.deposit(500e18, alice);

        vm.prank(alice);
        uint256 out = vault.redeem(200e18, alice, alice);

        assertEq(out, 200e18);
        assertEq(vault.balanceOf(alice), 300e18);
        assertEq(asset.balanceOf(alice), CAP - 300e18);
    }

    function testHarvestMintsFeesOnlyAboveHighWaterMark() public {
        vm.prank(alice);
        vault.deposit(1_000e18, alice);

        assertEq(vault.highWaterMark(), 1_000e18, "first deposit seeds the baseline");

        asset.mint(address(vault), 100e18); // simulate 10% yield

        (uint256 profit, uint256 feeShares) = vault.harvest();
        // 10% of 100e18 profit at a 10% fee = 10e18 assets, priced at 1.1 assets/share.
        assertEq(profit, 100e18);
        assertEq(feeShares, uint256(10e18) * 1_000e18 / 1_100e18);
        assertEq(vault.balanceOf(treasury), feeShares);
        assertEq(vault.highWaterMark(), 1_100e18);

        vault.harvest();
        assertEq(vault.balanceOf(treasury), feeShares, "no fee without new profit");
    }

    function testHarvestAfterLossChargesNoFeeUntilRecovery() public {
        vm.prank(alice);
        vault.deposit(1_000e18, alice);
        asset.mint(address(vault), 100e18);
        vault.harvest();

        uint256 feesAfterPeak = vault.balanceOf(treasury);

        asset.burn(address(vault), 150e18); // drawdown below HWM
        vault.harvest();
        assertEq(vault.balanceOf(treasury), feesAfterPeak, "fees stay flat through the loss");

        asset.mint(address(vault), 60e18);
        vault.harvest();
        assertEq(vault.balanceOf(treasury), feesAfterPeak, "still below the old peak");

        asset.mint(address(vault), 100e18);
        (uint256 profit, uint256 feeShares) = vault.harvest();
        assertGt(profit, 0);
        assertGt(feeShares, 0, "fees resume above the old peak");
    }

    function testWithdrawHandlesInfiniteAllowance() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(alice);
        vault.approve(bob, type(uint256).max);

        vm.prank(bob);
        vault.withdraw(10e18, bob, alice);

        assertEq(asset.balanceOf(bob), CAP + 10e18);
        assertEq(vault.allowance(alice, bob), type(uint256).max);
    }

    function testOnlyOwnerSetters() public {
        vm.prank(alice);
        vm.expectRevert(CappedVault.NotOwner.selector);
        vault.setCap(1);

        vault.setCap(0);
        assertEq(vault.cap(), uint256(0));

        vm.expectRevert(abi.encodeWithSelector(CappedVault.FeeTooHigh.selector, 2_001, 2_000));
        vault.setFee(2_001);
    }

    function testFuzzRoundTripNeverProfits(uint96 rawAssets) public {
        uint256 assets = bound(rawAssets, 1, CAP);
        vm.startPrank(alice);
        uint256 shares = vault.deposit(assets, alice);
        uint256 out = vault.redeem(shares, alice, alice);
        vm.stopPrank();

        assertEq(out, assets, "no fee, no yield: deposit then redeem is neutral");
    }
}
