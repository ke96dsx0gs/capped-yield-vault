// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Minimal ERC-20 used for vault shares.
/// @dev Deliberately small: no hooks, no permit. Callers that need either should
/// wrap the vault rather than extend share accounting here.
abstract contract ERC20 {
    error InsufficientBalance(address account, uint256 balance, uint256 needed);
    error InsufficientAllowance(address owner, address spender, uint256 allowance, uint256 needed);
    error ZeroAddress();
    error EmptyName();

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    string public name;
    string public symbol;
    uint8 public immutable decimals;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        if (bytes(name_).length == 0) revert EmptyName();
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        uint256 balance = balanceOf[from];
        if (balance < amount) revert InsufficientBalance(from, balance, amount);
        unchecked {
            balanceOf[from] = balance - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _spendAllowance(address owner_, address spender, uint256 amount) internal {
        uint256 allowed = allowance[owner_][spender];
        if (allowed == type(uint256).max) return;
        if (allowed < amount) revert InsufficientAllowance(owner_, spender, allowed, amount);
        unchecked {
            allowance[owner_][spender] = allowed - amount;
        }
        emit Approval(owner_, spender, allowed - amount);
    }

    function _mint(address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        totalSupply += amount;
        unchecked {
            balanceOf[to] += amount;
        }
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        uint256 balance = balanceOf[from];
        if (balance < amount) revert InsufficientBalance(from, balance, amount);
        unchecked {
            balanceOf[from] = balance - amount;
            totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }
}
