# Public Version History (`HISTORY.md`)

## Current Active Protocol Line: **NARA Protocol V5**

**NARA Protocol V5** is the active production protocol line on **Base Mainnet (Chain ID `8453`)**. All current contract addresses, supply allocations, and pool parameters are documented in **[Current On-Chain State (`CURRENT_STATE.md`)](CURRENT_STATE.md)**.

---

## Release Log

### `docs-v5.1.0` (Current — Live Uniswap v4 Trading, Range Rungs, V5 Console & CryptoSLIP `v33`)
- Synchronized the entire public documentation suite with **Base Mainnet Block `56,767,987` (`2026-11-13`, wall epoch `1035`)**:
  - **`949,923.04 NARA` (`94.9923%`)** remaining in `NARAEmissionReserveV5` (`0xf932178F24b0813C82093985F0Af6Db27Ae25930`) from the `949,987 NARA` genesis allocation as 15-minute epochs stream live emissions.
  - **`49,997 NARA` (`4.9997%`)** in legacy `NARATreasuryRangeManagerV5` (`0xa72557fcBE56B3eC739dF3aF7b6b893B6Db4D288`, queued for 7-day migration at `Safe Nonce 9`, maturing `2026-11-14T14:27:48Z`) + **`51.0811 NARA`** in active-pool `NARATreasuryRangeManagerV5` (`0x221c625d2BC416460C397035C1286C1f4A4D3A7C`: `46.2471 NARA` liquid + `4.8340 NARA` across **`12` active Uniswap v4 upside sell rungs**).
  - **Canonical Uniswap v4 `NARA / USDC` Pool (`0x4a475299ef674bcc3d2c87c3917cfbecd38cf7237646a3553e37daba67da6e5f`) live and trading (`tradingPaused = false`)**, seeded by `Treasury Safe` (`0xe320C281c86079eA85f2Bc67864E873A61D551E3`, `Safe Nonce 23`) and routed `100%` through `NARALiquidityHookV5` on [`https://naraprotocol.io`](https://naraprotocol.io) and [`https://slip.naraprotocol.io`](https://slip.naraprotocol.io).
  - **`3.20 NARA`** committed 1-for-1 in `NARAPrincipalLedgerV5` (`0x7F866a9fbe41D54F0d9C35b6892fcf27Ea766DB2`, `Positions #1–#4` minted on `NARAPositionNFTV5`, `Positions #2` & `#4` active `>1d`, including `Treasury Safe` `Position #4`: `2.20 NARA` for `365d` at `4.00x`).
  - Documented the interactive V5 console and live Cloudflare Pages APIs (`/api/supply`, `/api/quote`, `/api/leaderboard`, `#buyNaraModal` V4-Hook swap engine) alongside **CryptoSLIP `v33`** (`0x3f80aa68Fb4834d6E119EE1cf932C14419Cf63EB`, micro-minimums `$0.10 USDC`, `100 sats cbBTC`, `0.000001 ETH`, `0.000001 NARA` at [`https://slip.naraprotocol.io`](https://slip.naraprotocol.io)) and preserved **`v32`** (`0x38BF0321FA7489576978353a6a8da4A3e85C2F18`).

### `docs-v5.0.0` (Genesis V5 Mainnet Deployment — Block `54,778,829`)
- Initial public release covering the **35-contract NARA Protocol V5 production deployment** on Base Mainnet (`8453`), the **`949,987 NARA`** genesis reserve funding, **`1.0+ NARA`** Position NFT (`#1`) proof, and zero-delay Hook fee periphery (`NARAFeeVaultV5` + `NARATreasuryFeeControllerV5`).

### `docs-v4.0.0` – `docs-v4.0.2` (Archived August 2026 V4 Line)
- Documented the initial August 2026 V4 deployment (`NARAEngine` `0x98ab...`, `NARALiquidityGrowthHook` `0x59AE...`, `NARAPositionNFTV4` `0xCcBD...`).
- The August 2026 V4 periphery contracts are now **permanently retired** and superseded by the V5 architecture. Historical V4 snapshots remain in `verification/` strictly for archival reproducibility.

### `v0.1.0-predeploy` / `v0.1.0-beta`
- Pre-deployment historical prototypes prior to mainnet launch; retained for Git history only.
