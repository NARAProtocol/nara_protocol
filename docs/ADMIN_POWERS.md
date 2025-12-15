# NARA Admin Powers After Lock

## Overview

After calling `lockParams()` (NARAMiner) and `lockTokenParams()` (NARAToken), the contracts become **parameter-immutable**. This document explicitly states what the owner CAN and CANNOT do.

---

## NARAMiner (after `lockParams()`)

### ❌ Owner CANNOT do:

| Function                     | Status                               |
| ---------------------------- | ------------------------------------ |
| `setUnitWei()`               | **BLOCKED** - ParamsLocked           |
| `setHardCap()`               | **BLOCKED** - ParamsLocked           |
| `setBasePerMin()`            | **BLOCKED** - ParamsLocked           |
| `setLinearL()`               | **BLOCKED** - ParamsLocked           |
| `setStreakWindows()`         | **BLOCKED** - ParamsLocked           |
| `setJackpotParams()`         | **BLOCKED** - ParamsLocked           |
| `setJackpotPayoutShareBps()` | **BLOCKED** - ParamsLocked           |
| `seedLiquidity()`            | **BLOCKED** - ParamsLocked           |
| `topUpRewardPool()`          | **BLOCKED** - ParamsLocked           |
| `airdropFromRewardPool()`    | **BLOCKED** - ParamsLocked           |
| `setAutoMinerRegistry()`     | **BLOCKED** - ParamsLocked           |
| `pause()` / `unpause()`      | **REMOVED** - Does not exist in code |

### ✅ ANYONE can do (permissionless after conditions):

| Function                    | Condition                     |
| --------------------------- | ----------------------------- |
| `sweepETH(epoch)`           | After epoch ends + 24 hours   |
| `recoverExpiredNARA(epoch)` | After 2x claim window expires |

**Rationale:** These functions exist to prevent permanent capital lock-up due to user inactivity. They do not allow value extraction beyond what is already unclaimed or protocol-owned.

---

## NARAToken (after `lockTokenParams()`)

### ❌ Owner CANNOT do:

| Function                  | Status                          |
| ------------------------- | ------------------------------- |
| `setTransferFeeBps()`     | **BLOCKED** - TokenParamsLocked |
| `setFeeRecipient()`       | **BLOCKED** - TokenParamsLocked |
| `setTreasury()`           | **BLOCKED** - TokenParamsLocked |
| `setMiningHoldDuration()` | **BLOCKED** - TokenParamsLocked |

### ✅ Owner CAN still do:

| Function              | Reason                          |
| --------------------- | ------------------------------- |
| `transferOwnership()` | Standard OpenZeppelin construct |

Ownership after lock confers **no protocol-level control over issuance, fees, or reward logic**. Treasury management remains discretionary and is explicitly out of scope of protocol immutability.

---

## NARATokenOFT (after `lockTokenParams()`)

Same as NARAToken above.

---

---

## AutoMinerRegistry (Service Layer)

AutoMinerRegistry is a **convenience service** for automated mining. It does not affect core protocol issuance logic.

### ❌ Owner CANNOT do:

| Function                 | Status               |
| ------------------------ | -------------------- |
| Modify core mining logic | **DOES NOT CONTROL** |
| Change epoch rewards     | **DOES NOT CONTROL** |
| Affect manual miners     | **DOES NOT CONTROL** |

### ✅ Owner CAN do:

| Function                | Reason                                       |
| ----------------------- | -------------------------------------------- |
| `setBot(address)`       | Authorize bot to trigger auto-mining         |
| `commitServiceFeeBps()` | Propose new service fee (3-day timelock)     |
| `applyServiceFeeBps()`  | Apply fee after `FEE_UPDATE_DELAY` (3 days)  |
| `withdrawServiceFees()` | Collect accumulated service fees to treasury |

**Service fee mechanics:**

- Service fee is capped at **25%** (`MAX_SERVICE_FEE_BPS = 2500`)
- Changes require two-step process with **3-day delay** (`FEE_UPDATE_DELAY`)
- Service fees withdraw to miner's treasury address (read from `miner.treasury()` at deployment)
- Does not affect ETH split to treasury/Community Pool
- Only affects auto-mining convenience cost

**Execution authorization:**

The bot, user, or owner can trigger `mineForUser()`. The registry enforces `token.canMine(user)` eligibility (tier + hold duration rules) and reverts with `UserIneligible()` if not met.

**Impact scope:** AutoMinerRegistry only controls **automation convenience fees**. All protocol-level economics (jackpot odds, emission rates, treasury split) remain in NARAMiner and are locked after `lockParams()`.

Users can always mine manually to avoid auto-miner fees.

---

## Treasury Governance (Post-Lock)

After parameters are locked, the protocol continues to route ETH to the treasury address.

- Treasury funds are **not** governed by protocol logic.
- Treasury spending decisions are **off-chain discretionary**.
- No on-chain guarantees exist regarding treasury actions.

The treasury controller **may**:

- Fund liquidity
- Buy and burn NARA
- Fund development or audits
- Do nothing

The treasury controller **may later be changed**, including transfer to:

- A DAO
- A multisig
- A timelock
- Or any other governance system

Any such transition is **external to the protocol** and does not affect core issuance mechanics.

Treasury actions are **not guaranteed** and do not imply price support, yield, or profitability.

All treasury transactions are publicly visible on-chain.

---

## Summary

**After both locks are called:**

- 🔒 All protocol-level economic and governance parameters _(issuance rates, fees, thresholds, and reward logic)_ are permanently disabled
- 🔒 No pause or emergency controls exist
- 🔒 Ownership confers no protocol-level privileges
- ✅ Mining, claiming, and protocol operation continue permissionlessly
- ✅ Recovery of expired funds is open to anyone
- ⚠️ Treasury spending remains discretionary (see above)

The system becomes **parameter-immutable and self-operating**, with all remaining behavior strictly defined by deployed code.

---

## Verification

All statements in this document can be verified directly in the deployed contracts via Etherscan.

No multisig, DAO, proxy upgrade mechanism, or off-chain protocol control exists beyond what is described above.
