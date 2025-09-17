pragma solidity 0.8.13;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
 import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import '../interfaces/IGaugeFactoryCL.sol';
import '../interfaces/IGaugeManager.sol';
import './interface/ICLPool.sol';
import './interface/ICLFactory.sol';
import './interface/INonfungiblePositionManager.sol';
import '../interfaces/IBribe.sol';
import '../interfaces/IRHYBR.sol';
import {HybraTimeLibrary} from "../libraries/HybraTimeLibrary.sol";
import {FullMath} from "./libraries/FullMath.sol";
import {FixedPoint128} from "./libraries/FixedPoint128.sol";
import '../interfaces/IRHYBR.sol';



contract GaugeCL is ReentrancyGuard, Ownable, IERC721Receiver {

    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;
    using SafeCast for uint128;
    IERC20 public immutable rewardToken;
    address public immutable rHYBR;
    address public VE;
    address public DISTRIBUTION;
    address public internal_bribe;
    address public external_bribe;

    uint256 public DURATION;
    uint256 internal _periodFinish;
    uint256 public rewardRate;
    ICLPool public clPool;
    address public poolAddress;
    INonfungiblePositionManager public nonfungiblePositionManager;
    
    bool public emergency;
    bool public immutable isForPair;
    address immutable factory;

    mapping(uint256 => uint256) public  rewardRateByEpoch; // epoch => reward rate
    mapping(address => EnumerableSet.UintSet) internal _stakes;
    mapping(uint256 => uint256) public  rewardGrowthInside;

    mapping(uint256 => uint256) public  rewards;

    mapping(uint256 => uint256) public  lastUpdateTime;

    event RewardAdded(uint256 reward);
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Harvest(address indexed user, uint256 reward);
    event ClaimFees(address indexed from, uint256 claimed0, uint256 claimed1);
    event EmergencyActivated(address indexed gauge, uint256 timestamp);
    event EmergencyDeactivated(address indexed gauge, uint256 timestamp);

    constructor(address _rewardToken, address _rHYBR, address _ve, address _pool, address _distribution, address _internal_bribe, 
        address _external_bribe, bool _isForPair, address nfpm,  address _factory) {
        factory = _factory;
        rewardToken = IERC20(_rewardToken);     // main reward
        rHYBR = _rHYBR;
        VE = _ve;                               // vested
        poolAddress = _pool;
        clPool = ICLPool(_pool);
        DISTRIBUTION = _distribution;           // distro address (GaugeManager)
        DURATION = HybraTimeLibrary.WEEK;                   

        internal_bribe = _internal_bribe;       // lp fees goes here
        external_bribe = _external_bribe;       // bribe fees goes here
        isForPair = _isForPair;
        nonfungiblePositionManager = INonfungiblePositionManager(nfpm);
        emergency = false;
    }

    modifier onlyDistribution() {
        require(msg.sender == DISTRIBUTION, "Caller is not RewardsDistribution contract");
        _;
    }

    modifier isNotEmergency() {
        require(emergency == false, "emergency");
        _;
    }


    function _updateRewards(uint256 tokenId, int24 tickLower, int24 tickUpper) internal {
        if (lastUpdateTime[tokenId] == block.timestamp) return;
        clPool.updateRewardsGrowthGlobal();
        lastUpdateTime[tokenId] = block.timestamp;
        rewards[tokenId] += _earned(tokenId);
        rewardGrowthInside[tokenId] = clPool.getRewardGrowthInside(tickLower, tickUpper, 0);
    }

    function activateEmergencyMode() external onlyOwner {
        require(emergency == false, "emergency");
        emergency = true;
        emit EmergencyActivated(address(this), block.timestamp);
    }

    function stopEmergencyMode() external onlyOwner {

        require(emergency == true,"emergency");

        emergency = false;
        emit EmergencyDeactivated(address(this), block.timestamp);
    }

    function balanceOf(uint256 tokenId) external view returns (uint256) {
        (,,,,,,,uint128 liquidity,,,,) = nonfungiblePositionManager.positions(tokenId);
        return liquidity;
    }

    function _getPoolAddress(address token0, address token1, int24 tickSpacing) internal view returns (address) {
        return ICLFactory(nonfungiblePositionManager.factory()).getPool(token0, token1, tickSpacing);
    }

    function earned(uint256 tokenId) external view returns (uint256 reward) {
        require(_stakes[msg.sender].contains(tokenId), "NA");

        uint256 reward = _earned(tokenId);
        return (reward); // bonsReward is 0 for now
    }

       function _earned(uint256 tokenId) internal view returns (uint256) {
        uint256 lastUpdated = clPool.lastUpdated();

        uint256 timeDelta = block.timestamp - lastUpdated;

        
        uint256 rewardGrowthGlobalX128 = clPool.rewardGrowthGlobalX128();
        uint256 rewardReserve = clPool.rewardReserve();

        if (timeDelta != 0 && rewardReserve > 0 && clPool.stakedLiquidity() > 0) {
            uint256 reward = rewardRate * timeDelta;
            if (reward > rewardReserve) reward = rewardReserve;

            rewardGrowthGlobalX128 += FullMath.mulDiv(reward, FixedPoint128.Q128, clPool.stakedLiquidity());
        }

        (,,,,, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) = nonfungiblePositionManager.positions(tokenId);

        uint256 rewardPerTokenInsideInitialX128 = rewardGrowthInside[tokenId];
        uint256 rewardPerTokenInsideX128 = clPool.getRewardGrowthInside(tickLower, tickUpper, rewardGrowthGlobalX128);

        uint256 claimable =
            FullMath.mulDiv(rewardPerTokenInsideX128 - rewardPerTokenInsideInitialX128, liquidity, FixedPoint128.Q128);
        return claimable;
    }

    function deposit(uint256 tokenId) external nonReentrant isNotEmergency {
        
         (,,address token0, address token1, int24 tickSpacing, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) = 
            nonfungiblePositionManager.positions(tokenId);
        
        require(liquidity > 0, "Gauge: zero liquidity");
        // Calculate pool address from position parameters
        address positionPool = _getPoolAddress(token0, token1, tickSpacing);
        // Verify that the position's pool matches this gauge's pool
        require(positionPool == poolAddress, "Pool mismatch: Position not for this gauge pool");
        // collect fees 
        nonfungiblePositionManager.collect(INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: msg.sender,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            }));

        nonfungiblePositionManager.safeTransferFrom(msg.sender, address(this), tokenId);

        clPool.stake(int128(liquidity), tickLower, tickUpper, true);


        uint256 rewardGrowth = clPool.getRewardGrowthInside(tickLower, tickUpper, 0);
        rewardGrowthInside[tokenId] = rewardGrowth;
        lastUpdateTime[tokenId] = block.timestamp;

        _stakes[msg.sender].add(tokenId);

        emit Deposit(msg.sender, tokenId);
    }

    function withdraw(uint256 tokenId, uint8 redeemType) external nonReentrant isNotEmergency {
           require(_stakes[msg.sender].contains(tokenId), "NA");

        // trigger update on staked position so NFT will be in sync with the pool
        nonfungiblePositionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: msg.sender,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        (,,,,, int24 tickLower, int24 tickUpper, uint128 liquidityToStake,,,,) = nonfungiblePositionManager.positions(tokenId);
        _getReward(tickLower, tickUpper, tokenId, msg.sender, redeemType);

        // update virtual liquidity in pool only if token has existing liquidity
        // i.e. not all removed already via decreaseStakedLiquidity
        if (liquidityToStake != 0) {
            clPool.stake(-int128(liquidityToStake), tickLower, tickUpper, true);
        }

        _stakes[msg.sender].remove(tokenId);
        nonfungiblePositionManager.safeTransferFrom(address(this), msg.sender, tokenId);

        emit Withdraw(msg.sender, tokenId);
    }

    

    function getReward(uint256 tokenId, address account,uint8 redeemType ) public nonReentrant onlyDistribution {

        require(_stakes[account].contains(tokenId), "NA");

        (,,,,, int24 tickLower, int24 tickUpper,,,,,) = nonfungiblePositionManager.positions(tokenId);
        _getReward(tickLower, tickUpper, tokenId, account, redeemType);
    }


    function _getReward(int24 tickLower, int24 tickUpper, uint256 tokenId,address account, uint8 redeemType) internal {
        _updateRewards(tokenId, tickLower, tickUpper);
        uint256 rewardAmount = rewards[tokenId];
        if(rewardAmount > 0){
            delete rewards[tokenId];
            rewardToken.safeApprove(rHYBR, rewardAmount);
            IRHYBR(rHYBR).depostionEmissionsToken(rewardAmount);
            IRHYBR(rHYBR).redeemFor(rewardAmount, redeemType, account);
        }
        emit Harvest(msg.sender, rewardAmount);
    }

    function notifyRewardAmount(address token, uint256 rewardAmount) external nonReentrant
        isNotEmergency onlyDistribution returns (uint256 currentRate) {
        require(token == address(rewardToken), "Invalid reward token");

        // Update global reward growth before processing new rewards
        clPool.updateRewardsGrowthGlobal();

        // Calculate time remaining until next epoch begins
        uint256 epochTimeRemaining = HybraTimeLibrary.epochNext(block.timestamp) - block.timestamp;
        uint256 epochEndTimestamp = block.timestamp + epochTimeRemaining;

        // Include any rolled over rewards from previous period
        uint256 totalRewardAmount = rewardAmount + clPool.rollover();

        // Check if we are starting a new reward period or continuing existing one
        if (block.timestamp >= _periodFinish) {
            // New period: distribute rewards over remaining epoch time
            rewardRate = rewardAmount / epochTimeRemaining;
            clPool.syncReward({
                rewardRate: rewardRate,
                rewardReserve: totalRewardAmount,
                periodFinish: epochEndTimestamp
            });
        } else {
            // Existing period: add new rewards to pending distribution
            uint256 pendingRewards = epochTimeRemaining * rewardRate;
            rewardRate = (rewardAmount + pendingRewards) / epochTimeRemaining;
            clPool.syncReward({
                rewardRate: rewardRate,
                rewardReserve: totalRewardAmount + pendingRewards,
                periodFinish: epochEndTimestamp
            });
        }

        // Store reward rate for current epoch tracking
        rewardRateByEpoch[HybraTimeLibrary.epochStart(block.timestamp)] = rewardRate;

        // Transfer reward tokens from distributor to gauge
        rewardToken.safeTransferFrom(DISTRIBUTION, address(this), rewardAmount);

        // Verify contract has sufficient balance to support calculated reward rate
        uint256 contractBalance = rewardToken.balanceOf(address(this));
        require(rewardRate <= contractBalance / epochTimeRemaining, "Insufficient balance for reward rate");

        // Update period finish time and return current rate
        _periodFinish = epochEndTimestamp;
        currentRate = rewardRate;

        emit RewardAdded(rewardAmount);
    }

    function gaugeBalances() external view returns (uint256 token0, uint256 token1){
        
        (token0, token1) = clPool.gaugeFees();

    }

  



    function claimFees() external nonReentrant returns (uint256 claimed0, uint256 claimed1) {
        return _claimFees();
    }

    function _claimFees() internal returns (uint256 claimed0, uint256 claimed1) {
        if (!isForPair) {
            return (0, 0);
        }
        
        clPool.collectFees();
        
        address _token0 = clPool.token0();
        address _token1 = clPool.token1();
        // Fetch fee from the whole epoch which just eneded and transfer it to internal Bribe address.
        claimed0 = IERC20(_token0).balanceOf(address(this));
        claimed1 = IERC20(_token1).balanceOf(address(this));

        if (claimed0 > 0 || claimed1 > 0) {
    

            uint256 _fees0 = claimed0;
            uint256 _fees1 = claimed1;

            if (_fees0  > 0) {
                IERC20(_token0).safeApprove(internal_bribe, 0);
                IERC20(_token0).safeApprove(internal_bribe, _fees0);
                IBribe(internal_bribe).notifyRewardAmount(_token0, _fees0);
            } 
            if (_fees1  > 0) {
                IERC20(_token1).safeApprove(internal_bribe, 0);
                IERC20(_token1).safeApprove(internal_bribe, _fees1);
                IBribe(internal_bribe).notifyRewardAmount(_token1, _fees1);
            } 
            emit ClaimFees(msg.sender, claimed0, claimed1);
        }
    }

    ///@notice get total reward for the duration
    function rewardForDuration() external view returns (uint256) {
        return rewardRate * DURATION;
    }

    ///@notice set new internal bribe contract (where to send fees)
    function setInternalBribe(address _int) external onlyOwner {
        require(_int >= address(0), "zero");
        internal_bribe = _int;
    }

    function _safeTransfer(address token,address to,uint256 value) internal {
        require(token.code.length > 0);
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }

    /**
     * @dev Handle the receipt of an NFT
     * @param operator The address which called `safeTransferFrom` function
     * @param from The address which previously owned the token
     * @param tokenId The NFT identifier which is being transferred
     * @param data Additional data with no specified format
     * @return bytes4 `bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"))`
     */
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

}


