// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "../lib/ERC20.sol";

/// @notice Test token with an open faucet. Test-only, not deployed.
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_, decimals_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}
