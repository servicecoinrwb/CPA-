/**
 *Submitted for verification at Arbiscan.io on 2026-04-07
*/

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title CPA Token
 * @notice Fixed-supply ERC-20 token on Arbitrum.
 *         1,000,000 CPA minted once to the deployer. No owner, no mint, no pause.
 */
contract CPA {
    // ── Metadata ──────────────────────────────────────────────────────────────
    string  public constant name     = "CPA";
    string  public constant symbol   = "CPA";
    uint8   public constant decimals = 18;

    // ── Supply ────────────────────────────────────────────────────────────────
    uint256 public constant totalSupply = 1_000_000 * 10 ** 18;

    // ── State ─────────────────────────────────────────────────────────────────
    mapping(address => uint256)                     public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // ── Events ────────────────────────────────────────────────────────────────
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ── Constructor ───────────────────────────────────────────────────────────
    constructor() {
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }

    // ── ERC-20 Core ───────────────────────────────────────────────────────────
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "CPA: insufficient allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    // ── Internal ──────────────────────────────────────────────────────────────
    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0),              "CPA: transfer to zero address");
        require(balanceOf[from] >= amount,     "CPA: insufficient balance");

        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        emit Transfer(from, to, amount);
    }
}
