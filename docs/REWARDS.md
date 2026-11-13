# 15-Minute Epoch Rewards & Time Commitments

NARA Protocol V5 replaces continuous block-by-block inflation and manual team distributions with **`NARAEpochEngineV5`** (`0xd93FbEbFb33FAc9288125074625D4750573B1a53`), a deterministic **15-minute (`900s`) epoch engine** backed by **`949,987 NARA`** genesis reserve (**`949,923.04 NARA`** / `94.9923%` remaining at block `56,767,987`) sealed inside **`NARAEmissionReserveV5`** (`0xf932178F24b0813C82093985F0Af6Db27Ae25930`).

---

## 1. How Commitments & Quadratic Time Weight Work

When you commit `NARA` via `NARAPrincipalLedgerV5` (`0x7F866a9fbe41D54F0d9C35b6892fcf27Ea766DB2`), you choose a commitment duration from **1 day (`96` epochs / `86,400s`) to 365 days (`35,040` epochs / `31,536,000s`)**:

- **Direct Individual Commitment (`1.0 NARA` Minimum):** Committing on `NARAPrincipalLedgerV5.create(...)` requires at least **`1.0 NARA`** (`minimumPrincipal = 1e18`) and mints an individual 1:1 ERC-721 `NARAP` Position NFT directly to your wallet (`3.20 NARA` committed across active `Positions #2` & `#4` at block `56,767,987`). Position NFTs are never split, fractionalized, or pooled into shared NFTs.
- **CryptoSLIP Companion (`Commit NARA` & `0.000001+ NARA` Payment Slips):** Inside the **[CryptoSLIP App](https://slip.naraprotocol.io/?tab=nara)** (ENS/IPFS mirror: [`https://cryptoslip.eth.limo`](https://cryptoslip.eth.limo); [**Public Overview & Legal FAQ**](CRYPTOSLIP_PUBLIC_OVERVIEW_AND_LEGAL_FAQ.md)), users can commit `1.0+ NARA` via **`Commit NARA`**, harvest 15-minute rewards (`NARA`, `ETH`, `USDC`) to their wallet or directly into shareable payment links (`>= 0.1 NARA`), or use **`NARA Slip`** (`v33` `0x3f80aa68Fb4834d6E119EE1cf932C14419Cf63EB`) to send, receive, keep (`0%` fee), split payment slips with automatic change, or combine up to 10 smaller payment slips into one (`rearrangeAndPayWithPermits`) starting from **`0.000001 NARA`**.

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
- **Equal-Footing Duration-Only Mode (`1.00x` to `4.00x` Pure Duration Weight):** Every position is weighted strictly by `NARA` principal and `1.00x–4.00x` commitment duration (`NARAForgeV5` `0x84225aBaBbE7433c736925f9c0ba6f6CcB51551a` is permanently sealed with `commitsPaused = true` and bound to deterministic `NARANullEntropyAdapterV5` `0x13b06070790C0A4Ed7f90B635b18E3FEF8ADa8ef` — zero rarity rolls, zero card fusion). Accrued rewards (`NARA`, `ETH`, `USDC`) can be claimed directly or harvested in 1 tap into a `CryptoSlipNFTV32` payment voucher (`>= 0.1 NARA`), which splits atomically (`splitAndPayWithPermit` / `swapAndPay`) with automatic free change (`changeSlipId`) when paying any bill.
- **1-for-1 Principal Segregation:** Your committed `NARA` is stored inside `NARAPrincipalLedgerV5` (`0x7F866a9fbe41D54F0d9C35b6892fcf27Ea766DB2`) and is never mingled with the reward reserve.

---

## 2. 15-Minute Reward Epochs (`96 Epochs / Day`)

Every **15 minutes (`900 seconds`)**, a new epoch settles on `NARAEpochEngineV5`:

1. **Emission Release (`949,987 NARA` Reserve):** A scheduled slice of the `949,987 NARA` sealed in `NARAEmissionReserveV5` is released for the completed epoch.
2. **Hook Swap Fees (`USDC` & `NARA` via Zero-Delay `NARATreasuryFeeControllerV5` & `NARAFeeVaultV5`) + NFT Market Fees (`ETH`):**
   - **NFT Marketplace Royalties (`5% ETH`):** Every sale on `NARAPositionSaleV5` (`0x04Ac83045d26259D46400Ce6beb9bBd0641df225`) routes a `5%` (`500 bps`) `ETH` fee directly into `NARARewardIngressV5` (`0x44130CC47b886D8488041F5eaE271477D1aFA909`) → `NARARewardLedgerV5` (`0xC72671D9438388638547444524F6542b650C9264`).
   - **Zero-Delay Hook Swap Fee Routing (`USDC` & `NARA`):** The `4.63%–20%` Uniswap v4 Hook swap fees are collected in `NARAFeeVaultV5` (`0xF1f361F803895BF5cf67eC6C506dbFEf2f6E88Cf`), which is sealed directly to `NARATreasuryFeeControllerV5` (`0xB6A436b48222C94fe427ecAfB263DF9cf42646b9`). With **`0-second delay`**, the `2-of-3` `Treasury Safe` can route 100% (or any custom `50/50` / `100%` split) of `USDC` and `NARA` swap fees directly to `NARARewardIngressV5` → `NARARewardLedgerV5` for 15-minute epoch rewards, to `NARAEmissionReserveV5`, or to `NARATreasuryRangeManagerV5` (`0x221c625d2BC416460C397035C1286C1f4A4D3A7C`) to deepen two-way liquidity—and can also configure an automatic on-chain `holderFeeBps` split (`0%` to `100%`) via `NARAFeeIngressBindingV5` (`0x17cc74317AD75a170887F9E76e5fF09f2058d4BF`).
3. **Pro-Rata Weight Distribution:**
   - Because all positions operate at equal `1.0x` rarity in Equal-Footing Launch Mode (`commitsPaused = true` on `NARAForgeV5`), both the `80%` (`8,000 bps`) base pool and the `20%` (`2,000 bps`) bonus pool distribute 100% pro-rata by quadratic duration-weighted principal (`Your Weight ÷ Total Active Weight`).

---

## 3. Claiming, Recharging & Exiting

| Action | How It Works |
|---|---|
| **Claim Rewards (`claim(id, generation, asset, recipient)`)** | Claim accrued `NARA`, `ETH`, and `USDC` from completed epochs on `NARARewardLedgerV5` at any time without closing your position. |
| **Recharge Matured Position (`rechargeCommon`)** | Once your position reaches maturity, use `NARAPrincipalLedgerV5.rechargeCommon(...)` to add `NARA` principal and start a fresh commitment duration on your existing position with zero fee. |
| **Withdraw Principal (`withdrawPrincipal`)** | Anytime after maturity, withdraw **100% of your committed `NARA` principal** from `NARAPrincipalLedgerV5` with zero penalty. |
| **Sell Before Maturity (`NARAPositionSaleV5`)** | Because every commitment is a `NARAP` Position NFT (`0x8C5F088D9d09dBB90aB6F3aaA049a8FD5D5FfFDA`), you can list and sell your active position for native `ETH` on `NARAPositionSaleV5` (`0x04Ac83045d26259D46400Ce6beb9bBd0641df225`) at any time. |

---

## 4. Important Disclosures

- **No Fixed APY:** Epoch rewards depend on total active weight in the pool, the emission schedule, and actual protocol trading/marketplace volume. NARA does not promise a fixed APY or guaranteed dollar return.
- **Unallocated Epochs:** If an epoch passes with zero active weight across the entire protocol, no emission is lost—it remains inside `NARAEmissionReserveV5`.
