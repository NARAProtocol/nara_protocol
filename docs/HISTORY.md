# Public Version History (`HISTORY.md`)

## Current Active Protocol Line: **NARA Protocol V5**

**NARA Protocol V5** is the active production protocol line on **Base Mainnet (Chain ID `8453`)**. All current contract addresses, supply allocations, and pool parameters are documented in **[Current On-Chain State (`CURRENT_STATE.md`)](CURRENT_STATE.md)**.

---

## Release Log

### `docs-v5.0.0` (Current — NARA V5 Mainnet Architecture)
- Updated the entire public documentation suite to reflect the **35-contract NARA Protocol V5 production deployment** on Base Mainnet (`8453`, verified through block `54,778,829`).
- Documented the verified on-chain allocation of the fixed **`1,000,000 NARA`** supply:
  - **`949,987 NARA` (`94.9987%`)** sealed in `NARAEmissionReserveV5` (`0xf932178F24b0813C82093985F0Af6Db27Ae25930`).
  - **`49,997 NARA` (`4.9997%`)** held across `NARATreasuryRangeManagerV5` (`51.0149 NARA` pre-funded on active-pool `0x221c625d2BC416460C397035C1286C1f4A4D3A7C` + `49,997 NARA` in legacy `0xa72557fcBE56B3eC739dF3aF7b6b893B6Db4D288` with 7-day withdrawal queued at `Safe Nonce 9`, maturing `2026-11-14T14:27:48Z`).
  - **`3.0 NARA` (`0.0003%`)** + `300.0 USDC` held in `Treasury Safe` (`0xe320C281c86079eA85f2Bc67864E873A61D551E3`) for the initial Uniswap v4 LP seed (`3 NARA + 300 USDC` at `$100.00 / NARA`).
  - **`13.0 NARA` (`0.0013%`)** committed in live Base Mainnet positions on `NARAPrincipalLedgerV5` (`0x7F866a9fbe41D54F0d9C35b6892fcf27Ea766DB2`, including `Position #1` at `1.0 NARA`) and E2E verification float.
  - **`0%` team allocation, `0%` VC allocation, `0%` deferred bonds.**
- Added comprehensive guides for **15-minute (`900s`) reward epochs** (`NARAEpochEngineV5`), **liquid 1:1 Position NFTs (`NARAP`)** rendered on-chain (`NARAPositionRendererV5` + `NARAPositionCardV5`), the native-`ETH` marketplace (`NARAPositionSaleV5`), the **Zero-Delay Uniswap v4 Fee Periphery (`NARAFeeVaultV5` + `NARATreasuryFeeControllerV5`)**, and the **[CryptoSLIP App](https://cryptoslip-g29s.4everland.app/?v=cs-1794113891779)** (`Commit NARA`, 1-tap reward harvesting into slips, and fractional `NARA` payment slips from `0.001 NARA`).

### `docs-v4.0.0` – `docs-v4.0.2` (Archived August 2026 V4 Line)
- Documented the initial August 2026 V4 deployment (`NARAEngine` `0x98ab...`, `NARALiquidityGrowthHook` `0x59AE...`, `NARAPositionNFTV4` `0xCcBD...`).
- The August 2026 V4 periphery contracts are now **permanently retired** and superseded by the V5 architecture. Historical V4 snapshots remain in `verification/` strictly for archival reproducibility.

### `v0.1.0-predeploy` / `v0.1.0-beta`
- Pre-deployment historical prototypes prior to mainnet launch; retained for Git history only.
