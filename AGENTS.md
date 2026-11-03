# Rules for AI and coding agents

## Cross-Repository Role

This repository is the downstream public documentation and verification layer.
It never originates contract behavior, ABIs, addresses, deployment state, or
availability.

Use a full merged commit from `NARAProtocol/nara_protocol_v4` or
`NARAProtocol/nara_protocol_v4_baskets` for implemented behavior. Use verified
onchain evidence and sanitized manifests for deployed, configured, activated,
or available claims. Regenerate exported verification material; never copy it
from an uncommitted engineering tree.

Protocol and basket consumer repositories must be reconciled before publishing
an availability claim here. In the FIELD workspace, the complete order and
handoff schema are in
`../docs/NARA_CROSS_REPOSITORY_RELEASE_PROTOCOL.md`.

## Cold-AI fast path

For every public-state or listing-document update, start here without
rediscovering the workflow:

1. From this isolated public worktree, run
   `powershell -NoProfile -ExecutionPolicy Bypass -File ..\..\scripts\check-nara-roadmap-evidence.ps1 -PublicPath (Get-Location).Path -UsePublicWorkingTree`.
   Read `docs/ROADMAP.md`, `docs/CURRENT_STATE.md`, and
   `docs/ROADMAP_EVIDENCE.json`, then treat the
   immutable verified deployment manifest and source commit in the
   authoritative `nara-protocol-hardhat` checkout as origin evidence. This
   public repository is the final downstream publication target.
2. Fetch `origin/main` and work from a focused branch in a clean isolated
   worktree. Never reuse an unrelated branch or a dirty checkout.
3. Configure repository-local SSH commit signing with the registered
   `$env:USERPROFILE/.ssh/nara_gates.pub` key before committing. Stop if it is
   unavailable; do not publish unsigned replacement commits, force-push, amend
   a pushed branch, broaden token scopes, or delete branches.
4. Update `verification/` only from a clean detached worktree at the exact
   immutable source commit recorded by the deployment evidence.
5. Run `npm run verify`, `npm run verify:roadmap`,
   `npm run verify:roadmap:upstream`, `npm run verify:external`, pinned-block
   onchain verification, cross-manifest parity,
   stale-address/state searches, a secret scan, and a staged-diff check. Never
   print RPC URLs or credentials.
6. Confirm GitHub marks the pushed commit signature as verified, then use a
   protected pull request, wait for required checks, merge only from a clean
   merge state, and verify public `main` after merge.

Current addresses and availability belong in verified manifests and current
state documents, not in reusable workflow instructions.

## Source of truth

- Active protocol: NARA V5 modular stack (with retired v4 reference baseline preserved in `verification/`).
- Public deployed-source snapshot and artifacts:
  `verification/`
- Public token on Base:
  `0x91FB78A9F46B67f54BbD4489941d19666b2fAe0f`
- Generated artifacts, verified manifests, and observed Base state win over
  prose.

## Never reintroduce

- v3 contracts or addresses as current
- mining or auto-mining
- jackpot behavior
- historical v3 Lotto or Arena code as active code
- old keeper or cron behavior
- historical experimental token contracts

Lotto and Arena are not part of the current launch. Their old v3 implementations
are inactive, while any rebuild is deferred. Do not describe the product
concepts as permanently retired.

## Documentation rules

- Before editing, follow the mandatory
  [repository maintenance protocol](docs/MAINTENANCE.md). It defines evidence
  priority, cross-file synchronization, verification, and handoff requirements.
- Write for a reader starting from zero in crypto.
- Separate deployed, activated, planned, deferred, and retired states.
- Do not call a feature live without verified evidence.
- Do not claim safety, approval, insurance, returns, or price outcomes.
- Do not steer users toward an asset or personalized decision.
- Do not print or store private keys, seed phrases, credentials, or private RPC URLs.
- Update `docs/CURRENT_STATE.md` when a verified deployment state changes.
- Update `docs/ROADMAP_EVIDENCE.json` whenever roadmap or current-state content
  changes, and require its evidence assertions and document hashes to pass.
- Run `npm run verify` before committing.
- Never hand-edit exported files under `verification/sources/` or
  `verification/artifacts/`; regenerate them from the exact release commit.
- Treat historical tokens and pools as retired historical evidence, not
  current integration fallbacks.

## Change control

Use focused branches, pull requests, required review, and passing checks. Do not
send transactions, deploy contracts, or change production systems from work in
this documentation repository.

An update is incomplete until every affected row in the synchronization matrix
in `docs/MAINTENANCE.md` has been reviewed and the pull request records the
evidence and verification results.
