// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface IGHYBR {
    // Events
    event Deposit(address indexed user, address indexed recipient, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event PenaltyReward(uint256 amount);
    event Transfer(address indexed from, address indexed to, uint256 value);

    // View functions
    function name() external pure returns (string memory);
    function symbol() external pure returns (string memory);
    function decimals() external pure returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    
    // Core functions
    function deposit(uint256 amount, address recipient) external;
    function withdraw(uint256 amount) external;
    function getPenaltyReward(uint256 amount) external;
    
    // Transfer functions
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}