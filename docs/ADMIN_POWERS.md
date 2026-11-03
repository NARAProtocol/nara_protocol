# Governance, Multisig Safes & Immutability (`ADMIN_POWERS`)

NARA Protocol V5 is engineered to **minimize human trust**. Core token custody, principal custody, and epoch emission rules have **zero owner (`0x0`)** and cannot be altered by anyone. Where operational tuning is required (such as liquidity management and VRF randomness), permissions are strictly bounded and split across three separate **`2-of-3` Gnosis Safes**.

---

## 1. Zero-Owner & Permanently Sealed Contracts

The following V5 contracts have **no admin owner (`owner = 0x0`)** and **permanently sealed bindings**:

| Contract | Address | Immutability Guarantee |
|---|---|---|
| **`NARATokenV5`** | [`0x91FB78A9F46B67f54BbD4489941d19666b2fAe0f`](https://basescan.org/address/0x91FB78A9F46B67f54BbD4489941d19666b2fAe0f) | `owner = 0x0`, flash-loan fee sink permanently sealed. Fixed `1,000,000 NARA` supply; cannot mint, pause, or blacklist. |
| **`NARAEmissionReserveV5`** | [`0xf932178F24b0813C82093985F0Af6Db27Ae25930`](https://basescan.org/address/0xf932178F24b0813C82093985F0Af6Db27Ae25930) | `coreBound = true` and `bindingsSealed = true` to `NARAEpochEngineV5`. Holds `949,987 NARA` (`94.9987%`); no admin withdrawal function exists. |
| **`NARAPrincipalLedgerV5`** | [`0x7F866a9fbe41D54F0d9C35b6892fcf27Ea766DB2`](https://basescan.org/address/0x7F866a9fbe41D54F0d9C35b6892fcf27Ea766DB2) | Permanently bound to `NARAEpochEngineV5`. Holds user principal 1-for-1; no admin sweep of committed principal is possible. |
| **`NARAEpochEngineV5`** | [`0xd93FbEbFb33FAc9288125074625D4750573B1a53`](https://basescan.org/address/0xd93FbEbFb33FAc9288125074625D4750573B1a53) | `activated = true` and `bindingsSealed = true`. Epoch duration (`900s`), commitment durations (`96–35,040` epochs / `1–365d`), quadratic curve (`1x–4x`), and `80/20` split are constructor-immutable. |
| **`NARARewardLedgerV5`** | [`0xC72671D9438388638547444524F6542b650C9264`](https://basescan.org/address/0xC72671D9438388638547444524F6542b650C9264) | Permanently bound to `NARAEpochEngineV5`. Multi-asset epoch reward balances belong exclusively to position holders. |
| **`NARARewardIngressV5`** | [`0x44130CC47b886D8488041F5eaE271477D1aFA909`](https://basescan.org/address/0x44130CC47b886D8488041F5eaE271477D1aFA909) | Permanently bound pass-through router into `NARARewardLedgerV5`. |
| **`NARAPositionSaleV5`** | [`0x04Ac83045d26259D46400Ce6beb9bBd0641df225`](https://basescan.org/address/0x04Ac83045d26259D46400Ce6beb9bBd0641df225) | Immutable `5%` (`500 bps`) market fee routed to `NARARewardIngressV5`; only the NFT owner can list or cancel their listing. |

---

## 2. Separated `2-of-3` Governance Safes

To prevent single-key compromise or conflated roles, V5 separates bounded governance across three independent **`2-of-3` Gnosis Safes**:

### A. `Treasury Safe` (`0xe320C281c86079eA85f2Bc67864E873A61D551E3`)
- **Modules Governed:** `NARALiquidityHookV5`, `NARAFeeVaultV5`, `NARAPOLPositionV5`, `NARACapitalBudgetV5`, `NARATreasuryRangeManagerV5`, and guardian pause on `NARAForgeV5`.
- **What It Can Do:**
  - Adjust the Hook fee curve within hard-coded contract caps (never exceeding `20.00%` / `2,000 bps`, subject to a **7-day waiting period**).
  - Adjust the `NARAFeeVaultV5` split so that once target permanent POL (`NARAPOLPositionV5`) depth is built, Hook swap taxes (`USDC` and `NARA`) are redirected to `NARARewardIngressV5` for 15-minute epoch rewards.
  - Manage two-way range liquidity on `NARATreasuryRangeManagerV5` (`49,997 NARA`): place upside `NARA` sell rungs to collect `USDC`, and use collected `USDC` to place buy rungs that buy `NARA` back on pullbacks.
  - Schedule a `NARA` withdrawal from the Range Manager subject to a mandatory **7-day (`604,800s`) public waiting period** at launch (designed to be extended to **1 year / 365 days** once live operation is verified with nothing breaking).
- **What It Cannot Do:**
  - Cannot touch user principal in `NARAPrincipalLedgerV5`.
  - Cannot withdraw `NARA` from `NARAEmissionReserveV5`.
  - Cannot remove permanent liquidity from `NARAPOLPositionV5`.

### B. `OA-3` VRF Governance Safe (`0x9d415e070AF8e93890dcCaE27755C66E3A313f0F`)
- **Module Governed:** `NARAForgeV5` (`0x84225aBaBbE7433c736925f9c0ba6f6CcB51551a`, paired with `NARAEntropyAdapterV5` `0x9fAf0606c62cA28d34d76e1710BF6E4f523fda5F` and `NARANullEntropyAdapterV5` `0x13b06070790C0A4Ed7f90B635b18E3FEF8ADa8ef`).
- **What It Can Do:** Configure or switch the randomness adapter (`NARANullEntropyAdapterV5` deterministic mode vs. `NARAEntropyAdapterV5` Chainlink VRF v2.5 mode) after a **7-day waiting period**.
- **What It Cannot Do:** Cannot prevent users from committing, claiming base rewards, or withdrawing their principal at maturity.

### C. `C1` Presentation Governor Safe (`0x0939BE9a5359764C2334a70A13eC567C7e38E017`)
- **Modules Governed:** `NARAPositionNFTV5` (`0x8C5F088D9d09dBB90aB6F3aaA049a8FD5D5FfFDA`, paired with `NARAPositionRendererV5` `0x5Fd79Fc807B0e3d1e04A818f304526F8954dbd24` and `NARAPositionCardV5` `0x12B9F23C24a4A0F29cA66F79183ed4C3f07588F5`).
- **What It Can Do:** Update the non-custodial visual renderer on `NARAPositionNFTV5` if explorer display standards evolve, until presentation is frozen.
- **What It Cannot Do:** Cannot transfer, burn, or modify the ownership or balances of any Position NFT.
