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
import {HybraTimeLibrary} from "./libraries/HybraTimeLibrary.sol";

interface IgHYBR {
    function deposit(uint256 amount, address recipient) external;
    function getPenaltyReward(uint256 amount) external;
}

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
    
    // Rate bounds (in basis points, 10000 = 100%)
    uint256 public minConversionRate = 7000; // 70% minimum (highest penalty)
    uint256 public maxConversionRate = 9000; // 90% maximum (lowest penalty)
    
    // Recovery parameters (adjustable)
    uint256 public recoveryEpochs = 4; // Number of epochs to fully recover
    uint256 public penaltyImpactBeta = 2; // Sensitivity to redemption amount (higher = less sensitive)
    
    // Decay parameters
    uint256 public decayHalfLife = 12 hours; // Half-life for rate decay (adjustable)
    uint256 public epochDuration = 1 weeks; // Production: 1 week, Test: 30 minutes
    
    // Constants
    uint256 public constant RATE_PRECISION = 10000;
    uint256 public constant BASIS = 10000;
    uint256 private constant PRECISION = 1e18;
    
    // ========== Dynamic Rate State ==========
    
    // Current effective conversion rate for HYBR redemptions
    uint256 public currentConversionRate;
    
    // Base rate that gets adjusted by redemptions
    uint256 public baseConversionRate;
    
    // Tracking redemption activity
    uint256 public lastRedemptionTime;
    uint256 public lastRateUpdateTime;
    
    // Cross-epoch tracking
    uint256 public cumulativeRedemptionImpact; // Accumulated impact from all redemptions
    uint256 public lastEpochWithRedemption; // Last epoch when someone redeemed to HYBR
    uint256 public currentEpoch;
    
    // Penalty collection
    uint256 public pendingRebase;
    
    // ========== External Contracts ==========
    address public immutable HYBR;
    address public gHYBR;
    address public immutable votingEscrow;
    address public minter; // GaugeManager or other emission controller
    address public gaugeManager; // GaugeManager to check gauge addresses
    address public rewardsDistributor; // RewardsDistributor for veNFT holder rewards
    address public VOTER; // Voter contract
    uint256 public lastDistributedPeriod;
    
    // ========== Events ==========
    event Transfer(address indexed from, address indexed to, uint256 value);
    event ConvertToHYBR(address indexed user, uint256 rHYBRAmount, uint256 HYBRReceived, uint256 penalty, uint256 effectiveRate);
    event ConvertToGHYBR(address indexed user, uint256 rHYBRAmount, uint256 gHYBRReceived);
    event ConvertToVeHYBR(address indexed user, uint256 rHYBRAmount, uint256 tokenId, uint256 lockTime);
    event RateUpdated(uint256 oldRate, uint256 newRate, string reason);
    event GHYBRSet(address indexed gHYBR);
    event ConversionRateBoundsUpdated(uint256 oldMinRate, uint256 oldMaxRate, uint256 newMinRate, uint256 newMaxRate);
    event RecoveryParametersUpdated(uint256 newRecoveryEpochs, uint256 newPenaltyBeta, uint256 newDecayHalfLife);
    event Converted(address indexed user, uint256 amount);
    event Rebase(address indexed caller, uint256 amount);
    event EpochUpdated(uint256 oldEpoch, uint256 newEpoch);
    
    // ========== Errors ==========
    error ZeroAmount();
    error InvalidAddress();
    error NotMinter();
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
        
        // Set epoch duration based on environment
        epochDuration = HybraTimeLibrary.WEEK;
        
        // Initialize rates
        currentConversionRate = maxConversionRate; // Start at maximum (most favorable)
        baseConversionRate = maxConversionRate;
        lastRateUpdateTime = block.timestamp;
        lastRedemptionTime = block.timestamp;
        currentEpoch = _getCurrentEpoch();
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
     * @param conversionType Type of conversion
     */
    function redeem(uint256 amount, RedeemType conversionType) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();
        
        // Update epoch if needed
        _updateEpoch();
        
        // Burn rHYBR first
        _burn(msg.sender, amount);
        
        if (conversionType == RedeemType.TO_HYBR) {
            _redeemToHYBR(amount);
        } else if (conversionType == RedeemType.TO_VEHYBR) {
            _redeemToVeHYBR(amount);
        } else if (conversionType == RedeemType.TO_GHYBR) {
            _redeemToGHYBR(amount);
        } else {
            revert InvalidRedeemType();
        }
    }
    
    /**
     * @notice Convert to HYBR with dynamic penalty
     * @dev Penalty increases with usage, recovers over time
     */
    function _redeemToHYBR(uint256 amount) internal {
        // Update the conversion rate based on time elapsed
        _updateConversionRate();
        
        // Calculate effective rate for this specific redemption amount
        uint256 effectiveRate = _calculateEffectiveRate(amount);
        
        uint256 hybrAmount = (amount * effectiveRate) / RATE_PRECISION;
        uint256 penalty = amount - hybrAmount;
        
        // Apply the redemption impact to lower future rates
        _applyRedemptionImpact(amount);
        
        // Transfer HYBR to user
        IERC20(HYBR).transfer(msg.sender, hybrAmount);
        
        // Collect penalty for rebase
        pendingRebase += penalty;
        
        // Record this redemption
        lastRedemptionTime = block.timestamp;
        lastEpochWithRedemption = currentEpoch;
        
        emit ConvertToHYBR(msg.sender, amount, hybrAmount, penalty, effectiveRate);
    }
    
    /**
     * @notice Convert to veHYBR 1:1 (no penalty, encourages locking)
     */
    function _redeemToVeHYBR(uint256 amount) internal {
        IERC20(HYBR).approve(votingEscrow, amount);
        
        uint256 lockTime = HybraTimeLibrary.MAX_LOCK_DURATION;
        uint256 newTokenId = IVotingEscrow(votingEscrow).create_lock_for(amount, lockTime, msg.sender);
        
        emit ConvertToVeHYBR(msg.sender, amount, newTokenId, lockTime);
    }
    
    /**
     * @notice Convert to gHYBR 1:1 (no penalty, encourages staking)
     */
    function _redeemToGHYBR(uint256 amount) internal {
        if (gHYBR == address(0)) revert InvalidAddress();
        
        IERC20(HYBR).approve(gHYBR, amount);
        IgHYBR(gHYBR).deposit(amount, msg.sender);
        
        emit ConvertToGHYBR(msg.sender, amount, amount);
    }
    
    // ========== Rate Calculation Functions ==========
    
    /**
     * @notice Update the conversion rate based on time elapsed since last redemption
     * @dev Rate recovers towards maximum over time when no HYBR redemptions occur
     */
    function _updateConversionRate() internal {
        uint256 epochsSinceRedemption = currentEpoch - lastEpochWithRedemption;
        
        if (epochsSinceRedemption > 0) {
            // Calculate recovery based on epochs without redemption
            uint256 recoveryAmount = _calculateRecovery(epochsSinceRedemption);
            
            uint256 oldRate = baseConversionRate;
            uint256 newRate = baseConversionRate + recoveryAmount;
            
            // Apply cumulative impact decay
            if (cumulativeRedemptionImpact > 0) {
                uint256 impactDecay = (cumulativeRedemptionImpact * epochsSinceRedemption) / (recoveryEpochs * 2);
                if (impactDecay > cumulativeRedemptionImpact) {
                    cumulativeRedemptionImpact = 0;
                } else {
                    cumulativeRedemptionImpact -= impactDecay;
                }
            }
            
            // Cap at maximum rate
            if (newRate > maxConversionRate) {
                newRate = maxConversionRate;
            }
            
            baseConversionRate = newRate;
            currentConversionRate = newRate;
            
            if (oldRate != newRate) {
                emit RateUpdated(oldRate, newRate, "Time-based recovery");
            }
        }
        
        lastRateUpdateTime = block.timestamp;
    }
    
    /**
     * @notice Calculate recovery amount based on epochs without redemption
     */
    function _calculateRecovery(uint256 epochsWithoutRedemption) internal view returns (uint256) {
        if (epochsWithoutRedemption >= recoveryEpochs) {
            // Full recovery
            return maxConversionRate - baseConversionRate;
        }
        
        // Partial recovery: linear interpolation
        uint256 totalRecoveryNeeded = maxConversionRate - baseConversionRate;
        return (totalRecoveryNeeded * epochsWithoutRedemption) / recoveryEpochs;
    }
    
    /**
     * @notice Calculate the effective rate for a specific redemption amount
     * @dev Larger redemptions get progressively worse rates
     */
    function _calculateEffectiveRate(uint256 redeemAmount) internal view returns (uint256) {
        // Start with the current base rate
        uint256 rate = baseConversionRate;
        
        // Apply cumulative impact from past redemptions
        if (cumulativeRedemptionImpact > 0) {
            uint256 impactReduction = (cumulativeRedemptionImpact * RATE_PRECISION) / (PRECISION);
            if (rate > impactReduction) {
                rate -= impactReduction;
            } else {
                rate = minConversionRate;
            }
        }
        
        // Calculate immediate impact of this redemption
        if (totalSupply > 0) {
            uint256 redemptionFraction = (redeemAmount * PRECISION) / totalSupply;
            uint256 immediateImpact = redemptionFraction / (penaltyImpactBeta * PRECISION / RATE_PRECISION);
            
            if (rate > immediateImpact) {
                rate -= immediateImpact;
            } else {
                rate = minConversionRate;
            }
        }
        
        // Ensure rate stays within bounds
        if (rate < minConversionRate) {
            rate = minConversionRate;
        } else if (rate > maxConversionRate) {
            rate = maxConversionRate;
        }
        
        return rate;
    }
    
    /**
     * @notice Apply the impact of a redemption to future rates
     */
    function _applyRedemptionImpact(uint256 redeemAmount) internal {
        if (totalSupply > 0) {
            // Calculate the impact of this redemption
            uint256 redemptionFraction = (redeemAmount * PRECISION) / (totalSupply + redeemAmount);
            uint256 impact = redemptionFraction / penaltyImpactBeta;
            
            // Add to cumulative impact
            cumulativeRedemptionImpact += impact;
            
            // Update base rate immediately
            uint256 immediateReduction = (impact * RATE_PRECISION) / PRECISION;
            uint256 oldRate = baseConversionRate;
            
            if (baseConversionRate > minConversionRate + immediateReduction) {
                baseConversionRate -= immediateReduction;
            } else {
                baseConversionRate = minConversionRate;
            }
            
            currentConversionRate = baseConversionRate;
            
            emit RateUpdated(oldRate, baseConversionRate, "Redemption impact applied");
        }
    }
    
    // ========== Epoch Management ==========
    
    /**
     * @notice Update the current epoch if needed
     */
    function _updateEpoch() internal {
        uint256 newEpoch = _getCurrentEpoch();
        if (newEpoch > currentEpoch) {
            emit EpochUpdated(currentEpoch, newEpoch);
            currentEpoch = newEpoch;
        }
    }
    
    /**
     * @notice Get the current epoch number
     */
    function _getCurrentEpoch() internal view returns (uint256) {
        return block.timestamp / epochDuration;
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
        effectiveRate = _calculateEffectiveRate(rHYBRAmount);
        hybrAmount = (rHYBRAmount * effectiveRate) / RATE_PRECISION;
        penalty = rHYBRAmount - hybrAmount;
    }
    
    /**
     * @notice Get epochs since last HYBR redemption
     */
    function epochsSinceLastRedemption() external view returns (uint256) {
        uint256 current = _getCurrentEpoch();
        return current > lastEpochWithRedemption ? current - lastEpochWithRedemption : 0;
    }
    
    /**
     * @notice Get current effective conversion rate
     */
    function getEffectiveConversionRate(uint256 redeemAmount) external view returns (uint256) {
        return _calculateEffectiveRate(redeemAmount);
    }
    
    // ========== Admin Functions ==========
    
    /**
     * @notice Update recovery parameters (owner only)
     * @param _recoveryEpochs Number of epochs for full recovery
     * @param _penaltyBeta Sensitivity factor for penalties
     * @param _decayHalfLife Half-life for decay in seconds
     */
    function setRecoveryParameters(
        uint256 _recoveryEpochs,
        uint256 _penaltyBeta,
        uint256 _decayHalfLife
    ) external onlyOwner {
        require(_recoveryEpochs > 0 && _recoveryEpochs <= 52, "Invalid recovery epochs");
        require(_penaltyBeta > 0 && _penaltyBeta <= 100, "Invalid penalty beta");
        require(_decayHalfLife > 0, "Invalid decay half-life");
        
        recoveryEpochs = _recoveryEpochs;
        penaltyImpactBeta = _penaltyBeta;
        decayHalfLife = _decayHalfLife;
        
        emit RecoveryParametersUpdated(_recoveryEpochs, _penaltyBeta, _decayHalfLife);
    }
    
    /**
     * @notice Set conversion rate bounds (owner only)
     */
    function setConversionRateBounds(uint256 _minRate, uint256 _maxRate) external onlyOwner {
        require(_minRate >= 1000, "Min rate too low (min 10%)");
        require(_maxRate <= 10000, "Max rate too high (max 100%)");
        require(_minRate < _maxRate, "Invalid bounds");
        
        uint256 oldMinRate = minConversionRate;
        uint256 oldMaxRate = maxConversionRate;
        
        minConversionRate = _minRate;
        maxConversionRate = _maxRate;
        
        // Adjust current rates if needed
        if (currentConversionRate < _minRate) {
            currentConversionRate = _minRate;
            baseConversionRate = _minRate;
        } else if (currentConversionRate > _maxRate) {
            currentConversionRate = _maxRate;
            baseConversionRate = _maxRate;
        }
        
        emit ConversionRateBoundsUpdated(oldMinRate, oldMaxRate, _minRate, _maxRate);
    }
    
    /**
     * @notice Set epoch duration (owner only, mainly for testing)
     */
    function setEpochDuration(uint256 _epochDuration) external onlyOwner {
        require(_epochDuration >= 30 minutes, "Epoch too short");
        require(_epochDuration <= 4 weeks, "Epoch too long");
        epochDuration = _epochDuration;
    }
    
    /**
     * @notice Set the gHYBR contract address (owner only)
     */
    function setGHYBR(address _gHYBR) external onlyOwner {
        if (_gHYBR == address(0)) revert InvalidAddress();
        gHYBR = _gHYBR;
        emit GHYBRSet(_gHYBR);
    }
    
    /**
     * @notice Set gauge manager contract
     */
    function setGaugeManager(address _gaugeManager) external onlyOwner {
        gaugeManager = _gaugeManager;
    }
    
    /**
     * @notice Set minter contract (owner only)
     */
    function setMinter(address _minter) external onlyOwner {
        if (_minter == address(0)) revert InvalidAddress();
        minter = _minter;
    }

    /**
     * @notice Set rewards distributor contract for veNFT holder rewards
     */
    function setRewardsDistributor(address _rewardsDistributor) external onlyOwner {
        if (_rewardsDistributor == address(0)) revert InvalidAddress();
        rewardsDistributor = _rewardsDistributor;
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
    
    function rebase() external whenNotPaused {
        if (msg.sender != minter) revert NotMinter();

        uint256 period = HybraTimeLibrary.epochStart(block.timestamp);
        if (period > lastDistributedPeriod && pendingRebase > 0) {
            lastDistributedPeriod = period;
            uint256 _temp = pendingRebase;
            pendingRebase = 0;

            // Send rebase rewards to RewardsDistributor for veNFT holders
            if (rewardsDistributor != address(0)) {
                IERC20(HYBR).transfer(rewardsDistributor, _temp);
            }

            emit Rebase(msg.sender, _temp);
        }
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