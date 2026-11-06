# 15-Minute Epoch Rewards & Time Commitments

NARA Protocol V5 replaces continuous block-by-block inflation and manual team distributions with **`NARAEpochEngineV5`** (`0xd93FbEbFb33FAc9288125074625D4750573B1a53`), a deterministic **15-minute (`900s`) epoch engine** backed by **`949,987 NARA`** (`94.9987%` of total supply) sealed inside **`NARAEmissionReserveV5`** (`0xf932178F24b0813C82093985F0Af6Db27Ae25930`).

---

## 1. How Commitments & Quadratic Time Weight Work

When you commit `NARA` via `NARAPrincipalLedgerV5` (`0x7F866a9fbe41D54F0d9C35b6892fcf27Ea766DB2`), you choose a commitment duration from **1 day (`96` epochs / `86,400s`) to 365 days (`35,040` epochs / `31,536,000s`)**:

- **Direct Individual Commitment (`1.0 NARA` Minimum):** Committing on `NARAPrincipalLedgerV5.create(...)` requires at least **`1.0 NARA`** (`minimumPrincipal = 1e18`) and mints a dedicated `NARAP` Position NFT directly to your wallet.
- **`0.1 NARA` Shared `NARA Grid` & Slips via CryptoSLIP:** Because the core smart contract enforces a `1.0 NARA` minimum per Position NFT, the **[CryptoSLIP App](https://cryptoslip-g29s.4everland.app/?v=cs-1793645949345)** ([**Public Overview & Legal FAQ**](CRYPTOSLIP_PUBLIC_OVERVIEW_AND_LEGAL_FAQ.md)) lets anyone commit **`0.1 NARA` per slot** (1 to 10 slots) into the shared 10-slot **NARA Grid** (`10 × 0.1 NARA = 1.0 NARA` Position NFT, crediting each slot **10%** of the position's 15-minute rewards and principal) or send/receive fractional `NARA` Slips via instant links and QR codes.

Your position's reward weight follows the **`V4Quadratic`** multiplier curve (`1.00x` to `4.00x`):

$$\text{Multiplier}(r) = 1 + 0.5r + 2.5r^2, \quad r = \frac{\text{durationEpochs}}{35040}$$

| Commitment Duration | Weight Multiplier | Effective Weight per `100 NARA` Committed |
|---|---:|---:|
| **1 Day** (`96` epochs — Minimum) | **`1.00x`** | `100` Weight |
| **30 Days** (`2,880` epochs) | **`1.06x`** | `106` Weight |
| **90 Days** (`8,640` epochs) | **`1.28x`** | `128` Weight |
| **180 Days** (`17,280` epochs) | **`1.85x`** | `185` Weight |
| **365 Days** (`35,040` epochs — Max) | **`4.00x`** | **`400` Weight** |

- **Longer Commitment = Up to 4x Share:** Committing `100 NARA` for 365 days gives the same base reward weight (`400`) as committing `400 NARA` for 1 day.
- **2-Hour Activation Delay (`8 Epochs`):** Every newly created position waits **8 epochs (`2 hours`)** before its weight becomes active in the epoch pool.
- **Equal-Footing Launch Mode:** Paid VRF rarity rolls and 5-position fusion (`NARAForgeV5` `0x84225aBaBbE7433c736925f9c0ba6f6CcB51551a`) are switched off at launch (`commitsPaused = true`), so every position starts as a free standard `1X` position.
- **1-for-1 Principal Segregation:** Your committed `NARA` is stored inside `NARAPrincipalLedgerV5` (`0x7F866a9fbe41D54F0d9C35b6892fcf27Ea766DB2`) and is never mingled with the reward reserve.

---

## 2. 15-Minute Reward Epochs (`96 Epochs / Day`)

Every **15 minutes (`900 seconds`)**, a new epoch settles on `NARAEpochEngineV5`:

1. **Emission Release (`949,987 NARA` Reserve):** A scheduled slice of the `949,987 NARA` sealed in `NARAEmissionReserveV5` is released for the completed epoch.
2. **Hook Swap Tax Redirected Once Liquidity Is Built (`USDC` & `NARA`) + NFT Market Fees (`ETH`):**
   - **At Launch (`Phase 1`):** 100% of the `4.63%–20%` Uniswap v4 Hook swap fees go into `NARAPOLPositionV5` to rapidly build permanent pool liquidity, while committed holders receive `NARA` reserve emissions plus the `5% ETH` marketplace fee from `NARAPositionSaleV5`.
   - **Once Target Liquidity Is Built (`Phase 2`):** `NARAFeeVaultV5` redirects the Hook swap tax (`USDC` and `NARA` collected on pool trades) straight into **`NARARewardIngressV5` → `NARARewardLedgerV5`**. From that point forward, every swap on the pool feeds **`USDC` and `NARA` rewards** directly into the 15-minute epoch distributions for active positions.
3. **80 / 20 Base & Rarity Split (`RARITY_SHARE_BPS = 2,000`):**
   - **80% (`8,000 bps`) Base Weight Pool:** Distributed pro-rata across all active positions according to their quadratic time-weighted principal.
   - **20% (`2,000 bps`) Rarity / Bonus Pool:** Distributed according to each position's rarity weight (`1.0x` standard at launch, or up to `100x` when VRF rarity rolls are active via `NARAForgeV5` and `NARAEntropyAdapterV5`).

---

## 3. Claiming, Recharging & Exiting

| Action | How It Works |
|---|---|
| **Claim Rewards (`claim(id, generation, asset, recipient)`)** | Claim accrued `NARA`, `ETH`, and `USDC` from completed epochs on `NARARewardLedgerV5` at any time without closing your position. |
| **Recharge Matured Position (`rechargeCommon` / `rechargeAwarded`)** | Once your position reaches maturity, use `NARAPrincipalLedgerV5.rechargeCommon(...)` (or `rechargeAwarded(...)` for rarity-awarded frames) to add `NARA` principal and start a fresh commitment duration on your existing position. |
| **Withdraw Principal (`withdrawPrincipal`)** | Anytime after maturity, withdraw **100% of your committed `NARA` principal** from `NARAPrincipalLedgerV5` with zero penalty. |
| **Sell Before Maturity (`NARAPositionSaleV5`)** | Because every commitment is a `NARAP` Position NFT (`0x8C5F088D9d09dBB90aB6F3aaA049a8FD5D5FfFDA`), you can list and sell your active position for native `ETH` on `NARAPositionSaleV5` (`0x04Ac83045d26259D46400Ce6beb9bBd0641df225`) at any time. |

---

## 4. Important Disclosures

- **No Fixed APY:** Epoch rewards depend on total active weight in the pool, the emission schedule, and actual protocol trading/marketplace volume. NARA does not promise a fixed APY or guaranteed dollar return.
- **Unallocated Epochs:** If an epoch passes with zero active weight across the entire protocol, no emission is lost—it remains inside `NARAEmissionReserveV5`.
