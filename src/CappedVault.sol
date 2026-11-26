// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "./lib/ERC20.sol";
import {IERC20} from "./interfaces/IERC20.sol";

/// @title CappedVault
/// @notice ERC-4626 style vault with a hard deposit cap and a performance fee
/// charged on the yield above the last high-water mark.
///
/// Invariants:
/// 1. `totalAssets() <= cap` whenever the cap is non-zero, checked at deposit time.
/// 2. `totalSupply > 0` implies `convertToAssets(previewRedeem(x)) <= x` for all x.
/// 3. Fees are only minted when `totalAssets()` exceeds `highWaterMark`.
/// 4. The share price can never be moved by the owner: only `cap`, `feeBps`,
///    `feeRecipient` and ownership are mutable.
///
/// Roles: `owner` sets cap and fee, harvests, and is the only address that can
/// rotate `feeRecipient`. Depositors are permissionless.
///
/// Upgrade path: the contract is not proxied. Migration is cap -> 0, withdraw,
/// redeploy, and re-deposit; the cap exists so a strategy change can be staged.
contract CappedVault is ERC20 {
    error NotOwner();
    error CapExceeded(uint256 requested, uint256 available);
    error FeeTooHigh(uint256 requestedBps, uint256 maxBps);
    error ZeroAssets();
    error ZeroShares();
    error EmptyHighWaterMark();

    event CapUpdated(uint256 cap);
    event FeeUpdated(uint256 feeBps);
    event FeeRecipientUpdated(address recipient);
    event OwnershipTransferred(address indexed from, address indexed to);
    event Harvested(uint256 profit, uint256 feeShares);

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_FEE_BPS = 2_000;

    IERC20 public immutable asset;
    address public owner;
    address public feeRecipient;

    /// @notice Deposit ceiling in asset units. Zero means uncapped.
    uint256 public cap;
    /// @notice Performance fee in basis points, applied to profit above the HWM.
    uint256 public feeBps;
    /// @notice Highest `totalAssets()` seen at a harvest.
    uint256 public highWaterMark;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(IERC20 asset_, address owner_, address feeRecipient_, uint256 cap_, uint256 feeBps_)
        ERC20("Capped Yield Vault", "cyv", _readDecimals(asset_))
    {
        if (address(asset_) == address(0) || owner_ == address(0) || feeRecipient_ == address(0)) {
            revert ZeroAddress();
        }
        _checkFee(feeBps_);
        asset = asset_;
        owner = owner_;
        feeRecipient = feeRecipient_;
        cap = cap_;
        feeBps = feeBps_;
        highWaterMark = 0;
    }

    // ---------------------------------------------------------------------
    // ERC-4626 accounting
    // ---------------------------------------------------------------------

    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return _toShares(assets, totalSupply, totalAssets(), false);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return _toAssets(shares, totalSupply, totalAssets(), false);
    }

    function maxDeposit(address) public view returns (uint256) {
        if (cap == 0) return type(uint256).max;
        uint256 held = totalAssets();
        return held >= cap ? 0 : cap - held;
    }

    function maxMint(address) public view returns (uint256) {
        uint256 free = maxDeposit(address(0));
        if (free == type(uint256).max) return free;
        return _toShares(free, totalSupply, totalAssets(), false);
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return _toShares(assets, totalSupply, totalAssets(), false);
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        return _toAssets(shares, totalSupply, totalAssets(), true);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return _toShares(assets, totalSupply, totalAssets(), true);
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return _toAssets(shares, totalSupply, totalAssets(), false);
    }

    // ---------------------------------------------------------------------
    // Entry points
    // ---------------------------------------------------------------------

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        if (assets == 0) revert ZeroAssets();
        _checkCap(assets);
        shares = _toShares(assets, totalSupply, totalAssets(), false);
        if (shares == 0) revert ZeroShares();
        asset.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        _seedHighWaterMark(shares);
    }

    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        if (shares == 0) revert ZeroShares();
        assets = _toAssets(shares, totalSupply, totalAssets(), true);
        if (assets == 0) revert ZeroAssets();
        _checkCap(assets);
        asset.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        _seedHighWaterMark(shares);
    }

    function withdraw(uint256 assets, address receiver, address owner_) external returns (uint256 shares) {
        if (assets == 0) revert ZeroAssets();
        shares = _toShares(assets, totalSupply, totalAssets(), true);
        if (shares == 0) revert ZeroShares();
        if (msg.sender != owner_) _spendAllowance(owner_, msg.sender, shares);
        _burn(owner_, shares);
        asset.transfer(receiver, assets);
        _resetHighWaterMark();
    }

    function redeem(uint256 shares, address receiver, address owner_) external returns (uint256 assets) {
        if (shares == 0) revert ZeroShares();
        assets = _toAssets(shares, totalSupply, totalAssets(), false);
        if (assets == 0) revert ZeroAssets();
        if (msg.sender != owner_) _spendAllowance(owner_, msg.sender, shares);
        _burn(owner_, shares);
        asset.transfer(receiver, assets);
        _resetHighWaterMark();
    }

    // ---------------------------------------------------------------------
    // Owner
    // ---------------------------------------------------------------------

    function setCap(uint256 newCap) external onlyOwner {
        cap = newCap;
        emit CapUpdated(newCap);
    }

    function setFee(uint256 newFeeBps) external onlyOwner {
        _checkFee(newFeeBps);
        feeBps = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }

    function setFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        feeRecipient = recipient;
        emit FeeRecipientUpdated(recipient);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Mints fee shares for the profit accrued since the last high-water mark.
    /// @dev Permissionless-safe: only the owner calls it, and a loss simply leaves
    /// the HWM above `totalAssets()`, so no fee is charged on the recovery leg.
    function harvest() external onlyOwner returns (uint256 profit, uint256 feeShares) {
        uint256 held = totalAssets();
        if (held <= highWaterMark) return (0, 0);
        profit = held - highWaterMark;
        uint256 feeAssets = (profit * feeBps) / BPS;
        feeShares = _toShares(feeAssets, totalSupply, held, false);
        highWaterMark = held;
        if (feeShares > 0) _mint(feeRecipient, feeShares);
        emit Harvested(profit, feeShares);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    /// @dev The first deposit sets the baseline, otherwise the whole principal
    /// would be booked as profit at the next harvest.
    function _seedHighWaterMark(uint256 shares) private {
        if (shares == totalSupply) highWaterMark = totalAssets();
    }

    /// @dev Leaving supply at zero drops the baseline so the next cycle restarts.
    function _resetHighWaterMark() private {
        if (totalSupply == 0) highWaterMark = totalAssets();
    }

    function _checkCap(uint256 assets) private view {
        uint256 free = maxDeposit(msg.sender);
        if (assets > free) revert CapExceeded(assets, free);
    }

    function _checkFee(uint256 feeBps_) private pure {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh(feeBps_, MAX_FEE_BPS);
    }

    /// @dev Round up only where the vault must be made whole (mint, withdraw).
    function _toShares(uint256 assets, uint256 supply, uint256 held, bool roundUp) private pure returns (uint256) {
        if (supply == 0 || held == 0) return assets;
        uint256 numerator = assets * supply;
        return roundUp ? _ceilDiv(numerator, held) : numerator / held;
    }

    function _toAssets(uint256 shares, uint256 supply, uint256 held, bool roundUp) private pure returns (uint256) {
        if (supply == 0) return shares;
        uint256 numerator = shares * held;
        return roundUp ? _ceilDiv(numerator, supply) : numerator / supply;
    }

    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    function _readDecimals(IERC20 token) private view returns (uint8) {
        if (address(token) == address(0)) return 18;
        return token.decimals();
    }
}
