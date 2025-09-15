// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface IRHYBR {
    // Enums
    enum RedeemType {
        TO_HYBR,        // 0: Convert to HYBR with penalty (70%-90% rate)
        TO_VEHYBR,      // 1: Convert to veHYBR 1:1 (max lock, new NFT)
        TO_GHYBR        // 2: Convert to gHYBR at current ratio
    }

    // Events
    event Transfer(address indexed from, address indexed to, uint256 value);
    event ConvertToHYBR(address indexed user, uint256 rHYBRAmount, uint256 HYBRReceived, uint256 penalty);
    event ConvertToGHYBR(address indexed user, uint256 rHYBRAmount, uint256 gHYBRReceived);
    event ConvertToVeHYBR(address indexed user, uint256 rHYBRAmount, uint256 tokenId, uint256 lockTime);
    event RateUpdated(uint256 oldRate, uint256 newRate);
    event MinterSet(address indexed oldMinter, address indexed newMinter);
    event GHYBRSet(address indexed gHYBR);
    event ConversionRateBoundsUpdated(uint256 oldMinRate, uint256 oldMaxRate, uint256 newMinRate, uint256 newMaxRate);
    event Converted(address indexed user, uint256 amount);

    // View functions
    function name() external pure returns (string memory);
    function symbol() external pure returns (string memory);
    function decimals() external pure returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    
    // Conversion rate parameters
    function minConversionRate() external view returns (uint256);
    function maxConversionRate() external view returns (uint256);
    function RATE_PRECISION() external pure returns (uint256);
    function RATE_INCREASE_PER_HOUR() external pure returns (uint256);
    function RATE_DECREASE_PER_CONVERSION() external pure returns (uint256);
    function MIN_DECREASE_PER_CONVERSION() external pure returns (uint256);
    
    // Dynamic rate state
    function currentConversionRate() external view returns (uint256);
    function lastConversionTime() external view returns (uint256);
    function lastRateUpdateTime() external view returns (uint256);
    
    // External contracts
    function HYBR() external view returns (address);
    function gHYBR() external view returns (address);
    function votingEscrow() external view returns (address);
    function minter() external view returns (address);
    function gaugeManager() external view returns (address);

    // Core functions
    function updateConversionRate() external;
    function depostionEmissionsToken(uint256 _amount) external;
    function withdraw(uint256 amount) external;
    function redeem(uint256 amount, RedeemType conversionType) external;
    function mint(address to, uint256 amount) external;
    
    // Transfer functions
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external pure returns (bool);
    function allowance(address owner, address spender) external pure returns (uint256);
    
    // Admin functions
    function setMinter(address _minter) external;
    function setGHYBR(address _gHYBR) external;
    function setConversionRateBounds(uint256 _minRate, uint256 _maxRate) external;
    function emergencyWithdraw(address token, uint256 amount) external;
    
    // Whitelist management
    function addExempt(address account) external;
    function removeExempt(address account) external;
    function addExemptTo(address account) external;
    function removeExemptTo(address account) external;
    function setGaugeManager(address _gaugeManager) external;
    function isExempt(address account) external view returns (bool);
    function isExemptTo(address account) external view returns (bool);

    // gHYBR interface functions (for compatibility)
    function deposit(uint256 amount, address recipient) external;
    function getPenaltyReward(uint256 amount) external;
    function rebase() external;
}