# Liquidity, Uniswap v4 Hook, Zero-Delay Fee Controller & Two-Way Range Manager

NARA Protocol V5 uses **Uniswap v4** on Base Mainnet (`8453`) with a custom dynamic fee hook (`NARALiquidityHookV5`), a fee custody vault (`NARAFeeVaultV5`), a zero-delay (`0-second delay`) fee routing controller (`NARATreasuryFeeControllerV5`), and a two-way active range manager (`NARATreasuryRangeManagerV5`).

---

## 1. Canonical `NARA / USDC` Pool

| Parameter | Verified On-Chain Value |
|---|---|
| **Uniswap v4 `PoolManager`** | [`0x498581fF718922c3f8e6A244956aF099B2652b2b`](https://basescan.org/address/0x498581fF718922c3f8e6A244956aF099B2652b2b) |
| **Canonical Pool ID** | `0x4a475299ef674bcc3d2c87c3917cfbecd38cf7237646a3553e37daba67da6e5f` |
| **Currency 0 (`USDC`)** | [`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`](https://basescan.org/address/0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913) (`6` decimals) |
| **Currency 1 (`NARA`)** | [`0x91FB78A9F46B67f54BbD4489941d19666b2fAe0f`](https://basescan.org/address/0x91FB78A9F46B67f54BbD4489941d19666b2fAe0f) (`18` decimals) |
| **Tick Spacing** | `60` |
| **LP Fee** | `3000` (`0.30%`) |
| **Hook Contract** | [`0x07d8F2Dfd121B10dE3176DeAb6A8C0eaa2646aCC`](https://basescan.org/address/0x07d8F2Dfd121B10dE3176DeAb6A8C0eaa2646aCC) (`NARALiquidityHookV5`, paired with `NARAHookFeeCalculatorV5` [`0xeCc6bB347c615BD51E13dcAB670D0c34Df3375F8`](https://basescan.org/address/0xeCc6bB347c615BD51E13dcAB670D0c34Df3375F8)) |
| **Initial Seed Price** | **`$100.00 USDC` per `1.00 NARA`** (`3.0 NARA + 300.0 USDC`) |

---

## 2. Dynamic Anti-Bot Hook Fee (`4.63%` to `20.00%`)

Every swap on the canonical `NARA / USDC` pool passes through **`NARALiquidityHookV5`** (`0x07d8F2Dfd121B10dE3176DeAb6A8C0eaa2646aCC`):

- **Base-Tier Swap Cost (`4.63%` Hook Fee + `0.30%` LP Fee = `4.92%` Total):** Standard retail buys and sells pay a `4.63%` (`463 bps`) Hook fee plus the `0.30%` (`3000 pips`) Uniswap LP fee (`4.9161%` combined each way).
- **Same-Block Volume Escalation (up to `20.00%` / `2,000 bps`):** If large or repeated swaps hit the pool inside the same Base block across all senders, the Hook automatically escalates the fee through higher volume tiers (`5%`, `8%`, `12%`, up to `20%` on buys; `5%`, `7%`, `10%`, `15%`, up to `20%` on sells), then resets cleanly on the next block.

```text
Swap on Canonical NARA / USDC Pool (Pool ID: 0x4a475299...6e5f)
        |
        v
NARALiquidityHookV5 (4.63% Base Fee -> up to 20.00% Same-Block Burst Fee)
        |
        v
NARAFeeVaultV5 (0xF1f361F803895BF5cf67eC6C506dbFEf2f6E88Cf, maxHolderFeeBps = 10,000)
        |
        +---> ZERO-DELAY FEE CONTROLLER (NARATreasuryFeeControllerV5 0xB6A436b4...646b9):
        |     0-second delay redemption & routing of 100% (or any custom % split) of USDC & NARA
        |     swap fees to Treasury Safe, NARATreasuryRangeManagerV5, NARAEmissionReserveV5,
        |     or NARARewardIngressV5 -> NARARewardLedgerV5 (15-minute epoch rewards)
        |
        +---> CONFIGURABLE AUTOMATIC HOLDER SPLIT (NARAFeeIngressBindingV5 0x17cc7431...8d4BF):
              Optional on-chain holderFeeBps (0% to 100%, 7-day governance notice) routing
              swap fees automatically via forwardHolders -> NARARewardIngressV5 -> NARARewardLedgerV5
```

---

## 3. Zero-Delay Fee Vault & Controller (`NARAFeeVaultV5` + `NARATreasuryFeeControllerV5`)

Hook swap fees (`USDC` on buys, `NARA` on sells) are collected by **`NARAFeeVaultV5`** (`0xF1f361F803895BF5cf67eC6C506dbFEf2f6E88Cf`), which is sealed directly to **`NARATreasuryFeeControllerV5`** (`0xB6A436b48222C94fe427ecAfB263DF9cf42646b9`) and bound via **`NARAFeeIngressBindingV5`** (`0x17cc74317AD75a170887F9E76e5fF09f2058d4BF`) to **`NARARewardIngressV5`** (`0x44130CC47b886D8488041F5eaE271477D1aFA909`):

1. **Immediate (`0-Second Delay`) Fee Redemption & Routing (`NARATreasuryFeeControllerV5`):**
   - Unlike legacy POL architectures (`NARAPOLPositionV5`) that permanently trap swap fees inside a one-way LP position with no withdrawal capability or behind multi-day delays, `NARATreasuryFeeControllerV5` operates with **`0-second delay` and zero permanent tie-up**.
   - At launch (`_holderFeeBps = 0`), 100% of collected `USDC` and `NARA` swap fees accrue to the controller bucket (`polClaims` / `polRaw`). The `2-of-3` **Treasury Safe** (`0xe320C281c86079eA85f2Bc67864E873A61D551E3`) can redeem and route 100% (or any custom `50/50` / `100%` split) of `USDC` and `NARA` swap fees **immediately (`0-second delay`)** via `sweepToSafe()`, `withdrawAllTo(recipient)`, or `withdrawTo(asset, amount, recipient)`:
     - To the **Treasury Safe** (`0xe320C281c86079eA85f2Bc67864E873A61D551E3`) or **`NARATreasuryRangeManagerV5`** (`0x221c625d2BC416460C397035C1286C1f4A4D3A7C`) to deepen active two-way liquidity,
     - Directly into **`NARARewardIngressV5`** (`0x44130CC47b886D8488041F5eaE271477D1aFA909`) → **`NARARewardLedgerV5`** (`0xC72671D9438388638547444524F6542b650C9264`) to distribute `USDC` and `NARA` swap fees across active Position NFTs every 15 minutes, or
     - Into **`NARAEmissionReserveV5`** (`0xf932178F24b0813C82093985F0Af6Db27Ae25930`) to replenish the epoch emission reserve.
2. **Configurable Automatic Holder Split (`proposeHolderFeeSplit` / `forwardHolders`):**
   - Because `NARAFeeVaultV5` was deployed with `maxHolderFeeBps = 10,000` (`100%`) and bound via `NARAFeeIngressBindingV5` (`0x17cc74317AD75a170887F9E76e5fF09f2058d4BF`) to `NARARewardIngressV5`, the `2-of-3` Treasury Safe can also configure an automatic on-chain `holderFeeBps` split (`0%` to `100%`, e.g., `50/50` or `100%` to rewards, after a 7-day public governance notice) so that portion of Hook swap fees routes automatically via `forwardHolders` into 15-minute `USDC` and `NARA` epoch rewards while the remainder stays immediately routable (`0-second delay`) through `NARATreasuryFeeControllerV5`.

---

## 4. Two-Way Active Range Manager (`NARATreasuryRangeManagerV5`)

**`49,997 NARA` (`4.9997%` of total supply)** is allocated to **`NARATreasuryRangeManagerV5`** (active-pool contract [`0x221c625d2BC416460C397035C1286C1f4A4D3A7C`](https://basescan.org/address/0x221c625d2BC416460C397035C1286C1f4A4D3A7C) bound to Pool `0x4a4752...` and pre-funded with **`51.0149 NARA`**, plus legacy custody [`0xa72557fcBE56B3eC739dF3aF7b6b893B6Db4D288`](https://basescan.org/address/0xa72557fcBE56B3eC739dF3aF7b6b893B6Db4D288) holding **`49,997.00 NARA`** with its 7-day withdrawal queued at `Safe Nonce 9`, maturing `2026-11-14T14:27:48Z` for transfer into `0x221c62...`).

Unlike a single-sided liquidity wall that only sells tokens on the way up, `NARATreasuryRangeManagerV5` is a **two-way active range liquidity engine**:

- **Upside Sell Rungs (`NARA` → `USDC`):** As organic buying moves the price up through upper price bands, the Range Manager supplies `NARA` liquidity and collects **`USDC`** (`0-second delay` settlement to `Treasury Safe` when a step closes).
- **Downside Buy Rungs (`USDC` → Buys `NARA` Back):** Once `USDC` is collected from upside fills, it can be deployed into buy-side range bands below spot to **buy `NARA` back on pullbacks**, building two-way market depth and collecting LP fees in both directions.
- **Surplus & Fee Recycling Toward Committed Positions:** Net trading surplus and LP proceeds generated by the Range Manager — alongside swap fees — may be used to acquire `NARA` from the market and send it into `NARAEmissionReserveV5` (`0xf932178F24b0813C82093985F0Af6Db27Ae25930`), routed into the 15-minute reward pool, or deployed into higher-impact ecosystem mechanisms as we build — so that captured swap taxes and range liquidity proceeds are used in one way or another to benefit committed `NARA` positions *(discretionary, activity-dependent, and never promised or guaranteed)*.
- **7-Day `NARA` Withdrawal Delay → Extendable to 1 Year:**
  - While realized `USDC` is delivered with `0-second delay` and held `NARA` can be replenished into `NARAEmissionReserveV5` with `0-second delay`, any withdrawal of raw `NARA` from `NARATreasuryRangeManagerV5` to `Treasury Safe` is gated by a mandatory **7-day (`604,800s`) on-chain waiting period** at launch.
  - Keeping the waiting period at **7 days** initially ensures that if anything ever needs adjustment during early live operation, it can be safely handled—and once live operation is proven with nothing breaking, the `NARA` waiting period can be extended out to **1 year (365 days)**.
