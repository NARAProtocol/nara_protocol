# NARA Public Documentation Maintenance Rules

This repository (`NARAProtocol/nara_protocol`) is the public documentation and verification surface for NARA Protocol V5 on Base Mainnet (`8453`).

## Cross-Repository Role

- **Role:** Public documentation consumer and on-chain verification reference.
- **Upstream sources:** Verified Base Mainnet (`8453`) state, source-verified V5 contracts on BaseScan, and immutable release manifests recorded in [`docs/ROADMAP_EVIDENCE.json`](docs/ROADMAP_EVIDENCE.json).
- **Consumer rule:** Update this repository from verified upstream evidence and on-chain state. Never publish unverified addresses, draft mechanisms, or speculative claims as live protocol behavior.
- **Maintenance runbook:** [`docs/MAINTENANCE.md`](docs/MAINTENANCE.md) defines the verification and synchronization checklist.

## Verification workflow

When updating public documentation, current-state tables, or roadmap evidence:

1. Refresh roadmap/current-state hashes when [`docs/ROADMAP.md`](docs/ROADMAP.md) or [`docs/CURRENT_STATE.md`](docs/CURRENT_STATE.md) changes:
   ```bash
   npm run roadmap:hashes
   ```
2. Run the local documentation and roadmap verification suite:
   ```bash
   npm run verify
   npm run verify:roadmap:upstream
   npm run verify:external
   git diff --check
   ```
3. Optional live Base RPC bytecode check:
   ```bash
   BASE_RPC_URL=https://mainnet.base.org npm run verify:onchain
   ```
4. Commit on a dedicated branch (`docs/<topic>`) with a verified signature, open a pull request, and wait for the `Documentation / verify` status check to pass before merging.

## Non-negotiable rules

- **Source of truth:** Every contract address, parameter, and custody figure must match verified Base Mainnet (`8453`) state and [`verification/deployment.json`](verification/deployment.json).
- **Canonical token & domain:** The sole canonical NARA token on Base Mainnet is `0x91FB78A9F46B67f54BbD4489941d19666b2fAe0f` (`1,000,000 NARA` fixed supply). The canonical primary domain is `https://naraprotocol.io`. Never reference retired historical tokens or deprecated `.com` / `.pro` domains.
- **Language:** All documentation, comments, and commit messages in this repository must be written in clear, accurate English.
- **Tone & legal discipline:** Describe smart-contract mechanics neutrally and factually in accordance with [`LEGAL.md`](LEGAL.md). Never promise APY, yield, guaranteed returns, or price floors.
- **No secrets or build artifacts:** Never commit `.env` files, private keys, RPC credentials, `node_modules/`, or local environment files.
