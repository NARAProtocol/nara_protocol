# Public verification package

This directory lets a developer inspect the deployed NARA v4 code without
access to private operational repositories.

## What is included

- `deployment.json` — sanitized addresses, transaction evidence, runtime code
  hashes, pool state, and token constants
- `engine-constructor.json` — decoded constructor configuration, CREATE2 salt,
  creation-code hash, and explorer verification evidence
- `release.json` — exact source commit, compiler settings, dependency versions,
  source hashes, and artifact hashes
- `sources/` — dependency-complete NARA source files used by the deployed
  entrypoints
- `artifacts/` — generated ABIs and bytecode from the exact release commit

The snapshot was generated from immutable deployed-source commit
`027af3f06bbe6dea2c187dfd8062e50c228f1c35`, compiled with Solidity 0.8.34.
It excludes private keys, RPC URLs, environment files, signing procedures,
deployment automation, and unrelated undeployed contracts.

## What the package proves

The package makes the documented source and integration interfaces public. The
runtime code hashes in `deployment.json` were checked on Base at block
`49736809`. A matching runtime hash proves that code at an address has not
changed since that checkpoint.

Compiler artifacts can contain immutable placeholders, so an artifact's generic
`deployedBytecode` should not be hashed and compared directly with deployed code
without applying the constructor's immutable values.

## Explorer verification

All eight NARA contracts in the package publish source through Basescan. The
engine reports the NARAEngine contract name and Solidity 0.8.34 compiler. The
launcher created the engine internally with CREATE2, so the separate constructor
record preserves the address-derivation evidence.

The exact engine creation code was reconstructed locally and matched the launch
transaction byte-for-byte. Its CREATE2 hash predicted the deployed engine
address. See [`engine-constructor.json`](engine-constructor.json) for the public
constructor and explorer evidence.

Use the address table in
[Current state](../docs/CURRENT_STATE.md) for direct explorer links.

## Reproducing the export

The export script requires a local checkout of the private engineering
repository at the exact release commit:

```powershell
node scripts/export-verification.mjs "C:\absolute\path\to\release-worktree"
npm run verify
```

The script refuses to export a different commit. It recursively includes only
local v4 dependencies of the eight deployed entrypoints and sanitizes generated
artifacts before writing them.

To verify the published runtime code against the exact Base checkpoint, use a
trusted Base mainnet RPC endpoint:

```powershell
$env:BASE_RPC_URL = "your Base mainnet RPC endpoint"
npm run verify:onchain
Remove-Item Env:BASE_RPC_URL
```

The script does not print or store the endpoint. It reads each contract's code at
block `49736809` and compares a SHA-256 digest with `deployment.json`.

## Limits

This is an evidence package, not an audit, warranty, endorsement, or instruction
to transact. It does not prove economic safety, correct administration, current
liquidity depth, whole-product availability, or legal compliance. Pool
activation evidence is point-in-time and is not a promise that any trade size
can be executed or exited at a particular price.
