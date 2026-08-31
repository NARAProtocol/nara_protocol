# Rules for AI and coding agents

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

- Active protocol: NARA v4 only.
- Public deployed-source snapshot and artifacts:
  `verification/`
- Public token on Base:
  `0xB6333F5D4cEd8dffA80F3F13697D6aA3BB3f19c1`
- Generated v4 artifacts, verified manifests, and observed Base state win over
  prose.

## Never reintroduce

- v3 contracts or addresses as current
- mining or auto-mining
- jackpot behavior
- historical v3 Lotto or Arena code as active v4 code
- old keeper or cron behavior
- historical experimental token contracts

Lotto and Arena are not part of the current launch. Their old v3 implementations
are inactive, while any v4 rebuild is deferred. Do not describe the product
concepts as permanently retired.

## Documentation rules

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
- Treat the previous Stage A token and pool as retired historical evidence, not
  current integration fallbacks.

## Change control

Use focused branches, pull requests, required review, and passing checks. Do not
send transactions, deploy contracts, or change production systems from work in
this documentation repository.
