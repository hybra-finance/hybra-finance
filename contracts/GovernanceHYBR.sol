// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IVotingEscrow.sol";
import "./interfaces/IVoter.sol";
import "./interfaces/IBribe.sol";
import "./interfaces/IRewardsDistributor.sol";
import "./interfaces/IGaugeManager.sol";
import {HybraTimeLibrary} from "./libraries/HybraTimeLibrary.sol";

/**
 * @title GovernanceHYBR (gHYBR)
 * @notice Auto-compounding staking token that locks HYBR as veHYBR and compounds rewards
 * @dev Implements transfer restrictions for new deposits and automatic reward compounding
 */
contract GovernanceHYBR is ERC20, Ownable, ReentrancyGuard {
    
    // Lock period for new deposits (configurable between 12-24 hours)
    uint256 public transferLockPeriod = 12 hours;
    uint256 public constant MIN_LOCK_PERIOD = 12 hours;
    uint256 public constant MAX_LOCK_PERIOD = 24 hours;
    
    // User deposit tracking for transfer locks
    struct UserLock {
        uint256 amount;
        uint256 unlockTime;
    }
    
    mapping(address => UserLock[]) public userLocks;
    mapping(address => uint256) public lockedBalance;
    
    // Core contracts
    address public immutable HYBR;
    address public immutable votingEscrow;
    address public voter;
    address public rewardsDistributor;
    address public gaugeManager;
    uint256 public veTokenId; // The veNFT owned by this contract
    
    // Auto-voting strategy
    bool public autoVotingEnabled;
    address public operator; // Address that can manage voting strategy
    address[] public defaultPools; // Default pools to vote for
    uint256[] public defaultWeights; // Default weights for pools
    uint256 public lastVoteEpoch; // Last epoch when we voted
    
    // Reward tracking
    uint256 public pendingPenaltyRewards; // Penalty rewards from rHYBR conversions
    uint256 public lastRebaseTime;
    uint256 public lastCompoundTime;
    
    // Swap configuration
    mapping(address => bool) public whitelistedAggregators;
    
    // Errors
    error AGGREGATOR_NOT_WHITELISTED(address aggregator);
    error AGGREGATOR_REVERTED(bytes returnData);
    error AMOUNT_OUT_TOO_LOW(uint256 actual);
    error FORBIDDEN_TOKEN(address token);
    error NOT_AUTHORIZED();
    
    // Events
    event Deposit(address indexed user, uint256 hybrAmount, uint256 sharesReceived);
    event Withdraw(address indexed user, uint256 shares, uint256 hybrAmount);
    event Compound(uint256 rewards, uint256 newTotalLocked);
    event PenaltyRewardReceived(uint256 amount);
    event TransferLockPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event AggregatorWhitelisted(address indexed aggregator, bool whitelisted);
    event NativeDEXUpdated(address oldDEX, address newDEX);
    event SwappedToHYBR(address indexed operator, address tokenIn, uint256 amountIn, uint256 hybrOut);
    event VoterSet(address voter);
    event EmergencyUnlock(address indexed user);
    event AutoVotingEnabled(bool enabled);
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);
    event DefaultVotingStrategyUpdated(address[] pools, uint256[] weights);
    event AutoVoteExecuted(uint256 epoch, address[] pools, uint256[] weights);
       /**
     * @notice Swap parameters for aggregator calls
     */
    struct SwapParams {
        address aggregator;     // Aggregator contract address
        address tokenIn;        // Input token address
        uint256 amountIn;       // Input token amount
        uint256 minAmountOut;   // Minimum HYBR expected
        bytes callData;         // Aggregator call data
    }
    
  
    constructor(
        address _HYBR,
        address _votingEscrow
    ) ERC20("Governance HYBR", "gHYBR") {
        require(_HYBR != address(0), "Invalid HYBR");
        require(_votingEscrow != address(0), "Invalid VE");
        
        HYBR = _HYBR;
        votingEscrow = _votingEscrow;
        lastRebaseTime = block.timestamp;
        lastCompoundTime = block.timestamp;
        operator = msg.sender; // Initially set deployer as operator
        autoVotingEnabled = true; // Enable auto-voting by default
    }
    
    
    function setRewardsDistributor(address _rewardsDistributor) external onlyOwner {
        require(_rewardsDistributor != address(0), "Invalid rewards distributor");
        rewardsDistributor = _rewardsDistributor;
    }
    
    function setGaugeManager(address _gaugeManager) external onlyOwner {
        require(_gaugeManager != address(0), "Invalid gauge manager");
        gaugeManager = _gaugeManager;
    }

    
      /**
     * @notice Modifier to check authorization (owner or operator)
     */
    modifier onlyOperator() {
        if (msg.sender != operator) {
            revert NOT_AUTHORIZED();
        }
        _;
    }
    /**
     * @notice Deposit HYBR and receive gHYBR shares
     * @param amount Amount of HYBR to deposit
     * @param recipient Recipient of gHYBR shares
     */
    function deposit(uint256 amount, address recipient) external nonReentrant {
        require(amount > 0, "Zero amount");
        recipient = recipient == address(0) ? msg.sender : recipient;
        
        // Transfer HYBR from user first
        IERC20(HYBR).transferFrom(msg.sender, address(this), amount);
        
        // Initialize veNFT on first deposit
        if (veTokenId == 0) {
            _initializeVeNFT(amount);
        } else {
            // Add to existing veNFT
            IERC20(HYBR).approve(votingEscrow, amount);
            IVotingEscrow(votingEscrow).deposit_for(veTokenId, amount);
            
            // Extend lock to maximum duration
            uint256 maxLockTime = block.timestamp + HybraTimeLibrary.MAX_LOCK_DURATION;
            IVotingEscrow(votingEscrow).increase_unlock_time_for(veTokenId, maxLockTime);
        }
        
        // Calculate shares to mint based on current totalAssets
        uint256 shares = _calculateShares(amount);
        
        // Mint gHYBR shares
        _mint(recipient, shares);
        
        // Add transfer lock for recipient
        _addTransferLock(recipient, shares);
        
        emit Deposit(msg.sender, amount, shares);
    }


    /**
     * @notice Internal function to initialize veNFT on first deposit
     */
    function _initializeVeNFT(uint256 initialAmount) internal {
        // Create max lock with the initial deposit amount
        IERC20(HYBR).approve(votingEscrow, type(uint256).max);
        uint256 lockTime = HybraTimeLibrary.MAX_LOCK_DURATION;
        
        // Create lock with initial amount
        veTokenId = IVotingEscrow(votingEscrow).create_lock_for(initialAmount, lockTime, address(this));
        
    }
    
    /**
     * @notice Calculate shares to mint based on deposit amount
     */
    function _calculateShares(uint256 amount) internal view returns (uint256) {
        uint256 _totalSupply = totalSupply();
        uint256 _totalAssets = totalAssets();
        if (_totalSupply == 0 || _totalAssets == 0) {
            return amount;
        }
        return (amount * _totalSupply) / _totalAssets;
    }
    
    /**
     * @notice Calculate HYBR value of shares
     */
    function calculateAssets(uint256 shares) public view returns (uint256) {
        uint256 _totalSupply = totalSupply();
        if (_totalSupply == 0) {
            return shares;
        }
        return (shares * totalAssets()) / _totalSupply;
    }

    
    /**
     * @notice Get total assets (HYBR) locked in veNFT
     */
    function totalAssets() public view returns (uint256) {
        if (veTokenId == 0) {
            return 0;
        }
        return  IVotingEscrow(votingEscrow).balanceOfNFT(veTokenId);
    }
    
    /**
     * @notice Add transfer lock for new deposits
     */
    function _addTransferLock(address user, uint256 amount) internal {
        uint256 unlockTime = block.timestamp + transferLockPeriod;
        userLocks[user].push(UserLock({
            amount: amount,
            unlockTime: unlockTime
        }));
        lockedBalance[user] += amount;
    }
    


    /**
     * @notice Preview available balance (total - currently locked)
     * @param user The user address to check
     * @return available The current available balance for transfer
     */
    function previewAvailable(address user) external view returns (uint256 available) {
        uint256 totalBalance = balanceOf(user);
        uint256 currentLocked = 0;
        
        UserLock[] storage arr = userLocks[user];
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i].unlockTime > block.timestamp) {
                currentLocked += arr[i].amount;
            }
        }
        
        return totalBalance > currentLocked ? totalBalance - currentLocked : 0;
    }
    /**
     * @notice Clean expired locks and update locked balance
     * @param user The user address to clean locks for
     * @return freed The amount of tokens freed from expired locks
     */
    function _cleanExpired(address user) internal returns (uint256 freed) {
        UserLock[] storage arr = userLocks[user];
        uint256 len = arr.length;
        if (len == 0) return 0;

        uint256 write = 0;
        unchecked {
            for (uint256 i = 0; i < len; i++) {
                UserLock memory L = arr[i];
                if (L.unlockTime <= block.timestamp) {
                    freed += L.amount;
                } else {
                    if (write != i) arr[write] = L;
                    write++;
                }
            }
            if (freed > 0) {
                lockedBalance[user] -= freed;
            }
            while (arr.length > write) {
                arr.pop();
            }
        }
    }
    
    
    /**
     * @notice Override transfer to implement lock mechanism
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        super._beforeTokenTransfer(from, to, amount);
        
        if (from != address(0) && to != address(0)) { // Not mint or burn
            uint256 totalBalance = balanceOf(from);
            
            // Step 1: Check current available balance using cached lockedBalance
            uint256 currentAvailable = totalBalance > lockedBalance[from] ? totalBalance - lockedBalance[from] : 0;
            
            // Step 2: If current available >= amount, pass directly
            if (currentAvailable >= amount) {
                return;
            }
            
            // Step 3: Not enough, clean expired locks and recalculate
            _cleanExpired(from);
            uint256 finalAvailable = totalBalance > lockedBalance[from] ? totalBalance - lockedBalance[from] : 0;
            
            // Step 4: Check final available balance
            require(finalAvailable >= amount, "Tokens locked");
        }
    }
    
    /**
     * @notice Claim all rewards from voting and rebase
     */
    function claimRewards() external onlyOperator {
        require(voter != address(0), "Voter not set");
        require(rewardsDistributor != address(0), "Distributor not set");
              
        // Claim rebase rewards from RewardsDistributor
        IRewardsDistributor(rewardsDistributor).claim(veTokenId);
        
        // Claim bribes from voted pools
        address[] memory votedPools = IVoter(voter).poolVote(veTokenId);
        
        for (uint256 i = 0; i < votedPools.length; i++) {
            if (votedPools[i] != address(0)) {
                address gauge = IGaugeManager(gaugeManager).gauges(votedPools[i]);
                
                if (gauge != address(0)) {
                    // Prepare arrays for single bribe claim
                    address[] memory bribes = new address[](1);
                    address[][] memory tokens = new address[][](1);
                    
                    // Claim internal bribe (trading fees)
                    address internalBribe = IGaugeManager(gaugeManager).internal_bribes(gauge);
                    if (internalBribe != address(0)) {
                        uint256 tokenCount = IBribe(internalBribe).rewardsListLength();
                        if (tokenCount > 0) {
                            address[] memory bribeTokens = new address[](tokenCount);
                            for (uint256 j = 0; j < tokenCount; j++) {
                                bribeTokens[j] = IBribe(internalBribe).bribeTokens(j);
                            }
                            bribes[0] = internalBribe;
                            tokens[0] = bribeTokens;
                            // Call claimBribes for this single bribe
                            IGaugeManager(gaugeManager).claimBribes(bribes, tokens, veTokenId);
                        }
                    }
                    
                    // Claim external bribe
                    address externalBribe = IGaugeManager(gaugeManager).external_bribes(gauge);
                    if (externalBribe != address(0)) {
                        uint256 tokenCount = IBribe(externalBribe).rewardsListLength();
                        if (tokenCount > 0) {
                            address[] memory bribeTokens = new address[](tokenCount);
                            for (uint256 j = 0; j < tokenCount; j++) {
                                bribeTokens[j] = IBribe(externalBribe).bribeTokens(j);
                            }
                            bribes[0] = externalBribe;
                            tokens[0] = bribeTokens;
                            // Call claimBribes for this single bribe
                            IGaugeManager(gaugeManager).claimBribes(bribes, tokens, veTokenId);
                        }
                    }
                }
            }
        }
    }
    
 
    
    /**
     * @notice Swap tokens to HYBR via aggregator with slippage protection
     * @param _params Swap parameters including aggregator and calldata
     */
    function swapToHYBR(SwapParams calldata _params) external nonReentrant onlyOperator {
        // Validate aggregator is whitelisted
        if (!whitelistedAggregators[_params.aggregator]) {
            revert AGGREGATOR_NOT_WHITELISTED(_params.aggregator);
        }
        
        // Prevent swapping HYBR itself
        if (_params.tokenIn == HYBR) {
            revert FORBIDDEN_TOKEN(HYBR);
        }
        
        // Record balances before swap
        uint256 totalAssetsBeforeSwap = totalAssets();
        uint256 hybrBalanceBeforeSwap = IERC20(HYBR).balanceOf(address(this));
        
        // Approve aggregator to spend input token
        IERC20(_params.tokenIn).approve(_params.aggregator, _params.amountIn);
        
        // Execute swap via aggregator
        (bool success, bytes memory returnData) = _params.aggregator.call(_params.callData);
        if (!success) {
            revert AGGREGATOR_REVERTED(returnData);
        }
        
        // Validate results after swap
        uint256 totalAssetsAfterSwap = totalAssets();
        uint256 hybrBalanceAfterSwap = IERC20(HYBR).balanceOf(address(this));
        
        // Calculate HYBR received
        uint256 hybrReceived = hybrBalanceAfterSwap - hybrBalanceBeforeSwap;
        
        // Check slippage protection
        if (hybrReceived < _params.minAmountOut) {
            revert AMOUNT_OUT_TOO_LOW(hybrReceived);
        }
        
        // Ensure veNFT balance wasn't manipulated
        if (totalAssetsAfterSwap != totalAssetsBeforeSwap) {
            revert FORBIDDEN_TOKEN(HYBR);
        }
        
        emit SwappedToHYBR(msg.sender, _params.tokenIn, _params.amountIn, hybrReceived);
    }
    
    /**
     * @notice Compound HYBR balance into veNFT (restricted to authorized users)
     */
    function compound() external onlyOperator {
        
        // Get current HYBR balance
        uint256 hybrBalance = IERC20(HYBR).balanceOf(address(this));
        
        if (hybrBalance > 0) {
            // Lock all HYBR to existing veNFT
            IERC20(HYBR).approve(votingEscrow, hybrBalance);
            IVotingEscrow(votingEscrow).deposit_for(veTokenId, hybrBalance);
            
            // Extend lock to maximum duration
            uint256 maxLockTime = block.timestamp + HybraTimeLibrary.MAX_LOCK_DURATION;
            IVotingEscrow(votingEscrow).increase_unlock_time_for(veTokenId, maxLockTime);
            
            lastCompoundTime = block.timestamp;

            emit Compound(hybrBalance, totalAssets());
        }
    }
    
    /**
     * @notice Vote for gauges using the veNFT
     * @param _poolVote Array of pools to vote for
     * @param _weights Array of weights for each pool
     */
    function vote(address[] calldata _poolVote, uint256[] calldata _weights) external {
        require(msg.sender == owner() || msg.sender == operator, "Not authorized");
        require(voter != address(0), "Voter not set");
        
        IVoter(voter).vote(veTokenId, _poolVote, _weights);
        lastVoteEpoch = HybraTimeLibrary.epochStart(block.timestamp);
        
        // Update auto-voting settings if this was a manual vote and auto-voting is enabled
        if (autoVotingEnabled && msg.sender == operator) {
            _updateDefaultStrategy(_poolVote, _weights);
        }
    }
    
    /**
     * @notice Reset votes
     */
    function reset() external {
        require(msg.sender == owner() || msg.sender == operator, "Not authorized");
        require(voter != address(0), "Voter not set");
        
        IVoter(voter).reset(veTokenId);
        
        // Disable auto-voting when resetting
        if (autoVotingEnabled) {
            IVoter(voter).disableAutoVote(veTokenId);
            autoVotingEnabled = false;
            emit AutoVotingEnabled(false);
        }
    }
    
    /**
     * @notice Receive penalty rewards from rHYBR conversions
     */
    function getPenaltyReward(uint256 amount) external {
        pendingPenaltyRewards += amount;
        
        // Auto-compound penalty rewards to existing veNFT
        if (amount > 0) {
            IERC20(HYBR).approve(votingEscrow, amount);
            IVotingEscrow(votingEscrow).deposit_for(veTokenId, amount);
            
            // Extend lock to maximum duration
            uint256 maxLockTime = block.timestamp + HybraTimeLibrary.MAX_LOCK_DURATION;
            IVotingEscrow(votingEscrow).increase_unlock_time_for(veTokenId, maxLockTime);
            
            pendingPenaltyRewards = 0;
        }
        
        emit PenaltyRewardReceived(amount);
    }
    
    /**
     * @notice Extend veNFT lock to max duration
     */
    function extendLock() external {
        uint256 maxTime = HybraTimeLibrary.MAX_LOCK_DURATION;
        IVotingEscrow(votingEscrow).increase_unlock_time_for(veTokenId, maxTime);
    }
    
    /**
     * @notice Set the voter contract
     */
    function setVoter(address _voter) external onlyOwner {
        require(_voter != address(0), "Invalid voter");  
        voter = _voter;
        emit VoterSet(_voter);
    }
    
    /**
     * @notice Update transfer lock period
     */
    function setTransferLockPeriod(uint256 _period) external onlyOwner {
        require(_period >= MIN_LOCK_PERIOD && _period <= MAX_LOCK_PERIOD, "Invalid period");
        uint256 oldPeriod = transferLockPeriod;
        transferLockPeriod = _period;
        emit TransferLockPeriodUpdated(oldPeriod, _period);
    }
    
    /**
     * @notice Whitelist/unwhitelist aggregator for swaps
     * @param _aggregator Aggregator contract address
     * @param _whitelisted Whether to whitelist or not
     */
    function setAggregatorWhitelist(address _aggregator, bool _whitelisted) external onlyOwner {
        whitelistedAggregators[_aggregator] = _whitelisted;
        emit AggregatorWhitelisted(_aggregator, _whitelisted);
    }
    

    
    /**
     * @notice Emergency unlock for a user (owner only)
     */
    function emergencyUnlock(address user) external onlyOperator {
        delete userLocks[user];
        lockedBalance[user] = 0;
        emit EmergencyUnlock(user);
    }
    

    
  
    
    /**
     * @notice Get user's locks info
     */
    function getUserLocks(address user) external view returns (UserLock[] memory) {
        return userLocks[user];
    }
    
    
 
    
    /**
     * @notice Update default voting strategy
     */
    function _updateDefaultStrategy(address[] memory pools, uint256[] memory weights) internal {
        delete defaultPools;
        delete defaultWeights;
        
        for (uint256 i = 0; i < pools.length; i++) {
            defaultPools.push(pools[i]);
            defaultWeights.push(weights[i]);
        }
    }
    
    /**
     * @notice Set operator address
     */
    function setOperator(address _operator) external onlyOwner {
        require(_operator != address(0), "Invalid operator");
        address oldOperator = operator;
        operator = _operator;
        emit OperatorUpdated(oldOperator, _operator);
    }
    


    /**
     * @notice Get the current exchange rate (HYBR per gHYBR)
     */
    function exchangeRate() external view returns (uint256) {
        uint256 _totalSupply = totalSupply();
        if (_totalSupply == 0) {
            return 1e18;
        }
        return (totalAssets() * 1e18) / _totalSupply;
    }
    
    /**
     * @notice Get veNFT lock end time
     */
    function getLockEndTime() external view returns (uint256) {
        if (veTokenId == 0) {
            return 0;
        }
        IVotingEscrow.LockedBalance memory locked = IVotingEscrow(votingEscrow).locked(veTokenId);
        return uint256(locked.end);
    }
    

    
    /**
     * @notice Check if gHYBR should vote this epoch
     */
    function shouldVoteThisEpoch() external view returns (bool) {
        if (!autoVotingEnabled || voter == address(0) || veTokenId == 0 || defaultPools.length == 0) {
            return false;
        }
        
        uint256 currentEpoch = HybraTimeLibrary.epochStart(block.timestamp);
        if (lastVoteEpoch >= currentEpoch) {
            return false; // Already voted
        }
        
        // Check if we're in voting window
        return block.timestamp > HybraTimeLibrary.epochVoteStart(block.timestamp);
    }
}