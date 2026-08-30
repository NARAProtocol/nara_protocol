# NARA public v4 state synchronization

```text
Change-ID: NARA-20260830-public-v4-state-sync
Origin remote: NARAProtocol/nara_protocol_v4
Origin commit: 027af3f06bbe6dea2c187dfd8062e50c228f1c35
Evidence state: activated (canonical pool and Hook fee path only)
Changed contracts/interfaces: none
Generated artifact or ABI source: immutable deployed-source commit 027af3f06bbe6dea2c187dfd8062e50c228f1c35
Deployment manifest: deployments/v4-production-activation-2026-08-09.json and deployments/v4-compounder-activation-2026-08-09.json
Chain and verification block: Base 8453; block 49736809
Depends-on: merged v4 deployment evidence and aligned basket/monitor consumers
Unblocks: accurate public token, pool, custody, and integration evidence for external review
Downstream repositories reviewed: nara_protocol_v4_baskets main bacc890004f4ca4fddb49854a7f5670312055a16; nara-swarm-monitor main e99fdeeb5783a88209a7fceb56ac32ed3f50ec84; nara_protocol updated here
Commands and results: pinned source npm ci PASS; pinned source npm run build PASS; verification export PASS (12 sources, 8 artifacts); npm run verify PASS (42 files); npm run verify:external PASS (24 links); npm run verify:onchain PASS (8 contracts at block 49736809); git diff --check PASS
Skipped gates: no refresh of current price, balances, fee curves, or liquidity depth; no product activation, deployment, or transaction
Unresolved risks: point-in-time liquidity does not guarantee current depth or exits; baskets remain preview-only; public locking, bonds, and whole-product availability remain separately gated
Onchain or production writes: none
Secret scan: changed-line scan passed; no environment value, RPC endpoint, private key, signing command, or credential added
```

The previous public package described a retired Stage A token and pre-liquidity
pool state. This change regenerates the public source and artifact snapshot from
the exact fresh-v4 deployed-source commit, replaces current-state references
with the canonical deployment, and adds checks that reject the retired token in
public Markdown.

The status language is intentionally narrow. The canonical NARA/USDC pool is
registered, initialized, seeded, and tested for supported exact-input swaps.
That does not establish a current price, a minimum liquidity level, or general
availability of baskets, locking, bonds, or other NARA products.
