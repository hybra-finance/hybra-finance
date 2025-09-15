pragma solidity 0.8.13;

interface IGaugeCL {
    function notifyRewardAmount(address token, uint amount) external returns ( uint256 rewardRate);
    function getReward(uint256 tokenId, address account) external;
    function claimFees() external returns (uint claimed0, uint claimed1);
    function balanceOf(uint256 tokenId) external view returns (uint256); 
    function emergency() external returns (bool);

    function earned(uint256 tokenId) external view returns (uint256 reward, uint256 bonusReward);   
    function totalSupply() external view returns (uint);
    function rewardRate() external view returns (uint);
    function rewardForDuration() external view returns (uint256);
    function stakedFees() external view returns (uint256, uint256);
}