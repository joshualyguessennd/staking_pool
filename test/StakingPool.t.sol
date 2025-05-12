// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import {StakingPool} from "../src/StakingPool.sol";
import {MockToken} from "./utils/MockToken.sol";

contract StakingPoolTest is Test {
    StakingPool public stakingPool;
    MockToken public usdcToken;
    MockToken public usdtToken;
    MockToken public rewardToken;

    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    address public manager = address(0x4);

    uint256 public constant REWARD_RATE = 100; // 1% per day
    uint256 public constant STAKE_AMOUNT = 100 * 1e6; // 100 tokens (6 decimals)
    uint256 public constant REWARD_AMOUNT = 1000 * 1e6; // 1000 tokens (6 decimals)

    bytes32 public usdcPoolId;
    bytes32 public usdtPoolId;
    bytes32 public ethPoolId;

    function setUp() public {
        // Set up accounts
        vm.startPrank(owner);

        // Deploy tokens
        usdcToken = new MockToken("USDC Token", "USDC");
        usdtToken = new MockToken("USDT Token", "USDT");
        rewardToken = new MockToken("Reward Token", "RWD");

        // Deploy and initialize StakingPool
        stakingPool = new StakingPool();
        stakingPool.initialize(owner, rewardToken);

        // Create pools
        usdcPoolId = stakingPool.createPool(address(usdcToken), REWARD_RATE, false);
        usdtPoolId = stakingPool.createPool(address(usdtToken), REWARD_RATE, false);
        ethPoolId = stakingPool.createPool(address(0), REWARD_RATE, true);

        // Grant manager role
        stakingPool.grantRole(stakingPool.MANAGER_ROLE(), manager);

        // Mint tokens
        usdcToken.mint(user1, 1000 * 1e6);
        usdtToken.mint(user1, 1000 * 1e6);
        rewardToken.mint(manager, 10000 * 1e6);

        // Approve tokens
        vm.stopPrank();
        vm.prank(user1);
        usdcToken.approve(address(stakingPool), type(uint256).max);
        vm.prank(user1);
        usdtToken.approve(address(stakingPool), type(uint256).max);
        vm.prank(manager);
        rewardToken.approve(address(stakingPool), type(uint256).max);

        // Fund user1 with ETH
        vm.deal(user1, 10 ether);
    }

    function test_Initialization() public view {
        assertEq(address(stakingPool.rewardToken()), address(rewardToken));
        assertTrue(stakingPool.hasRole(stakingPool.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(stakingPool.hasRole(stakingPool.MANAGER_ROLE(), manager));
    }

    function test_PoolCreation() public {
        (address inputToken, uint256 rewardRate, uint256 totalStaked, bool isEth, bool active) =
            stakingPool.getPoolInfo(usdcPoolId);

        assertEq(inputToken, address(usdcToken));
        assertEq(rewardRate, REWARD_RATE);
        assertEq(totalStaked, 0);
        assertFalse(isEth);
        assertTrue(active);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(StakingPool.PoolAlreadyExists.selector));
        stakingPool.createPool(address(usdcToken), REWARD_RATE, false);
    }

    function test_StakeERC20() public {
        vm.prank(user1);
        vm.expectEmit(true, true, false, true);
        emit StakingPool.Staked(user1, usdcPoolId, STAKE_AMOUNT, block.timestamp);
        stakingPool.stake(usdcPoolId, STAKE_AMOUNT);

        (,, uint256 totalStaked,,) = stakingPool.getPoolInfo(usdcPoolId);
        assertEq(totalStaked, STAKE_AMOUNT);
        assertEq(usdcToken.balanceOf(address(stakingPool)), STAKE_AMOUNT);
    }

    function test_StakeETH() public {
        vm.prank(user1);
        vm.expectEmit(true, true, false, true);
        emit StakingPool.Staked(user1, ethPoolId, STAKE_AMOUNT, block.timestamp);
        stakingPool.stake{value: STAKE_AMOUNT}(ethPoolId, STAKE_AMOUNT);

        (,, uint256 totalStaked,,) = stakingPool.getPoolInfo(ethPoolId);
        assertEq(totalStaked, STAKE_AMOUNT);
        assertEq(address(stakingPool).balance, STAKE_AMOUNT);
    }

    function test_StakeInvalidAmount() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(StakingPool.InvalidAmount.selector));
        stakingPool.stake(usdcPoolId, 0);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(StakingPool.InvalidAmount.selector));
        stakingPool.stake{value: STAKE_AMOUNT + 1}(ethPoolId, STAKE_AMOUNT);
    }

    function test_UnstakeERC20() public {
        vm.prank(user1);
        stakingPool.stake(usdcPoolId, STAKE_AMOUNT);

        uint256 balanceBefore = usdcToken.balanceOf(user1);
        vm.prank(user1);
        vm.expectEmit(true, true, false, true);
        emit StakingPool.Unstaked(user1, usdcPoolId, STAKE_AMOUNT, block.timestamp);
        stakingPool.unstake(usdcPoolId, STAKE_AMOUNT);

        (,, uint256 totalStaked,,) = stakingPool.getPoolInfo(usdcPoolId);
        assertEq(totalStaked, 0);
        assertEq(usdcToken.balanceOf(user1), balanceBefore + STAKE_AMOUNT);
    }

    function test_UnstakeETH() public {
        vm.prank(user1);
        stakingPool.stake{value: STAKE_AMOUNT}(ethPoolId, STAKE_AMOUNT);

        uint256 balanceBefore = user1.balance;
        vm.prank(user1);
        vm.expectEmit(true, true, false, true);
        emit StakingPool.Unstaked(user1, ethPoolId, STAKE_AMOUNT, block.timestamp);
        stakingPool.unstake(ethPoolId, STAKE_AMOUNT);

        (,, uint256 totalStaked,,) = stakingPool.getPoolInfo(ethPoolId);
        assertEq(totalStaked, 0);
        assertEq(user1.balance, balanceBefore + STAKE_AMOUNT);
    }

    function test_UnstakeInvalidAmount() public {
        vm.prank(user1);
        stakingPool.stake(usdcPoolId, STAKE_AMOUNT);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(StakingPool.InvalidAmount.selector));
        stakingPool.unstake(usdcPoolId, STAKE_AMOUNT + 1);
    }

    function test_Rewards() public {
        vm.prank(user1);
        stakingPool.stake(usdcPoolId, STAKE_AMOUNT);

        vm.prank(manager);
        stakingPool.fundRewards(REWARD_AMOUNT);

        // Fast forward 1 day
        vm.warp(block.timestamp + 1 days);

        uint256 expectedReward = (STAKE_AMOUNT * REWARD_RATE) / 10000;
        uint256 pendingRewards = stakingPool.getPendingRewards(usdcPoolId, user1);
        assertApproxEqAbs(pendingRewards, expectedReward, 1e3);

        uint256 balanceBefore = rewardToken.balanceOf(user1);
        vm.prank(user1);
        vm.expectEmit(true, true, false, true);
        emit StakingPool.RewardClaimed(user1, usdcPoolId, pendingRewards, block.timestamp);
        stakingPool.claimRewards(usdcPoolId);

        assertEq(rewardToken.balanceOf(user1), balanceBefore + pendingRewards);
    }

    function test_FundRewards() public {
        vm.prank(manager);
        vm.expectEmit(true, false, false, true);
        emit StakingPool.RewardFunded(manager, REWARD_AMOUNT, block.timestamp);
        stakingPool.fundRewards(REWARD_AMOUNT);

        assertEq(rewardToken.balanceOf(address(stakingPool)), REWARD_AMOUNT);

        vm.prank(user1);
        vm.expectRevert();
        stakingPool.fundRewards(REWARD_AMOUNT);
    }

    function test_UpdatePool() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit StakingPool.PoolUpdated(usdcPoolId, REWARD_RATE * 2, false);
        stakingPool.updatePool(usdcPoolId, REWARD_RATE * 2, false);

        (, uint256 rewardRate,,, bool active) = stakingPool.getPoolInfo(usdcPoolId);
        assertEq(rewardRate, REWARD_RATE * 2);
        assertFalse(active);
    }
}

contract Malicious {
    StakingPool public stakingPool;
    bytes32 public poolId;
    uint256 public attackCount;

    constructor(address payable _stakingPool, bytes32 _poolId) {
        stakingPool = StakingPool(_stakingPool);
        poolId = _poolId;
    }

    function attack(uint256 amount) external {
        stakingPool.stake(poolId, amount);
        stakingPool.unstake(poolId, amount);
    }

    fallback() external {
        if (attackCount < 5) {
            attackCount++;
            (,, uint256 totalStaked,,) = stakingPool.getPoolInfo(poolId);
            if (totalStaked > 0) {
                stakingPool.unstake(poolId, totalStaked);
            }
        }
    }
}
