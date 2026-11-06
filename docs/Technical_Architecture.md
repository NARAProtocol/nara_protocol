# NARA Protocol V5 Technical Architecture

NARA Protocol V5 is a modular smart-contract suite compiled with **Solidity `0.8.37`** (Cancun EVM, `viaIR`, 34 production contracts) and deployed on **Base Mainnet (`8453`)**.

Every module follows a strict **single-responsibility architecture**: user principal custody, epoch reward reserves, swap fee collection, protocol-owned liquidity, and NFT secondary-market escrow live in separate, isolated contracts with immutable cross-bindings.

---

## System Architecture Diagram

```text
+-----------------------------------------------------------------------------------+
|                            NARA PROTOCOL V5 (BASE 8453)                           |
+-----------------------------------------------------------------------------------+

  [ User Wallet / CryptoSLIP ]
        |               |
        | (1) Swap      | (2) Commit NARA (1-365 Days)
        v               v
  +-----------+   +-----------------------+      Mints      +-----------------------+
  | Uniswap   |   |  NARAPrincipalLedger  | --------------> |  NARAPositionNFTV5    |
  | v4 Pool   |   |  + NARAEpochEngineV5  |                 |  (0x8C5F088D...fFDA)  |
  +-----------+   +-----------------------+                 +-----------------------+
        |               |               |                       |               |
        v               | 1:1 Principal | 15m Emissions         | On-Chain SVG  | Native ETH
  +-----------+         v               v                       v               v
  | Liquidity |   +------------+  +------------+        +--------------+  +--------------+
  | Hook V5   |   | Principal  |  | Emission   |        | Renderer V5  |  | PositionSale |
  | (4.63-20%)|   | Ledger V5  |  | Reserve V5 |        | + Card V5    |  | V5 (95% /    |
  +-----------+   | (Segregated|  | (949,987   |        | + FrameArtV5 |  |  5% ETH)     |
        |         |  Custody)  |  |  NARA)     |        +--------------+  +--------------+
        v         +------------+  +------------+                                |
  +-----------+                         |                                       | 5% ETH
  | FeeVault  |                         v                                       |
  | V5        |                 +-----------------------+                       |
  +-----------+                 |  NARARewardLedgerV5   | <---------------------+
        |                       |  (NARA + ETH + USDC)  | <---+
        | 100% POL (Launch)     +-----------------------+     |
        v                                                     |
  +-----------+                                         +-----------------------+
  | POL       |                                         |  NARARewardIngressV5  |
  | PositionV5|                                         |  (0x44130CC4...A909)  |
  +-----------+                                         +-----------------------+
```

---

## Module Breakdown & Security Invariants

### 1. Token Layer (`NARATokenV5`)
- **Address:** [`0x91FB78A9F46B67f54BbD4489941d19666b2fAe0f`](https://basescan.org/address/0x91FB78A9F46B67f54BbD4489941d19666b2fAe0f)
- **Design:** Pure ERC-20 + EIP-2612 Permit + ERC-3156 Flash Lender + ERC-1363 + Multicall.
- **Invariants:**
  - Settled `totalSupply() == MAX_SUPPLY == 1,000,000e18` at the end of every transaction (no external `mint` or `burn` functions exist; bounded ERC-3156 flash mints are atomically burned within the same transaction, and core ledgers enforce `totalSupply() == 1,000,000e18` via `FlashActive()` guards).
  - Zero admin/owner contract state (does not inherit `Ownable`; no `owner()`, pause, blacklist, or setter functions exist).
  - `FLASH_FEE_SINK() == 0xf932178F24b0813C82093985F0Af6Db27Ae25930` (`NARAEmissionReserveV5`), permanently sealed (`MAX_FLASH_LOAN = 100,000e18`, `FLASH_FEE_BPS = 10`).

### 2. Core Commitment & Epoch Layer
- **`NARAEmissionReserveV5` ([`0xf932178F24b0813C82093985F0Af6Db27Ae25930`](https://basescan.org/address/0xf932178F24b0813C82093985F0Af6Db27Ae25930)):**
  - Holds **`949,987 NARA`** (`94.9987%` of total supply).
  - Permanently bound (`coreBound == true`, `bindingsSealed == true`) to `NARAEpochEngineV5`. No governance key or Safe can withdraw or redirect reserve tokens.
- **`NARAPrincipalLedgerV5` ([`0x7F866a9fbe41D54F0d9C35b6892fcf27Ea766DB2`](https://basescan.org/address/0x7F866a9fbe41D54F0d9C35b6892fcf27Ea766DB2)):**
  - Holds user-committed `NARA` 1-for-1 in complete isolation from reward funds (`create`, `rechargeCommon`, `rechargeAwarded`, `withdrawPrincipal`).
  - Constructor children & lens: `NARAPrincipalAdmissionV5` (`0x319f02F0a1cb2b18DA0C268231ECa3C9dA252ca0`), `NARALifecycleLedgerV5` (`0x3F2987fE6A5418F4DB415Fd08E0f7567F010f043`), and `NARAPrincipalLensV5` (`0xDCf87e4ba3706E3ac94b10A7BD157Baf64fFE6d0`).
  - Invariant: `NARA.balanceOf(PrincipalLedger)` always covers 100% of active user principal.
- **`NARAEpochEngineV5` ([`0xd93FbEbFb33FAc9288125074625D4750573B1a53`](https://basescan.org/address/0xd93FbEbFb33FAc9288125074625D4750573B1a53)) & `NARAEmissionModelV5` ([`0xd26b3c23d677b2DE82722DB5e687744600d4A231`](https://basescan.org/address/0xd26b3c23d677b2DE82722DB5e687744600d4A231)):**
  - Immutable policy (`policyHash = 0xb13b7c804be5f17c0b39753d85a987a28f95d2ca48a7ad2030c0fa1278c1a773`, `emissionConfigurationHash = 0xe731e21e8fc64daa3f6a6f113078346602d41c738be5f53439014930565dbffa`):
    - `epochSeconds = 900` (15 minutes; `RELEASE_HORIZON_EPOCHS = 140,160`).
    - `rewardIndexScale = 1e27`, `activationDelay = 8` epochs (2 hours), `maxAdvance = 48` epochs.
    - `minDuration = 96` epochs (1 day), `maxDuration = 35,040` epochs (365 days), `durationCurve = 1` (`V4Quadratic`).
    - `earlyExitEnabled = false`, `earlyExitBps = 0`.
    - `minimumPrincipal = 1e18` (`1.0 NARA` per Position NFT on-chain; `0.1 NARA` shared Grid slots and payment Slips supported via CryptoSLIP).
- **`NARARewardLedgerV5` ([`0xC72671D9438388638547444524F6542b650C9264`](https://basescan.org/address/0xC72671D9438388638547444524F6542b650C9264)) & `NARARewardIngressV5` ([`0x44130CC47b886D8488041F5eaE271477D1aFA909`](https://basescan.org/address/0x44130CC47b886D8488041F5eaE271477D1aFA909)):**
  - Multi-asset reward accounting supporting `NARA`, native `ETH`, and `USDC` (`RARITY_SHARE_BPS = 2,000` / `20%` rarity share and `80%` base weight share; constructor child `NARARewardCreditLedgerV5` at `0x0B98eb99b8E78c216632fADa9ad6ECB4fCFbDf4B` and read-only lens `NARARewardLensV5` at `0x4a5e7ec22d34885334deA050679f01a030a635Bf`).
  - O(1) prefix-sum epoch checkpointing so users can claim rewards across completed 15-minute epochs in a single low-gas transaction, or recharge matured positions directly on `NARAPrincipalLedgerV5` (`rechargeCommon` / `rechargeAwarded`).
- **`NARAForgeV5` ([`0x84225aBaBbE7433c736925f9c0ba6f6CcB51551a`](https://basescan.org/address/0x84225aBaBbE7433c736925f9c0ba6f6CcB51551a)):**
  - Optional VRF rarity roll and 5-position fusion module (`commitsPaused = true` at launch; paired with `NARAForgeQuoteV5` `0x3fA5c60A9d7A2A1B09Ec40a20593D5Ad26022Bbb`, `NARAEntropyAdapterV5` `0x9fAf0606c62cA28d34d76e1710BF6E4f523fda5F`, and `NARANullEntropyAdapterV5` `0x13b06070790C0A4Ed7f90B635b18E3FEF8ADa8ef`).

### 3. Position NFT & Secondary Market Layer
- **`NARAPositionNFTV5` ([`0x8C5F088D9d09dBB90aB6F3aaA049a8FD5D5FfFDA`](https://basescan.org/address/0x8C5F088D9d09dBB90aB6F3aaA049a8FD5D5FfFDA)):**
  - ERC-721 token (`NARAP`) minted on commitment and retired on principal withdrawal (paired with read-only lens `NARAPositionLensV5` at `0x4887303fba121a7B99A964B4e57903e688aD1e45`). Ownership of the NFT controls the underlying principal and unclaimed rewards.
- **`NARAPositionCardV5` ([`0x12B9F23C24a4A0F29cA66F79183ed4C3f07588F5`](https://basescan.org/address/0x12B9F23C24a4A0F29cA66F79183ed4C3f07588F5)) & `NARAPositionRendererV5` ([`0x5Fd79Fc807B0e3d1e04A818f304526F8954dbd24`](https://basescan.org/address/0x5Fd79Fc807B0e3d1e04A818f304526F8954dbd24)):**
  - Pure on-chain `1000×1000` brown mineral SVG renderer (with constructor children `NARAFrameArtV5` `0x2fe91CF40a1392b4149fc8ffffE22393d1fdFF23` and `NARAPositionStatsReaderV5` `0x7aD6Eab12F6DBa36810c6c94C259d07fA3E043c2`) displaying live principal, multiplier, tier badge, and countdown progress with zero external IPFS/server dependencies.
- **`NARAPositionSaleV5` ([`0x04Ac83045d26259D46400Ce6beb9bBd0641df225`](https://basescan.org/address/0x04Ac83045d26259D46400Ce6beb9bBd0641df225)):**
  - Non-custodial native-`ETH` marketplace (`FEE_BPS = 500` / `5%`, routed automatically to `NARARewardIngressV5`; constructor child `saleCreditLens` at `0x26b481f1545D9912D39693D7F8E589F82835e03d`).

### 4. Uniswap v4 Liquidity & Range Layer
- **`NARALiquidityHookV5` ([`0x201fBD2839bEc513040024b37dAe97B401E96acC`](https://basescan.org/address/0x201fBD2839bEc513040024b37dAe97B401E96acC)):**
  - Uniswap v4 `beforeSwap` / `afterSwap` dynamic fee hook on Pool ID `0x3bd8b60dc9eb37f00afa57585232e4018ae661b2dbd5318562183a67a07ac758` (paired with `NARAHookFeeCalculatorV5` `0x989aE21D79D9750A6528F1FCc4c2b331BF2D59d4` and `NARAPoolOracleV5` `0xA2151333BDD77DF2E058f9cE274F63D2e48A5553`).
- **`NARAFeeVaultV5` ([`0xe63b4BaAF873FC57859bfe13e0e8cFccAaB6AddE`](https://basescan.org/address/0xe63b4BaAF873FC57859bfe13e0e8cFccAaB6AddE)) & `NARAPOLPositionV5` ([`0x01EF9de9f4e9197F2A3944b5B34A90eA2f558b64`](https://basescan.org/address/0x01EF9de9f4e9197F2A3944b5B34A90eA2f558b64)):**
  - Receives Hook swap fees (`USDC` and `NARA`). At launch (`Phase 1`), 100% of fees compound into permanent Uniswap v4 protocol-owned liquidity (`NARAPOLPositionV5`, sized via `NARALiquiditySizerV5` `0x46B486a300190df823C5f1E4D04c100813fB0843`, budgeted via `NARACapitalBudgetV5` `0x6f5f586Bd4F14e47F432264D88Fe9A6A6A80552B`, and compounded via `NARACapitalPolicyV5` `0xC6b5471ADadcf66c2375EC8600bb7a3D85C73e45`). As soon as target liquidity depth is built (`Phase 2`), `NARAFeeVaultV5` (via `NARAFeeIngressBindingV5` `0x8f41d6427B25525fB863203c78FF9050B3bd0DBC`) redirects swap tax into `NARARewardIngressV5` → `NARARewardLedgerV5` for 15-minute epoch rewards.
- **`NARATreasuryRangeManagerV5` ([`0xa72557fcBE56B3eC739dF3aF7b6b893B6Db4D288`](https://basescan.org/address/0xa72557fcBE56B3eC739dF3aF7b6b893B6Db4D288)):**
  - Holds `49,997 NARA` (`4.9997%` of supply) as a two-way active range liquidity engine: deploys `NARA` sell rungs above spot to collect `USDC`, and uses collected `USDC` to deploy buy rungs and **buy `NARA` back** on dips. `NARA` withdrawals are protected by a **7-day withdrawal delay** at launch (extendable to **1 year / 365 days** once live operation is verified).
