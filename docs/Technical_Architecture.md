# NARA Protocol: Technical Architecture

## Executive Summary

NARA is a competitive token issuance mechanism adapted from Proof-of-Work principles for EVM environments (Base as initial deployment).

Instead of computational work, participants commit ETH during discrete time windows (epochs) to receive proportional shares of released supply. The aggregate ETH committed determines production cost. Optional variance mechanisms (jackpot) and participation modifiers (tiers, streaks) exist, but no outcome is guaranteed.

Participation may be manual or automated. The protocol does not promise yield, price support, or adoption.

## 1. System Overview

The system consists of three primary verified contracts:

| Contract                | Role           | Key Responsibility                                               |
| ----------------------- | -------------- | ---------------------------------------------------------------- |
| `NARAToken.sol`         | **Asset**      | ERC-20, Fixed Supply (3.33M), Transfer Fee Logic, Tier Tracking  |
| `NARAMiner.sol`         | **Engine**     | Epoch Management, Ticket Logic, Jackpot RNG, Reward Distribution |
| `AutoMinerRegistry.sol` | **Automation** | On-chain bot registry for automated mining participation         |

## 2. Core Mechanics

### 2.1 The Epoch System (`NARAMiner.sol`)

Time is divided into discrete windows called "Epochs".

- **Duration**: 180 Seconds (3 Minutes)
- **Emission**: Fixed base rate + Surge bonus based on ETH deposited.
- **Logic**: Users compete for shares of the _current_ epoch's emission.

```solidity
// NARAMiner.sol
uint256 public constant EPOCH_SECONDS = 180;
// Epoch calculation
uint256 e = (block.timestamp / EPOCH_SECONDS);
```

### 2.2 Mining & Tickets

Mining is a 2-step process to prevent blockhash grinding (exploit protection), unless using the trusted AutoMiner.

1.  **Request Mine**: User sends ETH. Commits to the current block number.
2.  **Finalize Mine**: Reveal occurs in a future block.
    - **Tickets**: `msg.value / unitWei`
    - **Effective Tickets**: `linearL + sqrt(n - linearL)` (Diminishing returns start after `linearL` tickets).

**Whale Protection Math:**

```solidity
function _effective(uint256 n) internal view returns (uint256) {
    if (n <= linearL) return n;
    // Diminishing returns for bulk buyers
    unchecked { return linearL + _sqrt(n - linearL); }
}
```

### 2.3 The Jackpot System

Every mining transaction has a chance to trigger a jackpot payout.

- **Probability**: ~0.25% (`jackpotChanceBps = 25`)
- **Source**: 30% of all mining ETH + 0.1% of all NARA transfers.
- **Payout**: Winner takes up to 90% of the pot (ETH + NARA).

**Randomness Source:**
Uses `blockhash` of the seed block (future from request time) + `prevrandao` (Beacon chain randomness).

```solidity
uint256 rand = uint256(keccak256(abi.encodePacked(
    blockhash(seedBlock), // Unpredictable at request time
    user,
    block.prevrandao
)));
```

## 3. Game Theory & Incentives

### 3.1 Loyalty Tiers (`NaraTiers.sol`)

Holding NARA grants "Tier" status. Tiers grant bonus multipliers to mining power.

- **12 Tiers**: Seedling (0.1 NARA) to Gaia (100k NARA).
- **Time Multiplier**: The longer you hold a tier, the higher your bonus (up to +180% for Gaia > 1 year).

### 3.2 Streaks

Maintaining daily activity boosts rewards.

- **Window**: Mine once every 24-48 hours.
- **Bonus**:
  - 3 Days: +10%
  - 7 Days: +25%
  - 30 Days: +50%
- **Penalty**: Miss a window -> Reset to Day 1.

### 3.3 Auto-Mining (`AutoMinerRegistry.sol`)

Allows "Set and Forget" participation.

- User deposits ETH into Registry.
- Configures `ticketsPerMine` and frequency.
- **Service Fee**: 25% of ETH cost goes to protocol.
- **Stop Conditions**: Auto-stop if Jackpot is won (Take profit protection).

## 4. Security & Access Control

- **Ownable**: Admin can tune parameters (ticket price, caps) but can `lockParams()` to renounce control.
- **ReentrancyGuard**: Applied to all value-transferring functions.
- **SafeERC20**: Used for all token transfers.
- **Parameter Locking**: Admin can `lockParams()` to permanently disable all parameter changes.

## 5. Data Structures & State

Key mappings for tracking user state:

- `tickets[epoch][user]`: Raw ticket count.
- `effWeightedUser[epoch][user]`: Effective tickets \* Multiplier (The actual share).
- `streaks[user]`: Last active timestamp and day count.
- `tierStarts[user]`: Timestamp of entering each tier level.

---

**Verification References:**

- `NARAMiner.sol`: Lines 57-155 (State), 323-374 (Mining Logic), 501-551 (Jackpot).
- `NaraTiers.sol`: Lines 8-20 (Tier Thresholds), 106-218 (Bonus Logic).
