pragma solidity ^0.7.0;

interface IStakingPool{
    function stake(uint256) external;
    function withdraw(uint256) external;
    function emergencyWithdraw() external;
    function getReward() external;
    function exit() external;
    function getCurRewardRate() external view returns (uint256);
    function earned(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}