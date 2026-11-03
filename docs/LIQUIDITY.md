# Liquidity, Uniswap v4 Hook & Two-Way Range Manager

NARA Protocol V5 uses **Uniswap v4** on Base Mainnet (`8453`) with a custom dynamic fee hook (`NARALiquidityHookV5`), a two-phase fee vault (`NARAFeeVaultV5`), a permanent protocol-owned liquidity vault (`NARAPOLPositionV5`), and a two-way active range manager (`NARATreasuryRangeManagerV5`).

---

## 1. Canonical `NARA / USDC` Pool

| Parameter | Verified On-Chain Value |
|---|---|
| **Uniswap v4 `PoolManager`** | [`0x498581fF718922c3f8e6A244956aF099B2652b2b`](https://basescan.org/address/0x498581fF718922c3f8e6A244956aF099B2652b2b) |
| **Canonical Pool ID** | `0x3bd8b60dc9eb37f00afa57585232e4018ae661b2dbd5318562183a67a07ac758` |
| **Currency 0 (`USDC`)** | [`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`](https://basescan.org/address/0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913) (`6` decimals) |
| **Currency 1 (`NARA`)** | [`0x91FB78A9F46B67f54BbD4489941d19666b2fAe0f`](https://basescan.org/address/0x91FB78A9F46B67f54BbD4489941d19666b2fAe0f) (`18` decimals) |
| **Tick Spacing** | `60` |
| **LP Fee Flag** | `0x800000` (Dynamic LP Fee controlled by Hook) |
| **Hook Contract** | [`0x201fBD2839bEc513040024b37dAe97B401E96acC`](https://basescan.org/address/0x201fBD2839bEc513040024b37dAe97B401E96acC) (`NARALiquidityHookV5`) |
| **Initial Seed Price** | **`$100.00 USDC` per `1.00 NARA`** (`3.0 NARA + 300.0 USDC`) |

---

## 2. Dynamic Anti-Bot Hook Fee (`4.63%` to `20.00%`)

Every swap on the canonical `NARA / USDC` pool passes through **`NARALiquidityHookV5`** (`0x201fBD2839bEc513040024b37dAe97B401E96acC`):

- **Base-Tier Swap Cost (`4.63%` Hook Fee + `0.30%` LP Fee = `4.92%` Total):** Standard retail buys and sells pay a `4.63%` (`463 bps`) Hook fee plus the `0.30%` Uniswap LP fee (`4.9161%` combined, always under `4.97%` both ways).
- **Same-Block Volume Escalation (up to `20.00%` / `2,000 bps`):** If large or repeated swaps hit the pool inside the same Base block across all senders, the Hook automatically escalates the fee through higher volume tiers (`5%`, `8%`, `12%`, up to `20%` on buys; `5%`, `7%`, `10%`, `15%`, up to `20%` on sells), then resets cleanly on the next block.

```text
Swap on Canonical NARA / USDC Pool
        |
        v
NARALiquidityHookV5 (4.63% Base Fee -> up to 20.00% Same-Block Burst Fee)
        |
        v
NARAFeeVaultV5 (0xe63b4BaAF873FC57859bfe13e0e8cFccAaB6AddE)
        |
        +---> PHASE 1 (Launch — Build Liquidity First):
        |     100% (10,000 bps) -> NARAPOLPositionV5 (Permanent Un-Ruggable Pool Depth)
        |
        +---> PHASE 2 (As Soon as Target Liquidity Is Built):
              Swap Tax (USDC & NARA) Redirected -> NARARewardIngressV5 -> NARARewardLedgerV5
              (Paid out every 15 minutes to active NARA Position NFT holders!)
```

---

## 3. Two-Phase Fee Vault: Build Permanent POL First $\rightarrow$ Redirect Tax to Engine Rewards

Hook fees (`USDC` and `NARA`) are collected by **`NARAFeeVaultV5`** (`0xe63b4BaAF873FC57859bfe13e0e8cFccAaB6AddE`), which operates in two distinct phases:

1. **Phase 1 — Launch Mode (`100% POL` Liquidity Build-Out):**
   - At launch, `_holderFeeBps = 0` (`100%` routed to `NARAPOLPositionV5` at `0x01EF9de9f4e9197F2A3944b5B34A90eA2f558b64`).
   - Why? Because an ultra-scarce token (`1,000,000` fixed supply) needs a rock-solid, permanent liquidity base first. `NARAPOLPositionV5` has **no `decreaseLiquidity()` or principal withdrawal function**—every dollar of Hook fees compounded during Phase 1 stays in the pool permanently.
2. **Phase 2 — Liquidity Built $\rightarrow$ Swap Tax Redirected to Epoch Rewards:**
   - **As soon as target liquidity depth is built**, `NARAFeeVaultV5` activates the holder reward split (`setHolderFeeBps`), redirecting collected Hook swap taxes (`USDC` and `NARA`) directly into **`NARARewardIngressV5`** (`0x44130CC47b886D8488041F5eaE271477D1aFA909`).
   - Those `USDC` and `NARA` swap fees are then distributed **every 15 minutes (`96 epochs/day`)** through `NARAEpochEngineV5` and `NARARewardLedgerV5` to everyone holding an active Position NFT!

---

## 4. Two-Way Active Range Manager (`NARATreasuryRangeManagerV5`)

**`49,997 NARA` (`4.9997%` of total supply)** is held inside **`NARATreasuryRangeManagerV5`** (`0xa72557fcBE56B3eC739dF3aF7b6b893B6Db4D288`).

Unlike a single-sided liquidity wall that only sells tokens on the way up, `NARATreasuryRangeManagerV5` is a **two-way active range liquidity engine**:

- **Upside Sell Rungs (`NARA` $\rightarrow$ `USDC`):** As organic buying moves the price up through upper price bands, the Range Manager supplies `NARA` liquidity and collects **`USDC`**.
- **Downside Buy Rungs (`USDC` $\rightarrow$ Buys `NARA` Back):** Once the Range Manager has collected **`USDC`** from upside fills, it actively deploys that **`USDC`** into buy-side range bands below spot to **buy `NARA` back on pullbacks**, building two-way market depth and collecting LP fees in both directions.
- **7-Day `NARA` Withdrawal Delay $\rightarrow$ Extendable to 1 Year:**
  - While realized `USDC` can be actively utilized to buy `NARA` and manage pool liquidity, any withdrawal of `NARA` from `NARATreasuryRangeManagerV5` is gated by a mandatory **7-day (`604,800s`) on-chain waiting period** at launch.
  - Keeping the waiting period at **7 days** initially ensures that if anything ever needs adjustment during early live operation, it can be safely handled—and once live operation is proven with nothing breaking, the `NARA` waiting period can be extended out to **1 year (365 days)**.
