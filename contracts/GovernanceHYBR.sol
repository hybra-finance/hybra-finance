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
import "./interfaces/ISwapper.sol";
import {HybraTimeLibrary} from "./libraries/HybraTimeLibrary.sol";

/**
 * @title GovernanceHYBR (gHYBR)
 * @notice Auto-compounding staking token that locks HYBR as veHYBR and compounds rewards
 * @dev Implements transfer restrictions for new deposits and automatic reward compounding
 */
contract GovernanceHYBR is ERC20, Ownable, ReentrancyGuard {
    
    // Lock period for new deposits (configurable between 12-24 hours)
    uint256 public transferLockPeriod = 24 hours;
    uint256 public constant MIN_LOCK_PERIOD = 1 minutes;
    uint256 public constant MAX_LOCK_PERIOD = 240 minutes;
    uint256 public head_not_withdraw_time = 1200; // 5days
    uint256 public tail_not_withdraw_time = 300; // 1day

    // Withdraw fee configuration (basis points, 10000 = 100%)
    uint256 public withdrawFee = 100; // 1% default fee
    uint256 public constant MIN_WITHDRAW_FEE = 10; // 0.1% minimum
    uint256 public constant MAX_WITHDRAW_FEE = 1000; // 10% maximum
    uint256 public constant BASIS = 10000;
    address public Team; // Address to receive fees
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
    address public operator; // Address that can manage voting strategy
    address[] public defaultPools; // Default pools to vote for
    uint256[] public defaultWeights; // Default weights for pools
    uint256 public lastVoteEpoch; // Last epoch when we voted
    
    // Reward tracking
    uint256 public lastRebaseTime;
    uint256 public lastCompoundTime;

    // Swap module
    ISwapper public swapper;

    // Errors
    error NOT_AUTHORIZED();
    
    // Events
    event Deposit(address indexed user, uint256 hybrAmount, uint256 sharesReceived);
    event Withdraw(address indexed user, uint256 shares, uint256 hybrAmount, uint256 fee);
    event Compound(uint256 rewards, uint256 newTotalLocked);
    event PenaltyRewardReceived(uint256 amount);
    event TransferLockPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event SwapperUpdated(address indexed oldSwapper, address indexed newSwapper);
    event VoterSet(address voter);
    event EmergencyUnlock(address indexed user);
    event AutoVotingEnabled(bool enabled);
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);
    event DefaultVotingStrategyUpdated(address[] pools, uint256[] weights);
    event AutoVoteExecuted(uint256 epoch, address[] pools, uint256[] weights);

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
            _extendLockToMax();
        }
        
        // Calculate shares to mint based on current totalAssets
        uint256 shares = calculateShares(amount);
        
        // Mint gHYBR shares
        _mint(recipient, shares);
        
        // Add transfer lock for recipient
        _addTransferLock(recipient, shares);
        
        emit Deposit(msg.sender, amount, shares);
    }

    /**
     * @notice Withdraw gHYBR shares and receive a new veNFT with proportional HYBR
     * @dev Creates new veNFT using multiSplit to maintain proportional ownership
     * @param shares Amount of gHYBR shares to burn
     * @return userTokenId The ID of the new veNFT created for the user
     */
    function withdraw(uint256 shares) external nonReentrant returns (uint256 userTokenId) {
        require(shares > 0, "Zero shares");
        require(balanceOf(msg.sender) >= shares, "Insufficient balance");
        require(veTokenId != 0, "No veNFT initialized");
        require(IVotingEscrow(votingEscrow).voted(veTokenId) == false, "Cannot withdraw yet");
        
        uint256 epochStart = HybraTimeLibrary.epochStart(block.timestamp);
        uint256 epochNext = HybraTimeLibrary.epochNext(block.timestamp);

        require(block.timestamp >= epochStart + head_not_withdraw_time && block.timestamp < epochNext - tail_not_withdraw_time, "Cannot withdraw yet");

        // Calculate proportional HYBR amount from veNFT
        uint256 hybrAmount = calculateAssets(shares);
        require(hybrAmount > 0, "No assets to withdraw");

        // Calculate fee amount (from the HYBR amount, not shares)
        uint256 feeAmount = 0;
        if (withdrawFee > 0) {
            feeAmount = (hybrAmount * withdrawFee) / BASIS;
        }

        // User receives amount minus fee
        uint256 userAmount = hybrAmount - feeAmount;
        require(userAmount > 0, "Amount too small after fee");

        // Get actual HYBR locked amount (not voting power)
        uint256 veBalance = totalAssets();
        require(hybrAmount <= veBalance, "Insufficient veNFT balance");

        uint256 remainingAmount = veBalance - userAmount - feeAmount;  
        require(remainingAmount >= 0, "Cannot withdraw entire veNFT");

        // Burn gHYBR shares (full amount)
        _burn(msg.sender, shares);

        // Use multiSplit to create two NFTs: one for user, one for contract
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = remainingAmount; // Amount staying with gHYBR 
        amounts[1] = userAmount;      // Amount going to user (after fee)
        amounts[2] = feeAmount;      // Amount going to fee recipient


        uint256[] memory newTokenIds = IVotingEscrow(votingEscrow).multiSplit(veTokenId, amounts);
    
        // Update contract's veTokenId to the first new token
        veTokenId = newTokenIds[0];
        userTokenId = newTokenIds[1];
        uint256 feeTokenId = newTokenIds[2];
        // Note: userTokenId is transferred to user, they can manage their own lock time
        IVotingEscrow(votingEscrow).safeTransferFrom(address(this), msg.sender, userTokenId);
        IVotingEscrow(votingEscrow).safeTransferFrom(address(this), Team, feeTokenId);
        emit Withdraw(msg.sender, shares, userAmount, feeAmount);
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
    function calculateShares(uint256 amount) public view returns (uint256) {
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
     * @dev Returns actual HYBR amount, not voting power
     */
    function totalAssets() public view returns (uint256) {
        if (veTokenId == 0) {
            return 0;
        }
        // Get actual locked HYBR amount, not voting power
        IVotingEscrow.LockedBalance memory locked = IVotingEscrow(votingEscrow).locked(veTokenId);
        return uint256(int256(locked.amount));
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
     * @notice Execute swap through the configured swapper module
     * @param _params Swap parameters for the swapper module
     */
    function executeSwap(ISwapper.SwapParams calldata _params) external nonReentrant onlyOperator {
        require(address(swapper) != address(0), "Swapper not set");

        // Get token balance before swap
        uint256 tokenBalance = IERC20(_params.tokenIn).balanceOf(address(this));
        require(tokenBalance >= _params.amountIn, "Insufficient token balance");

        // Approve swapper to spend tokens
        IERC20(_params.tokenIn).approve(address(swapper), _params.amountIn);

        // Execute swap through swapper module
        uint256 hybrReceived = swapper.swapToHYBR(_params);

        // Reset approval for safety
        IERC20(_params.tokenIn).approve(address(swapper), 0);

        // HYBR is now in this contract, ready for compounding
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
            _extendLockToMax();

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
        
    }
    
    /**
     * @notice Reset votes
     */
    function reset() external {
        require(msg.sender == owner() || msg.sender == operator, "Not authorized");
        require(voter != address(0), "Voter not set");
        
        IVoter(voter).reset(veTokenId);
    }
    
    /**
     * @notice Receive penalty rewards from rHYBR conversions
     */
    function receivePenaltyReward(uint256 amount) external {
        
        // Auto-compound penalty rewards to existing veNFT
        if (amount > 0) {
            IERC20(HYBR).approve(votingEscrow, amount);

            if(veTokenId == 0){
                _initializeVeNFT(amount);
            } else{
                IVotingEscrow(votingEscrow).deposit_for(veTokenId, amount);

                // Extend lock to maximum duration
                _extendLockToMax();
            }
        }
        
        emit PenaltyRewardReceived(amount);
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
     * @notice Set withdraw fee (in basis points)
     * @param _fee Fee amount (10-30 basis points)
     */
    function setWithdrawFee(uint256 _fee) external onlyOwner {
        require(_fee >= MIN_WITHDRAW_FEE && _fee <= MAX_WITHDRAW_FEE, "Invalid fee");
        withdrawFee = _fee;
    }


    function setHeadNotWithdrawTime(uint256 _time) external onlyOwner {
        head_not_withdraw_time = _time;
    }

    function setTailNotWithdrawTime(uint256 _time) external onlyOwner {
        tail_not_withdraw_time = _time;
    }
    
    /**
     * @notice Set the swapper module
     * @param _swapper Address of the swapper module
     */
    function setSwapper(address _swapper) external onlyOwner {
        require(_swapper != address(0), "Invalid swapper");
        address oldSwapper = address(swapper);
        swapper = ISwapper(_swapper);
        emit SwapperUpdated(oldSwapper, _swapper);
    }
    
    /**
     * @notice Set the team address
     */
    function setTeam(address _team) external onlyOwner {
        require(_team != address(0), "Invalid team");
        Team = _team;
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
     * @notice Internal helper to safely extend lock to maximum duration
     * @dev Calculates exact duration needed to reach max allowed unlock time
     */
    function _extendLockToMax() internal {
        if (veTokenId == 0) return;

        IVotingEscrow.LockedBalance memory locked = IVotingEscrow(votingEscrow).locked(veTokenId);
        if (locked.isPermanent || locked.end <= block.timestamp) return;

        uint256 maxUnlockTime = ((block.timestamp + HybraTimeLibrary.MAX_LOCK_DURATION) / HybraTimeLibrary.WEEK) * HybraTimeLibrary.WEEK;

        // Only extend if difference is more than 2 hours
        if (maxUnlockTime > locked.end + 2 hours) {
            try IVotingEscrow(votingEscrow).increase_unlock_time(veTokenId, HybraTimeLibrary.MAX_LOCK_DURATION) {
                // Extension successful
            } catch {
                // Extension failed, continue without error
                // This can happen if already at max possible time or other constraints
            }
        }
    }

}