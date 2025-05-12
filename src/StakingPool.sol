// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {UUPSUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlDefaultAdminRulesUpgradeable} from
    "openzeppelin-contracts-upgradeable/contracts/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {SafeERC20, IERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardUpgradeable} from
    "openzeppelin-contracts-upgradeable/contracts/utils/ReentrancyGuardUpgradeable.sol";

contract StakingPool is AccessControlDefaultAdminRulesUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    struct Stake {
        uint256 amount;
        uint256 startTime;
        uint256 lastRewardTime;
        uint256 accumulatedRewards;
        bool initialized;
    }

    struct InputPool {
        address inputToken; // address(0) for ETH
        uint256 rewardRate; // in basis points (1% = 100 bps)
        uint256 totalStaked;
        bool isEth;
        bool active;
        mapping(address => Stake) stakes;
    }

    mapping(bytes32 => InputPool) public pools; // poolId => InputPool
    IERC20 public rewardToken;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    error InvalidInputToken();
    error InvalidAmount();
    error NotInitialized();
    error ZeroAddress();
    error InsufficientBalance();
    error InactivePool();
    error PoolAlreadyExists();
    error InvalidPool();

    event Staked(address indexed staker, bytes32 indexed poolId, uint256 amount, uint256 timestamp);
    event Unstaked(address indexed staker, bytes32 indexed poolId, uint256 amount, uint256 timestamp);
    event RewardClaimed(address indexed staker, bytes32 indexed poolId, uint256 amount, uint256 timestamp);
    event RewardFunded(address indexed funder, uint256 amount, uint256 timestamp);
    event PoolCreated(bytes32 indexed poolId, address inputToken, bool isEth, uint256 rewardRate);
    event PoolUpdated(bytes32 indexed poolId, uint256 newRewardRate, bool active);

    function initialize(address admin, IERC20 _rewardToken) public initializer {
        if (admin == address(0) || address(_rewardToken) == address(0)) {
            revert ZeroAddress();
        }
        __AccessControlDefaultAdminRules_init_unchained(0, admin);
        __UUPSUpgradeable_init_unchained();
        __ReentrancyGuard_init_unchained();

        rewardToken = _rewardToken;
        _grantRole(MANAGER_ROLE, admin);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /**
     * @dev Create a new staking pool.
     * @param inputToken The address of the input token (ERC20) or address(0) for ETH.
     * @param rewardRate The reward rate in basis points (1% = 100 bps).
     * @param isEth True if the input token is ETH, false if it's an ERC20 token.
     *
     */
    function createPool(address inputToken, uint256 rewardRate, bool isEth)
        external
        onlyRole(MANAGER_ROLE)
        returns (bytes32)
    {
        bytes32 poolId = keccak256(abi.encodePacked(inputToken, isEth));
        if (pools[poolId].active) revert PoolAlreadyExists();

        InputPool storage pool = pools[poolId];
        pool.inputToken = inputToken;
        pool.rewardRate = rewardRate;
        pool.isEth = isEth;
        pool.active = true;

        emit PoolCreated(poolId, inputToken, isEth, rewardRate);
        return poolId;
    }

    /**
     * @dev Update the reward rate and active status of a pool.
     * @param poolId The ID of the pool to update.
     * @param newRewardRate The new reward rate in basis points.
     * @param active The new active status of the pool.
     *
     */
    function updatePool(bytes32 poolId, uint256 newRewardRate, bool active) external onlyRole(MANAGER_ROLE) {
        InputPool storage pool = pools[poolId];
        if (pool.inputToken == address(0) && !pool.isEth) revert InvalidPool();

        pool.rewardRate = newRewardRate;
        pool.active = active;

        emit PoolUpdated(poolId, newRewardRate, active);
    }

    /**
     * @dev Fund the rewards for the staking pool.
     * @param amount The amount of reward tokens to fund.
     *
     */
    function fundRewards(uint256 amount) external onlyRole(MANAGER_ROLE) {
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        emit RewardFunded(msg.sender, amount, block.timestamp);
    }

    /**
     * @dev Stake tokens in the pool.
     * @param poolId The ID of the pool to stake in.
     * @param amount The amount of tokens to stake.
     *
     */
    function stake(bytes32 poolId, uint256 amount) external payable nonReentrant {
        InputPool storage pool = pools[poolId];
        if (!pool.active) revert InactivePool();
        if (amount == 0) revert InvalidAmount();
        if (pool.isEth && msg.value != amount) revert InvalidAmount();
        if (!pool.isEth && msg.value > 0) revert InvalidAmount();

        updateRewards(poolId, msg.sender);

        Stake storage userStake = pool.stakes[msg.sender];
        if (!userStake.initialized) {
            userStake.initialized = true;
            userStake.startTime = block.timestamp;
        }

        if (pool.isEth) {
            // ETH staking
            if (msg.value != amount) revert InvalidAmount();
        } else {
            // ERC20 staking
            IERC20(pool.inputToken).safeTransferFrom(msg.sender, address(this), amount);
        }

        userStake.amount += amount;
        pool.totalStaked += amount;

        emit Staked(msg.sender, poolId, amount, block.timestamp);
    }

    /**
     * @dev Unstake tokens from the pool.
     * @param poolId The ID of the pool to unstake from.
     * @param amount The amount of tokens to unstake.
     *
     */
    function unstake(bytes32 poolId, uint256 amount) external nonReentrant {
        InputPool storage pool = pools[poolId];
        if (!pool.active) revert InactivePool();
        if (amount == 0 || pool.stakes[msg.sender].amount < amount) revert InvalidAmount();
        if (!pool.stakes[msg.sender].initialized) revert NotInitialized();

        updateRewards(poolId, msg.sender);

        Stake storage userStake = pool.stakes[msg.sender];
        userStake.amount -= amount;
        pool.totalStaked -= amount;

        if (pool.isEth) {
            // ETH withdrawal
            (bool success,) = msg.sender.call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            // ERC20 withdrawal
            IERC20(pool.inputToken).safeTransfer(msg.sender, amount);
        }

        emit Unstaked(msg.sender, poolId, amount, block.timestamp);
    }

    /**
     * @dev Claim rewards from the pool.
     * @param poolId The ID of the pool to claim rewards from.
     *
     */
    function claimRewards(bytes32 poolId) external nonReentrant returns (uint256) {
        InputPool storage pool = pools[poolId];
        if (!pool.active) revert InactivePool();
        if (!pool.stakes[msg.sender].initialized) revert NotInitialized();

        updateRewards(poolId, msg.sender);

        Stake storage userStake = pool.stakes[msg.sender];
        uint256 reward = userStake.accumulatedRewards;
        if (reward > 0) {
            userStake.accumulatedRewards = 0;
            rewardToken.safeTransfer(msg.sender, reward);
            emit RewardClaimed(msg.sender, poolId, reward, block.timestamp);
        }

        return reward;
    }

    /**
     * @dev Update the rewards for a user in the pool.
     * @param poolId The ID of the pool.
     * @param account The address of the user.
     *
     */
    function updateRewards(bytes32 poolId, address account) internal {
        InputPool storage pool = pools[poolId];
        Stake storage userStake = pool.stakes[account];
        if (!userStake.initialized) return;

        uint256 timeElapsed = block.timestamp - userStake.lastRewardTime;
        uint256 newRewards = (userStake.amount * pool.rewardRate * timeElapsed) / (10000 * 1 days);

        userStake.accumulatedRewards += newRewards;
        userStake.lastRewardTime = block.timestamp;
    }

    /**
     * @dev Get the pending rewards for a user in the pool.
     * @param poolId The ID of the pool.
     * @param account The address of the user.
     * @return pending rewards for the account.
     *
     */
    function getPendingRewards(bytes32 poolId, address account) external view returns (uint256) {
        InputPool storage pool = pools[poolId];
        Stake storage userStake = pool.stakes[account];
        if (!userStake.initialized) return 0;

        uint256 timeElapsed = block.timestamp - userStake.lastRewardTime;
        uint256 newRewards = (userStake.amount * pool.rewardRate * timeElapsed) / (10000 * 1 days);

        return userStake.accumulatedRewards + newRewards;
    }

    /**
     * @dev Get the staked amount for a user in the pool.
     * @param poolId The ID of the pool.
     */
    function getPoolInfo(bytes32 poolId)
        external
        view
        returns (address inputToken, uint256 rewardRate, uint256 totalStaked, bool isEth, bool active)
    {
        InputPool storage pool = pools[poolId];
        return (pool.inputToken, pool.rewardRate, pool.totalStaked, pool.isEth, pool.active);
    }

    // Allow contract to receive ETH
    receive() external payable {}
}
