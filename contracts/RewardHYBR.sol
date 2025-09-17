// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IVotingEscrow.sol";
import "./interfaces/IHybra.sol";
import "./interfaces/IGaugeManager.sol";
import "./interfaces/IVoter.sol";
import "./interfaces/IGHYBR.sol";
import {HybraTimeLibrary} from "./libraries/HybraTimeLibrary.sol";



/**
 * @title RewardHYBR (rHYBR)
 * @notice Non-transferable ERC20 reward token that can be converted to HYBR, gHYBR, or veHYBR
 * @dev Implements a dynamic conversion rate mechanism that encourages long-term locking
 * 
 * Key Features:
 * - Conversion to HYBR incurs dynamic penalty (increases with usage)
 * - Conversion to veHYBR/gHYBR is 1:1 (no penalty)
 * - Rate recovers over time when HYBR conversions are avoided
 * - Cross-epoch state persistence
 */
contract RewardHYBR is Ownable, ReentrancyGuard, Pausable {
    using EnumerableSet for EnumerableSet.AddressSet;
    
    // ========== Token Metadata ==========
    string public constant name = "Reward HYBR";
    string public constant symbol = "rHYBR";
    uint8 public constant decimals = 18;
    
    // ========== Balances ==========
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    
    // ========== Transfer Whitelist ==========
    EnumerableSet.AddressSet private exempt; // Addresses that can send rHYBR
    EnumerableSet.AddressSet private exemptTo; // Addresses that can receive rHYBR
    
    // ========== Dynamic Rate Configuration (Adjustable) ==========
    
    // Fixed conversion rate (controlled off-chain)
    uint256 public fixedConversionRate = 8000; // 80% fixed rate (20% penalty)
    uint256 public constant MIN_FIXED_RATE = 5000; // 50% minimum
    uint256 public constant MAX_FIXED_RATE = 10000; // 100% maximum (no penalty)
    
    // Constants
    uint256 public constant RATE_PRECISION = 10000;
    
    
    // ========== External Contracts ==========
    address public immutable HYBR;
    address public gHYBR;
    address public immutable votingEscrow;
    address public gaugeManager; // GaugeManager to check gauge addresses
    address public VOTER; // Voter contract
    
    // ========== Events ==========
    event Transfer(address indexed from, address indexed to, uint256 value);
    event RedeemToHYBR(address indexed user, uint256 rHYBRAmount, uint256 HYBRReceived, uint256 penalty, uint256 effectiveRate);
    event RedeemToGHYBR(address indexed user, uint256 rHYBRAmount, uint256 gHYBRReceived);
    event RedeemToVeHYBR(address indexed user, uint256 rHYBRAmount, uint256 tokenId, uint256 lockTime);
    event FixedRateUpdated(uint256 oldRate, uint256 newRate, address indexed updater);
    event GHYBRSet(address indexed gHYBR);
    event Converted(address indexed user, uint256 amount);
    event Rebase(address indexed caller, uint256 amount);
    event EpochUpdated(uint256 oldEpoch, uint256 newEpoch);
    
    // ========== Errors ==========
    error ZeroAmount();
    error InvalidAddress();
    error InsufficientBalance();
    error InvalidRedeemType();
    error TransferNotAllowed();
    error ApprovalsNotSupported();
    
    // ========== Constructor ==========
    constructor(
        address _HYBR,
        address _votingEscrow
    ) {
        if (_HYBR == address(0) || _votingEscrow == address(0)) revert InvalidAddress();
        
        HYBR = _HYBR;
        votingEscrow = _votingEscrow;
        
    }
    
    // ========== Redemption Types ==========
    enum RedeemType {
        TO_HYBR,        // 0: Convert to HYBR with dynamic penalty
        TO_VEHYBR,      // 1: Convert to veHYBR 1:1 (no penalty)
        TO_GHYBR        // 2: Convert to gHYBR 1:1 (no penalty)
    }
    
    // ========== Main Functions ==========
    
    /**
     * @notice Unified conversion function for rHYBR
     * @param amount Amount of rHYBR to convert
     * @param redeemType Type of conversion
     */
    function redeem(uint256 amount, uint8 redeemType) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();

        // Burn rHYBR first
        _burn(msg.sender, amount);

        _redeem(amount, redeemType, msg.sender);
    }

    function redeemFor(uint256 amount, uint8 redeemType, address recipient) external nonReentrant whenNotPaused {
          // Burn rHYBR first
        if (amount == 0) revert ZeroAmount();
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();
        _burn(msg.sender, amount);
        _redeem(amount, redeemType, recipient);
    }

    function _redeem(uint256 amount, uint8 redeemType, address recipient) internal {
        if (redeemType == uint8(RedeemType.TO_HYBR)) {
            _redeemToHYBR(amount, recipient);
        } else if (redeemType == uint8(RedeemType.TO_VEHYBR)) {
            _redeemToVeHYBR(amount, recipient);
        } else if (redeemType == uint8(RedeemType.TO_GHYBR)) {
            _redeemToGHYBR(amount, recipient);
        } else {
            revert InvalidRedeemType();
        }
    }

    
    /**
     * @notice Convert to HYBR with dynamic penalty
     * @dev Penalty increases with usage, recovers over time
     */
    function _redeemToHYBR(uint256 amount, address recipient) internal {
        // Use fixed conversion rate
        uint256 effectiveRate = fixedConversionRate;

        uint256 hybrAmount = (amount * effectiveRate) / RATE_PRECISION;
        uint256 penalty = amount - hybrAmount;
        
        // Transfer HYBR to user
        IERC20(HYBR).transfer(recipient, hybrAmount);
        
        // Collect penalty for rebase
        IERC20(HYBR).transfer(gHYBR, penalty);

        require(penalty + hybrAmount == amount, "Penalty is not equal to amount");
        IGHYBR(gHYBR).receivePenaltyReward(penalty);
        // Record this redemption for epoch tracking
        
        emit RedeemToHYBR(recipient, amount, hybrAmount, penalty, effectiveRate);
    }
    
    /**
     * @notice Convert to veHYBR 1:1 (no penalty, encourages locking)
     */
    function _redeemToVeHYBR(uint256 amount, address recipient) internal {
        IERC20(HYBR).approve(votingEscrow, amount);
        
        uint256 lockTime = HybraTimeLibrary.MAX_LOCK_DURATION;
        uint256 newTokenId = IVotingEscrow(votingEscrow).create_lock_for(amount, lockTime, recipient);
        
        emit RedeemToVeHYBR(recipient, amount, newTokenId, lockTime);
    }
    
    /**
     * @notice Convert to gHYBR rate (no penalty, encourages staking)
     */
    function _redeemToGHYBR(uint256 amount, address recipient) internal {
        if (gHYBR == address(0)) revert InvalidAddress();
        
        IERC20(HYBR).approve(gHYBR, amount);
        IGHYBR(gHYBR).deposit(amount, recipient);
        
        emit RedeemToGHYBR(recipient, amount, amount);
    }
    

    
 
    
    // ========== View Functions ==========
    
    /**
     * @notice Preview redemption to HYBR
     * @param rHYBRAmount Amount to potentially redeem
     * @return hybrAmount Amount of HYBR that would be received
     * @return penalty Penalty amount
     * @return effectiveRate The rate that would be applied
     */
    function previewRedemption(uint256 rHYBRAmount) external view returns (
        uint256 hybrAmount,
        uint256 penalty,
        uint256 effectiveRate
    ) {
        effectiveRate = fixedConversionRate;
        hybrAmount = (rHYBRAmount * effectiveRate) / RATE_PRECISION;
        penalty = rHYBRAmount - hybrAmount;
    }
    
 

    // ========== Admin Functions ==========
    
    /**
     * @notice Set the gHYBR contract address (owner only)
     */
    function setGHYBR(address _gHYBR) external onlyOwner {
        if (_gHYBR == address(0)) revert InvalidAddress();
        gHYBR = _gHYBR;
        emit GHYBRSet(_gHYBR);
    }

    /**
     * @notice Set fixed conversion rate (off-chain controlled)
     * @param _rate New conversion rate in basis points (5000-10000)
     */
    function setFixedConversionRate(uint256 _rate) external onlyOwner {
        require(_rate >= MIN_FIXED_RATE && _rate <= MAX_FIXED_RATE, "Rate out of bounds");

        uint256 oldRate = fixedConversionRate;
        fixedConversionRate = _rate;

        emit FixedRateUpdated(oldRate, _rate, msg.sender);
    }


    /**
     * @notice Set gauge manager contract
     */
    function setGaugeManager(address _gaugeManager) external onlyOwner {
        gaugeManager = _gaugeManager;
    }
    
  

  
    
    // ========== Token Functions ==========
    
    function depostionEmissionsToken(uint256 _amount) external whenNotPaused {
        if (_amount == 0) revert ZeroAmount();
        IERC20(HYBR).transferFrom(msg.sender, address(this), _amount);
        _mint(msg.sender, _amount);
        emit Converted(msg.sender, _amount);
    }
    
    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
    }
    
    
    /**
     * @notice Internal mint function
     */
    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }
    
    /**
     * @notice Internal burn function
     */
    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }
    
    // ========== Transfer Functions (Restricted) ==========
    
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _transfer(from, to, amount);
        return true;
    }
    
    function _transfer(address from, address to, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        if (balanceOf[from] < amount) revert InsufficientBalance();
        
        // Check transfer permissions
        uint8 allowed = 0;
        if (_isExempted(from, to)) {
            allowed = 1;
        } else if (gaugeManager != address(0) && IGaugeManager(gaugeManager).isGauge(from)) {
            exempt.add(from);
            allowed = 1;
        }
        
        if (allowed != 1) revert TransferNotAllowed();
        
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
    
    function _isExempted(address from, address to) internal view returns (bool) {
        if (from == address(0) || to == address(0)) return true;
        if (exempt.contains(from)) return true;
        if (exemptTo.contains(to)) return true;
        return false;
    }
    
    // ========== Whitelist Management ==========
    
    function addExempt(address account) external onlyOwner {
        exempt.add(account);
    }
    
    function removeExempt(address account) external onlyOwner {
        exempt.remove(account);
    }
    
    function addExemptTo(address account) external onlyOwner {
        exemptTo.add(account);
    }
    
    function removeExemptTo(address account) external onlyOwner {
        exemptTo.remove(account);
    }
    
    function isExempt(address account) external view returns (bool) {
        return exempt.contains(account);
    }
    
    function isExemptTo(address account) external view returns (bool) {
        return exemptTo.contains(account);
    }
    
    // ========== Emergency Functions ==========
    
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(msg.sender, amount);
    }
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    // ========== Unsupported Functions ==========
    
    function approve(address, uint256) external pure returns (bool) {
        revert ApprovalsNotSupported();
    }
    
    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }
}