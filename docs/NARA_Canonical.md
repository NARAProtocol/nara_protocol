# What NARA Protocol V5 Is

**NARA Protocol V5** is a decentralized liquidity and time-commitment system deployed on **Base Mainnet (`8453`)**.

Instead of relying on inflationary minting, team token cliffs, or mercenary liquidity farming, NARA V5 seals **99.9984%** of its fixed **1,000,000 NARA** supply directly inside immutable smart contracts that reward long-term commitment and manage two-way pool liquidity transparently on-chain.

```text
+-------------------------------------------------------------------------+
|                        NARA PROTOCOL V5 FLYWHEEL                        |
+-------------------------------------------------------------------------+
|                                                                         |
|  1. FIXED SUPPLY (1,000,000 NARA — Block 56,767,987)                   |
|     - 949,923.04 NARA (94.9923%) in NARAEmissionReserveV5               |
|     -  49,997 NARA legacy + 51.0811 NARA active RangeManagerV5          |
|     -       0 NARA ( 0.0000%) team, VC, or private pre-sale allocation  |
|                                   |                                     |
|                                   v                                     |
|  2. UNISWAP V4 HOOK & ZERO-DELAY FEE ROUTING (4.63% -> 20% Burst Fee)   |
|     - NARAFeeVaultV5 + NARATreasuryFeeControllerV5 (0-second delay)     |
|     - Routes USDC & NARA swap fees with zero permanent tie-up to        |
|       active liquidity, NARAEmissionReserveV5, or 15-min epoch rewards  |
|                                   |                                     |
|                                   v                                     |
|  3. TIME COMMITMENTS (1 to 365 Days -> 1.00x to 4.00x Weight)           |
|     - 1-for-1 segregated principal custody in NARAPrincipalLedgerV5     |
|     - 15-minute reward epochs (96 per day) via NARAEpochEngineV5        |
|     - Multi-asset rewards: NARA + ETH + USDC                            |
|                                   |                                     |
|                                   v                                     |
|  4. LIQUID POSITION NFTs (NARAP) & CRYPTOSLIP V3.2 COMPANION            |
|     - Every 1.0+ NARA commitment mints a tradeable Position NFT         |
|     - Built-in native-ETH marketplace (95% seller / 5% rewards)         |
|     - CryptoSLIP supports Commit NARA + 0.000001+ NARA Slips (v33)      |
+-------------------------------------------------------------------------+
```

---

## Core Pillars of What We Built

### 1. Fixed Supply with Zero Team or Insider Allocations

- **Total Supply:** Exactly **1,000,000 NARA** (`0x91FB78A9F46B67f54BbD4489941d19666b2fAe0f`).
- **No Owner, No Minting:** `NARATokenV5` has no `mint()` function and no owner (`owner = 0x0`). Supply can never be inflated.
- **No Insider Allocations:** There are zero team tokens, zero investor vesting schedules, and zero off-market bond discounts.
- **99.9974% Protocol-Committed:** `949,923.04 NARA` (`94.9923%` at block `56,767,987`, funded with `949,987 NARA` at genesis) is sealed in `NARAEmissionReserveV5` for 15-minute epoch rewards, `51.0811 NARA` + `49,997 NARA` (`4.9997%`) sit in `NARATreasuryRangeManagerV5`, and `3.20 NARA` sit in `NARAPrincipalLedgerV5`.

### 2. Dynamic Hook & Zero-Delay Fee Routing (`NARAFeeVaultV5` + `NARATreasuryFeeControllerV5`)

- **Dynamic Hook Protection:** The canonical `NARA / USDC` Uniswap v4 pool (`0x4a475299ef674bcc3d2c87c3917cfbecd38cf7237646a3553e37daba67da6e5f`) is governed by `NARALiquidityHookV5` (`0x07d8F2Dfd121B10dE3176DeAb6A8C0eaa2646aCC`). Normal swaps pay a **4.63% (`463 bps`)** Hook fee (`4.92%` total with the `0.30%` LP fee), while rapid same-block volume bursts escalate up to **20.00% (`2,000 bps`)**.
- **Zero-Delay (`0s`) Fee Redemption & Routing (`NARATreasuryFeeControllerV5`):** Collected `USDC` and `NARA` swap fees enter `NARAFeeVaultV5` (`0xF1f361F803895BF5cf67eC6C506dbFEf2f6E88Cf`), which is sealed directly to `NARATreasuryFeeControllerV5` (`0xB6A436b48222C94fe427ecAfB263DF9cf42646b9`). Instead of permanently trapping fees in an un-withdrawable POL position or behind multi-day delays, the `2-of-3` `Treasury Safe` can redeem and route 100% (or any custom `50/50` / `100%` split) of `USDC` and `NARA` swap fees with **`0-second delay`** (`sweepToSafe`, `withdrawAllTo`, `withdrawTo`) to deepen active two-way liquidity in `NARATreasuryRangeManagerV5`, replenish `NARAEmissionReserveV5`, or stream directly into `NARARewardIngressV5` → `NARARewardLedgerV5` for 15-minute epoch rewards.
- **Configurable Automatic Holder Split (`NARAFeeIngressBindingV5`):** `NARAFeeVaultV5` is also pre-bound via `NARAFeeIngressBindingV5` (`0x17cc74317AD75a170887F9E76e5fF09f2058d4BF`) to `NARARewardIngressV5` (`0x44130CC47b886D8488041F5eaE271477D1aFA909`), allowing the `Treasury Safe` to configure an automatic on-chain `holderFeeBps` split (`0%` to `100%`, after a 7-day governance notice) that routes that portion of Hook swap taxes automatically into 15-minute epoch rewards.

### 3. Two-Way Active Range Manager (`NARATreasuryRangeManagerV5`)

- **Not Single-Sided — Sells Upside & Buys Back with `USDC`:** `NARATreasuryRangeManagerV5` (active-pool contract `0x221c625d2BC416460C397035C1286C1f4A4D3A7C` holding `51.0811 NARA` = `46.2471 NARA` liquid + `4.8340 NARA` across `12` live Uniswap v4 upside sell rungs, plus legacy custody `0xa72557fcBE56B3eC739dF3aF7b6b893B6Db4D288` holding `49,997 NARA` with its 7-day withdrawal queued at `Safe Nonce 9`, maturing `2026-11-14T14:27:48Z` for transfer to `0x221c62...`) places bounded `NARA` sell rungs above spot to collect **`USDC`** (`0-second delay` settlement to `Treasury Safe`), and then uses collected **`USDC`** to place buy-side rungs that **buy `NARA` back** on pullbacks.
- **7-Day `NARA` Withdrawal Delay → Extendable to 1 Year:** While `USDC` proceeds settle with `0-second delay` and held `NARA` can replenish `NARAEmissionReserveV5` with `0-second delay`, withdrawing raw `NARA` from the Range Manager requires a **7-day on-chain waiting period** at launch—and once live operation is verified with nothing breaking, the `NARA` waiting period can be extended out to **1 year (365 days)**.

### 4. Segregated Principal Custody, 15-Minute Epochs & Liquid Position NFTs (`NARAP`)

- **1-for-1 Principal Safety:** When you commit `NARA` (`1.0 NARA` minimum) for **1 to 365 days**, your principal is stored 1-for-1 in `NARAPrincipalLedgerV5` (`0x7F866a9fbe41D54F0d9C35b6892fcf27Ea766DB2`), completely separated from reward reserves and swap fees.
- **Equal-Footing Quadratic Time Weight (`1.00x` to `4.00x`):** Longer commitments receive up to a `4.00x` weight multiplier (`V4Quadratic` curve) across **96 epochs per day** (`15 minutes` each) on `NARAEpochEngineV5` (`0xd93FbEbFb33FAc9288125074625D4750573B1a53`). Every `NARAPositionNFTV5` (`NARAP`) is an individual 1:1 commitment receipt weighted strictly by `NARA` committed and duration chosen (`NARAForgeV5` has `commitsPaused = true` — zero rarity rolls or card fusion), whereas `CryptoSlipNFTV32` payment voucher NFTs split automatically with a free change voucher (`changeSlipId`) whenever a bill is paid.
- **Built-In Native-`ETH` NFT Market:** Every commitment mints a tradeable ERC-721 `NARAP` Position NFT (`0x8C5F088D9d09dBB90aB6F3aaA049a8FD5D5FfFDA`) that can be sold before maturity on `NARAPositionSaleV5` (`0x04Ac83045d26259D46400Ce6beb9bBd0641df225`) for native `ETH` (`95%` to seller, `5%` to epoch rewards).

### 5. How CryptoSLIP V3.2 Works with NARA V5

- **Two Integrated `NARA` Modes in the [CryptoSLIP App](https://slip.naraprotocol.io)** (ENS/IPFS mirror: [`https://cryptoslip.eth.limo`](https://cryptoslip.eth.limo); [**Public Overview & 25-Question Legal FAQ**](CRYPTOSLIP_PUBLIC_OVERVIEW_AND_LEGAL_FAQ.md)):
  1. **`Commit NARA` (`1.0+ NARA` Individual Position NFTs):** Commit `1.0+ NARA` across canonical duration horizons (`1d` to `365d`) on `NARAPrincipalLedgerV5` to mint your own `NARAP` Position NFT, view live 15-minute multi-asset rewards (`NARA`, `ETH`, `USDC`), tap **`Collect`** to harvest rewards to your wallet or wrap them directly into a shareable CryptoSLIP payment link (`>= 0.1 NARA`), and tap **`Get back`** at maturity to withdraw 100% of your `NARA` 1-for-1 (or as a slip to send).
  2. **`NARA Slip` (`0.000001+ NARA` Gasless Payment Vouchers):** Send, receive, keep (`0%` fee), split *payment slips* with automatic change (`splitAndPayWithPermit`), combine up to 10 smaller payment slips into one (`rearrangeAndPayWithPermits`), or swap `USDC`, `ETH`, `cbBTC`, and `NARA` inside active `v33` `CryptoSlipTradeRouterV32` (`0x2069CA17D45d3421D28f15F20262575333CECF51`) / preserved `v32` (`0x295E72cB3dc09582F32e0fEB7e0e650752219a7f`) starting from **`0.000001 NARA`** (`$0.10 USDC`, `100 sats cbBTC`, `0.000001 ETH`; `0%` token transfer tax on off-DEX slip operations; official `NARA` swaps route `100%` through Uniswap v4 `NARALiquidityHookV5`).
