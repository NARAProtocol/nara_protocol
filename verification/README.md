# Public verification package

This directory provides machine-readable deployment and verification metadata for **NARA Protocol V5** on **Base Mainnet (Chain ID `8453`)** alongside the archived v4 reference source snapshot.

## What is included

- `deployment.json` — verified Base Mainnet (`8453`) NARA Protocol V5 contract addresses, runtime code hashes (`codehash`), bytecode sizes, `2-of-3` Gnosis Safe custody, canonical Uniswap v4 Pool ID (`0x3bd8b60dc9eb37f00afa57585232e4018ae661b2dbd5318562183a67a07ac758`), and token constants at block `53,422,831` (`2026-11-02`).
- `release.json`, `engine-constructor.json`, `sources/`, and `artifacts/` — historical reference artifacts preserved for SHA-256 verification reproducibility.

Use the complete 34-contract V5 table in [Current state](../docs/CURRENT_STATE.md) for direct BaseScan explorer links.

## Running documentation & evidence verification

```powershell
npm run verify
```

## Limits

This is an evidence package, not an audit, warranty, endorsement, or instruction to transact. It does not prove economic safety, current liquidity depth, or legal compliance.
