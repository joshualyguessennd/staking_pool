# StakingPool Project
This project features a StakingPool smart contract that allows users to stake multiple input tokens (USDC, USDT, ETH) in separate pools to earn rewards in a single reward token. The contract is upgradeable, leverages OpenZeppelin's UUPSUpgradeable, AccessControl, SafeERC20, and ReentrancyGuard, and includes comprehensive tests written for Foundry's Forge.

# Project Overview
The StakingPool contract supports:

Multiple Input Tokens: Users can stake USDC, USDT, or ETH in dedicated pools.
Reward System: Rewards accrue based on staking duration and pool-specific reward rates (in basis points).
Admin Functions: Managers can create/update pools and fund rewards.
Security: Includes reentrancy protection and access control.
Testing: Comprehensive Forge tests covering staking, unstaking, rewards, and security scenarios.

Key files:

src/StakingPool.sol: The main staking contract.
src/MockToken.sol: A mock ERC20 token with blacklist functionality for testing.
test/StakingPoolTest.sol: Foundry test suite.

# Setup Instructions
Prerequisites

Foundry: Install Foundry (see https://book.getfoundry.sh/getting-started/installation).
Rust: Ensure Rust is installed (curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh).
Git: For cloning the repository (if applicable).

# Build

Clone the Repository (if applicable):
git clone <repository-url>
cd <repository-directory>

```
forge build
```



# Testing
Run the test suite to verify StakingPool functionality:
```
forge test
```
For verbose output (including event logs and traces):

```
forge test -vv
```
Tests cover:

Contract initialization
Pool creation and updates
Staking and unstaking (USDC, USDT, ETH)
Reward calculation and claiming
Reward funding

# Formatting
Format Solidity code for consistency:
```
forge fmt
```
# Gas Snapshots
Generate gas usage reports:

```
forge snapshot
```