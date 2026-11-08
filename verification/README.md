# Public verification package

This directory provides machine-readable deployment and verification metadata for **NARA Protocol V5** on **Base Mainnet (Chain ID `8453`)** alongside the archived v4 reference source snapshot.

## What is included

- `deployment.json` — verified Base Mainnet (`8453`) NARA Protocol V5 contract addresses (all 35 production contracts + legacy Range Manager custody), runtime code hashes (`codehash`), bytecode sizes, `2-of-3` Gnosis Safe custody, canonical Uniswap v4 Pool ID (`0x4a475299ef674bcc3d2c87c3917cfbecd38cf7237646a3553e37daba67da6e5f`), and token constants at block `54,778,829` (`2026-11-08`).
- `release.json`, `engine-constructor.json`, `sources/`, and `artifacts/` — historical reference artifacts preserved for SHA-256 verification reproducibility.

Use the complete 35-contract V5 table in [Current state](../docs/CURRENT_STATE.md) for direct BaseScan explorer links.

## Running documentation & evidence verification

```powershell
npm run verify
```

## Limits

This is an evidence package, not an audit, warranty, endorsement, or instruction to transact. It does not prove economic safety, current liquidity depth, or legal compliance.
