# NARA public v4 state synchronization

```text
Change-ID: NARA-20260830-documentation-convergence
Origin remote: NARAProtocol/nara_protocol_v4
Immutable deployed-source commit: 027af3f06bbe6dea2c187dfd8062e50c228f1c35
Documentation evidence origin commit: dae88079dd336e22bdefde6f45e3b01389d554cb
Authoritative protocol main reviewed: b16e3251db693a52b73b02a8c5d5e734914f9419
Evidence state: core pool activated; Position NFT deployed and Safe-finalized; consumer integration gated
Changed contracts/interfaces: none
Generated artifact or ABI source: immutable deployed-source commit 027af3f06bbe6dea2c187dfd8062e50c228f1c35
Deployment manifests: v4-production-activation-2026-08-09.json; v4-compounder-activation-2026-08-09.json; v4-position-nft-phase2-finalized-2026-08-21.json
Chain and verification blocks: Base 8453; core-liquidity block 49736809; Position NFT Safe-finalization block 50296367
Depends-on: nara_protocol_v4 documentation origin dae88079dd336e22bdefde6f45e3b01389d554cb, with current main b16e3251db693a52b73b02a8c5d5e734914f9419 reviewed; nara_protocol_v4_baskets main 2213f4a7e9fe3af984fc4b157d92169c91b015a0; nara-swarm-monitor main 4a96f7b7186a65b33366271128da8db230c9dd2e
Unblocks: accurate public token, pool, custody, Position NFT, integration-gate, and legal-review status for external review
Downstream repositories reviewed: nara_protocol_v4_baskets main 2213f4a7e9fe3af984fc4b157d92169c91b015a0; nara-swarm-monitor main 4a96f7b7186a65b33366271128da8db230c9dd2e; nara_protocol updated here
Commands and results: npm run verify PASS (43 files); npm run verify:external PASS (29 links); npm run verify:onchain PASS (8 core contracts plus 3 Position NFT contracts and Safe finalization receipt); cross-repository manifest and protected-commit parity PASS (19 checks); stale-address/state and promotional-claim searches PASS; changed-line secret scan PASS; git diff --check PASS; independent legal/comms and technical reviews CLEAN
Skipped gates: no refresh of current price, balances, fee curves, or liquidity depth; no Position NFT value-bearing smoke; no product activation, deployment, or transaction
Unresolved risks: point-in-time liquidity does not guarantee current depth or exits; Position NFT consumer integration remains false; baskets remain preview-only; public locking, bonds, and whole-product availability remain separately gated; no completed jurisdiction-specific qualified legal review is evidenced
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

The Position NFT Phase 2 deployment is also recorded as deployed, tested under
its release gates, source-verified, and Safe-finalized. Its manifest remains
`integrationReady: false` because the separately approved value-bearing smoke,
observation, and downstream handoff evidence is not complete.
