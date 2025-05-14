// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract StakingPool {
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
    mapping(address => bool) public managers; // Tracks manager roles
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    // Reentrancy protection
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;
    uint256 private status = NOT_ENTERED;

    // Custom errors
    error InvalidInputToken();
    error InvalidAmount();
    error NotInitialized();
    error ZeroAddress();
    error InsufficientBalance();
    error InactivePool();
    error PoolAlreadyExists();
    error InvalidPool();
    error NotManager();
    error ReentrantCall();

    // Events
    event Staked(address indexed staker, bytes32 indexed poolId, uint256 amount, uint256 timestamp);
    event Unstaked(address indexed staker, bytes32 indexed poolId, uint256 amount, uint256 timestamp);
    event RewardClaimed(address indexed staker, bytes32 indexed poolId, uint256 amount, uint256 timestamp);
    event RewardFunded(address indexed funder, uint256 amount, uint256 timestamp);
    event PoolCreated(bytes32 indexed poolId, address inputToken, bool isEth, uint256 rewardRate);
    event PoolUpdated(bytes32 indexed poolId, uint256 newRewardRate, bool active);
    event ManagerAdded(address indexed manager);
    event ManagerRemoved(address indexed manager);

    // Modifiers
    modifier onlyManager() {
        if (!managers[msg.sender]) revert NotManager();
        _;
    }

    modifier nonReentrant() {
        if (status == ENTERED) revert ReentrantCall();
        status = ENTERED;
        _;
        status = NOT_ENTERED;
    }

    constructor(address admin, IERC20 _rewardToken) {
        if (admin == address(0) || address(_rewardToken) == address(0)) {
            revert ZeroAddress();
        }
        rewardToken = _rewardToken;
        managers[admin] = true;
        emit ManagerAdded(admin);
    }

    // Create a new staking pool
    function createPool(address inputToken, uint256 rewardRate, bool isEth) external onlyManager returns (bytes32) {
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

    // Update the reward rate and active status of a pool
    function updatePool(bytes32 poolId, uint256 newRewardRate, bool active) external onlyManager {
        InputPool storage pool = pools[poolId];
        if (pool.inputToken == address(0) && !pool.isEth) revert InvalidPool();

        pool.rewardRate = newRewardRate;
        pool.active = active;

        emit PoolUpdated(poolId, newRewardRate, active);
    }

    // Fund the rewards for the staking pool
    function fundRewards(uint256 amount) external onlyManager nonReentrant {
        if (amount == 0) revert InvalidAmount();
        safeTransferFrom(rewardToken, msg.sender, address(this), amount);
        emit RewardFunded(msg.sender, amount, block.timestamp);
    }

    // Stake tokens in the pool
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
            userStake.lastRewardTime = block.timestamp;
        }

        if (pool.isEth) {
            if (msg.value != amount) revert InvalidAmount();
        } else {
            safeTransferFrom(IERC20(pool.inputToken), msg.sender, address(this), amount);
        }

        userStake.amount += amount;
        pool.totalStaked += amount;

        emit Staked(msg.sender, poolId, amount, block.timestamp);
    }

    // Unstake tokens from the pool
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
            (bool success,) = msg.sender.call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            safeTransfer(IERC20(pool.inputToken), msg.sender, amount);
        }

        emit Unstaked(msg.sender, poolId, amount, block.timestamp);
    }

    // Claim rewards from the pool
    function claimRewards(bytes32 poolId) external nonReentrant returns (uint256) {
        InputPool storage pool = pools[poolId];
        if (!pool.active) revert InactivePool();
        if (!pool.stakes[msg.sender].initialized) revert NotInitialized();

        updateRewards(poolId, msg.sender);

        Stake storage userStake = pool.stakes[msg.sender];
        uint256 reward = userStake.accumulatedRewards;
        if (reward > 0) {
            userStake.accumulatedRewards = 0;
            safeTransfer(rewardToken, msg.sender, reward);
            emit RewardClaimed(msg.sender, poolId, reward, block.timestamp);
        }

        return reward;
    }

    // Update the rewards for a user in the pool
    function updateRewards(bytes32 poolId, address account) internal {
        InputPool storage pool = pools[poolId];
        Stake storage userStake = pool.stakes[account];
        if (!userStake.initialized) return;

        uint256 timeElapsed = block.timestamp - userStake.lastRewardTime;
        uint256 newRewards = (userStake.amount * pool.rewardRate * timeElapsed) / (10000 * 1 days);

        userStake.accumulatedRewards += newRewards;
        userStake.lastRewardTime = block.timestamp;
    }

    // Get the pending rewards for a user in the pool
    function getPendingRewards(bytes32 poolId, address account) external view returns (uint256) {
        InputPool storage pool = pools[poolId];
        Stake storage userStake = pool.stakes[account];
        if (!userStake.initialized) return 0;

        uint256 timeElapsed = block.timestamp - userStake.lastRewardTime;
        uint256 newRewards = (userStake.amount * pool.rewardRate * timeElapsed) / (10000 * 1 days);

        return userStake.accumulatedRewards + newRewards;
    }

    // Get pool information
    function getPoolInfo(bytes32 poolId)
        external
        view
        returns (address inputToken, uint256 rewardRate, uint256 totalStaked, bool isEth, bool active)
    {
        InputPool storage pool = pools[poolId];
        return (pool.inputToken, pool.rewardRate, pool.totalStaked, pool.isEth, pool.active);
    }

    // Add a new manager
    function addManager(address newManager) external onlyManager {
        if (newManager == address(0)) revert ZeroAddress();
        managers[newManager] = true;
        emit ManagerAdded(newManager);
    }

    // Remove a manager
    function removeManager(address manager) external onlyManager {
        if (manager == address(0)) revert ZeroAddress();
        if (!managers[manager]) revert NotManager();
        managers[manager] = false;
        emit ManagerRemoved(manager);
    }

    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        require(to != address(0), "Zero address");
        bool success = token.transfer(to, amount);
        require(success, "Transfer failed");
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        require(from != address(0) && to != address(0), "Zero address");
        bool success = token.transferFrom(from, to, amount);
        require(success, "TransferFrom failed");
    }

    // Allow contract to receive ETH
    receive() external payable {}
}
