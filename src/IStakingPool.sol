// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IStakingPool {
    function rewardToken() external view returns (address);
    function managers(address) external view returns (bool);
    function createPool(address inputToken, uint256 rewardRate, bool isEth) external returns (bytes32);
    function getPoolInfo(bytes32 poolId) external view returns (address, uint256, uint256, bool, bool);
    function stake(bytes32 poolId, uint256 amount) external payable;
    function unstake(bytes32 poolId, uint256 amount) external;
    function fundRewards(uint256 amount) external;
    function claimRewards(bytes32 poolId) external returns (uint256);
    function getPendingRewards(bytes32 poolId, address account) external view returns (uint256);
    function updatePool(bytes32 poolId, uint256 newRewardRate, bool active) external;
    function addManager(address newManager) external;
}
