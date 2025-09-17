// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import "./libraries/Math.sol";
import "./interfaces/IMinter.sol";
import "./interfaces/IRewardsDistributor.sol";
import "./interfaces/IHybra.sol";
import "./interfaces/IGaugeManager.sol";
import "./interfaces/IVotingEscrow.sol";
import { IHybraGovernor } from "./interfaces/IHybraGovernor.sol";

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {HybraTimeLibrary} from "./libraries/HybraTimeLibrary.sol";

// codifies the minting rules as per ve(3,3), abstracted from the token to support any token that allows minting
// 14 increment epochs followed by 52 decrement epochs after which we wil have vote based epochs

contract MinterUpgradeable is IMinter, OwnableUpgradeable {
    
    bool public isFirstMint;
    
    uint public EMISSION;
    uint public TAIL_EMISSION;
    uint public REBASEMAX;
    uint public teamRate;  //EMISSION that goes to protocol
    uint public constant MAX_TEAM_RATE = 500; // 5%
    uint256 public constant MAX_BPS = 10_000; 
   
    uint public WEEK; // allows minting once per week (reset every Thursday 00:00 UTC)
    uint public weekly; // represents a starting weekly emission of 2.6M HYBRA (HYBRA has 18 decimals)
    uint public active_period;
    uint public LOCK;
    uint256 public epochCount;

    address internal _initializer;
    address public team;
    address public pendingTeam;
    
    IHybra public _hybr ;
    IGaugeManager public _gaugeManager;
    IVotingEscrow public _ve;
    IRewardsDistributor public _rewards_distributor;
    address private burnTokenAddress;

    mapping(uint256 => bool) public proposals;

    event Mint(address indexed sender, uint weekly, uint circulating_supply, uint circulating_emission);

    constructor() {}

    function initialize(    
        address __gaugeManager, // distribution system
        address __ve, // the ve(3,3) system that will be locked into
        address __rewards_distributor // the distribution system that ensures users aren't diluted
    ) initializer public {
        __Ownable_init();

        _initializer = msg.sender;
        team = msg.sender;
        EMISSION = 9900;
        teamRate = 500; // 500 bps = 5%
        REBASEMAX = 3000;
        TAIL_EMISSION = 25;
        WEEK = HybraTimeLibrary.WEEK;
        LOCK = HybraTimeLibrary.MAX_LOCK_DURATION;
        _hybr = IHybra(IVotingEscrow(__ve).token());
        _gaugeManager = IGaugeManager(__gaugeManager);
        _ve = IVotingEscrow(__ve);
        _rewards_distributor = IRewardsDistributor(__rewards_distributor);

        active_period = ((block.timestamp + (2 * WEEK)) / WEEK) * WEEK;
        weekly = 2_600_000 * 1e18; // represents a starting weekly emission of 3000(Test) HYBRA (HYBRA has 18 decimals)
        isFirstMint = true;

        burnTokenAddress=0x000000000000000000000000000000000000dEaD;
    }

    function _initialize(
        address[] memory claimants,
        uint[] memory amounts,
        uint max // sum amounts / max = % ownership of top protocols, so if initial 20m is distributed, and target is 25% protocol ownership, then max - 4 x 20m = 80m
    ) external {
        require(_initializer == msg.sender);
        if(max > 0){
            _hybr.mint(address(this), max);
            _hybr.approve(address(_ve), type(uint).max);
            for (uint i = 0; i < claimants.length; i++) {
                _ve.create_lock_for(amounts[i], LOCK, claimants[i]);
            }
        }

        _initializer = address(0);
        active_period = ((block.timestamp) / WEEK) * WEEK; // allow minter.update_period() to mint new emissions THIS Thursday
    }

    function setTeam(address _team) external {
        require(msg.sender == team);
        pendingTeam = _team;
    }

    function acceptTeam() external {
        require(msg.sender == pendingTeam, "not pending team");
        team = pendingTeam;
    }

    function setGaugeManager(address __gaugeManager) external {
        require(__gaugeManager != address(0));
        require(msg.sender == team, "not team");
        _gaugeManager = IGaugeManager(__gaugeManager);
    }

    function setTeamRate(uint _teamRate) external {
        require(msg.sender == team, "not team");
        require(_teamRate <= MAX_TEAM_RATE, "rate too high");
        teamRate = _teamRate;
    }

    function setEmission(uint _emission) external {
        require(msg.sender == team, "not team");
        require(_emission <= MAX_BPS, "rate too high");
        EMISSION = _emission;
    }

    function setRebase(uint _rebase) external {
        require(msg.sender == team, "not team");
        require(_rebase <= MAX_BPS, "rate too high");
        REBASEMAX = _rebase;
    }

    function setTailEmission(uint _tailEmission) external {
        require(msg.sender == team, "not team");
        require(_tailEmission <= MAX_BPS, "rate too high");
        TAIL_EMISSION = _tailEmission;
    }

      // emission calculation is 1% of available supply to mint adjusted by circulating / total supply
    function calculate_emission() public view returns (uint) {
        return (weekly * EMISSION) / MAX_BPS;
    }


    function circulating_emission() public view returns (uint) {
        return (_hybr.totalSupply() * TAIL_EMISSION) / MAX_BPS;
    }

     // weekly emission takes the max of calculated (aka target) emission versus circulating tail end emission
    function weekly_emission() public view returns (uint) {
        return Math.max(calculate_emission(), circulating_emission());
    }

    // calculate inflation and adjust ve balances accordingly
    function calculate_rebase(uint _weeklyMint) public view returns (uint) {
        uint _veTotal = _hybr.balanceOf(address(_ve));
        uint _hybrTotal = _hybr.totalSupply();
        
        uint lockedShare = (_veTotal) * MAX_BPS  / _hybrTotal;
        if(lockedShare >= REBASEMAX){
            return _weeklyMint * REBASEMAX / MAX_BPS;
        } else {
            return _weeklyMint * lockedShare / MAX_BPS;
        }
    }
    

    // update period can only be called once per cycle (1 week)
    function update_period() external returns (uint) {
        uint _period = active_period;
        if (block.timestamp >= _period + WEEK && _initializer == address(0)) { // only trigger if new week
            epochCount++;
            _period = (block.timestamp / WEEK) * WEEK;
            active_period = _period;

            if(!isFirstMint){
                weekly = weekly_emission();
            } else {
                isFirstMint = false;
            }

            uint256 _weekly = weekly;
            uint256 _emission = _weekly;

            uint _rebase = calculate_rebase(_emission);

            uint _teamEmissions = _emission * teamRate / MAX_BPS;

            uint _gauge = _emission - _rebase - _teamEmissions;

            uint _balanceOf = _hybr.balanceOf(address(this));
            if (_balanceOf < _emission) {
                _hybr.mint(address(this), _emission - _balanceOf);
            }

            require(_hybr.transfer(team, _teamEmissions));
            
            require(_hybr.transfer(address(_rewards_distributor), _rebase));
           
            _rewards_distributor.checkpoint_token(); // checkpoint token balance that was just minted in rewards distributor

            _hybr.approve(address(_gaugeManager), _gauge);
            _gaugeManager.notifyRewardAmount(_gauge);
        
            emit Mint(msg.sender, _emission, _rebase, circulating_supply());
        }
        return _period;
    }

    function circulating_supply() public view returns (uint) {
        return _hybr.totalSupply() - _hybr.balanceOf(address(_ve)) - _hybr.balanceOf(address(burnTokenAddress));
    }

    function check() external view returns(bool){
        uint _period = active_period;
        return (block.timestamp >= _period + WEEK && _initializer == address(0));
    }

    function period() external view returns(uint){
        return(block.timestamp / WEEK) * WEEK;
    }
    function setRewardDistributor(address _rewardDistro) external {
        require(msg.sender == team);
        _rewards_distributor = IRewardsDistributor(_rewardDistro);
    }
}
