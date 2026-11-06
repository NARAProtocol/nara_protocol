# What NARA Protocol V5 Is

**NARA Protocol V5** is a decentralized liquidity and time-commitment system deployed on **Base Mainnet (`8453`)**.

Instead of relying on inflationary minting, team token cliffs, or mercenary liquidity farming, NARA V5 seals **99.9984%** of its fixed **1,000,000 NARA** supply directly inside immutable smart contracts that reward long-term commitment and deepen protocol-owned liquidity (**POL**) automatically.

```text
+-------------------------------------------------------------------------+
|                        NARA PROTOCOL V5 FLYWHEEL                        |
+-------------------------------------------------------------------------+
|                                                                         |
|  1. FIXED SUPPLY (1,000,000 NARA)                                       |
|     - 949,987 NARA (94.9987%) sealed in NARAEmissionReserveV5           |
|     -  49,997 NARA ( 4.9997%) in Two-Way NARATreasuryRangeManagerV5     |
|     -       0 NARA ( 0.0000%) team, VC, or private pre-sale allocation  |
|                                   |                                     |
|                                   v                                     |
|  2. TWO-PHASE UNISWAP V4 HOOK (4.63% Base Fee -> up to 20% Burst Fee)   |
|     - Phase 1 (Launch): 100% of Hook fees build permanent POL depth     |
|     - Phase 2 (Once Liquidity Is Built): Hook swap tax (USDC & NARA)    |
|       is redirected into NARAEpochEngineV5 15-minute epoch rewards      |
|                                   |                                     |
|                                   v                                     |
|  3. TIME COMMITMENTS (1 to 365 Days -> 1.00x to 4.00x Weight)           |
|     - 1-for-1 segregated principal custody in NARAPrincipalLedgerV5     |
|     - 15-minute reward epochs (96 per day) via NARAEpochEngineV5        |
|     - Multi-asset rewards: NARA + ETH + USDC                            |
|                                   |                                     |
|                                   v                                     |
|  4. LIQUID POSITION NFTs (NARAP) & CRYPTOSLIP 0.1 NARA GRID             |
|     - Every 1.0+ NARA commitment mints a tradeable Position NFT         |
|     - Built-in native-ETH marketplace (95% seller / 5% rewards)         |
|     - CryptoSLIP supports the 10-slot 0.1 NARA shared Grid & Slips      |
+-------------------------------------------------------------------------+
```

---

## Core Pillars of What We Built

### 1. Fixed Supply with Zero Team or Insider Allocations

- **Total Supply:** Exactly **1,000,000 NARA** (`0x91FB78A9F46B67f54BbD4489941d19666b2fAe0f`).
- **No Owner, No Minting:** `NARATokenV5` has no `mint()` function and no owner (`owner = 0x0`). Supply can never be inflated.
- **No Insider Allocations:** There are zero team tokens, zero investor vesting schedules, and zero off-market bond discounts.
- **99.9984% Protocol-Committed:** `949,987 NARA` (`94.9987%`) is sealed in `NARAEmissionReserveV5` for 15-minute epoch rewards, and `49,997 NARA` (`4.9997%`) is held in `NARATreasuryRangeManagerV5`.

### 2. Two-Phase Hook Fee Routing: Build Liquidity First, Then Redirect Tax to Engine Rewards

- **Dynamic Hook Protection:** The canonical `NARA / USDC` Uniswap v4 pool (`0x3bd8b60dc9eb37f00afa57585232e4018ae661b2dbd5318562183a67a07ac758`) is governed by `NARALiquidityHookV5` (`0x201fBD2839bEc513040024b37dAe97B401E96acC`). Normal swaps pay a **4.63% (`463 bps`)** Hook fee (`4.92%` total with the `0.30%` LP fee), while rapid same-block volume bursts escalate up to **20.00% (`2,000 bps`)**.
- **Phase 1 — `100% POL` Liquidity Build-Out:** At launch, **100%** of Hook swap fees flow into `NARAFeeVaultV5` and `NARAPOLPositionV5` to rapidly build permanent protocol-owned liquidity that can never be rugged or withdrawn.
- **Phase 2 — Redirect Swap Tax to 15-Minute Epoch Rewards:** As soon as the target pool liquidity depth is built, `NARAFeeVaultV5` redirects the Hook swap tax (`USDC` and `NARA`) straight into `NARARewardIngressV5` → `NARARewardLedgerV5`. Every trade on the pool then pays **`USDC` and `NARA` rewards** directly to active Position NFT holders every 15 minutes.

### 3. Two-Way Active Range Manager (`NARATreasuryRangeManagerV5`)

- **Not Single-Sided — Sells Upside & Buys Back with `USDC`:** `NARATreasuryRangeManagerV5` (`0xa72557fcBE56B3eC739dF3aF7b6b893B6Db4D288`, holding `49,997 NARA`) places bounded `NARA` sell rungs above spot to collect **`USDC`** as price rises, and then uses that collected **`USDC`** to place buy-side rungs that **buy `NARA` back** on pullbacks.
- **7-Day `NARA` Withdrawal Delay → Extendable to 1 Year:** While `USDC` can be actively deployed to buy `NARA` and support two-way pool depth, withdrawing `NARA` from the Range Manager requires a **7-day on-chain waiting period** at launch—and once live operation is verified with nothing breaking, the `NARA` commitment delay can be extended out to **1 year (365 days)**.

### 4. Segregated Principal Custody, 15-Minute Epochs & Liquid Position NFTs (`NARAP`)

- **1-for-1 Principal Safety:** When you commit `NARA` for **1 to 365 days**, your principal is stored 1-for-1 in `NARAPrincipalLedgerV5` (`0x7F866a9fbe41D54F0d9C35b6892fcf27Ea766DB2`), completely separated from reward reserves and swap fees.
- **Quadratic Time Weight (`1.00x` to `4.00x`):** Longer commitments receive up to a `4.00x` weight multiplier (`V4Quadratic` curve) across **96 epochs per day** (`15 minutes` each) on `NARAEpochEngineV5` (`0xd93FbEbFb33FAc9288125074625D4750573B1a53`).
- **Built-In Native-`ETH` NFT Market:** Every commitment mints a tradeable ERC-721 `NARAP` Position NFT (`0x8C5F088D9d09dBB90aB6F3aaA049a8FD5D5FfFDA`) that can be sold before maturity on `NARAPositionSaleV5` (`0x04Ac83045d26259D46400Ce6beb9bBd0641df225`) for native `ETH` (`95%` to seller, `5%` to epoch rewards).

### 5. How the CryptoSLIP `0.1 NARA` Grid & Payment Slips Work

- **The `1.0 NARA` On-Chain Rule:** To keep on-chain epoch accounting gas-efficient, `NARAPrincipalLedgerV5.create(...)` enforces an immutable minimum of **`1.0 NARA`** (`minimumPrincipal = 1e18`) per Position NFT.
- **Participate from `0.1 NARA` via CryptoSLIP:** Inside the **[CryptoSLIP App](https://cryptoslip-g29s.4everland.app/?v=cs-1793645949345)** ([**Public Overview & 25-Question Legal FAQ**](CRYPTOSLIP_PUBLIC_OVERVIEW_AND_LEGAL_FAQ.md)), users can:
  1. **Join the 10-Slot `0.1 NARA` `NARA Grid`:** Commit `0.1 NARA` per slot (1 to 10 slots) into the shared **NARA Grid** (`10 × 0.1 NARA = 1.0 NARA` Position NFT), where each slot receives **10% of the position's 15-minute rewards and principal**.
  2. **Send & Receive Instant `NARA` Slips:** Transfer fractional `NARA` bearer Slips off-DEX via shareable links or QR codes (`0%` transfer tax), or harvest 15-minute rewards directly into shareable Slips.
