# Public verification package

This directory provides machine-readable deployment, source, and ABI verification metadata for **NARA Protocol V5** on **Base Mainnet (Chain ID `8453`)**.

## What is included

- `deployment.json` — verified Base Mainnet (`8453`) NARA Protocol V5 contract addresses (37 verified V5 deployments: all 35 core/periphery contracts + `NARAGenesisShieldVaultV5` + legacy Range Manager custody), runtime code hashes (`codehash`), bytecode sizes, `2-of-3` Gnosis Safe custody, canonical Uniswap v4 Pool ID (`0x4a475299ef674bcc3d2c87c3917cfbecd38cf7237646a3553e37daba67da6e5f`, `fee: 3000`, `tickSpacing: 60`), ERC-8021 Base Builder Codes (`bc_g71jff6u`, `bc_ea68lz8s`), and token constants verified at Base block `58672281`.
- `release.json`, `engine-constructor.json`, `sources/contracts/v5/`, and `artifacts/` — canonical `Solidity 0.8.37` V5 source snapshot and compiled entrypoint ABIs with SHA-256 reproducibility pins.

Use the V5 contract registry in [Current state](../docs/CURRENT_STATE.md) for direct BaseScan explorer links.

## Running documentation & on-chain evidence verification

```powershell
npm run verify
$env:BASE_RPC_URL = "https://base.gateway.tenderly.co"
npm run verify:onchain
```

## Limits

This is an evidence package, not an audit, warranty, endorsement, or instruction to transact. It does not prove economic safety, current liquidity depth, or legal compliance.
