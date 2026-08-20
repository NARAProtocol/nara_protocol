## Summary

Describe the reader-facing change.

## Change class

Choose one: editorial, code behavior, deployment, onchain state, product status,
or legal/risk.

## Cross-repository routing

For a purely editorial change, write `not applicable` with a reason.

```text
Change-ID:
Origin repository:
Origin commit:
Evidence state:
Deployment manifest:
Chain and verification block:
Consumer repositories reconciled:
```

- [ ] Implemented behavior came from a full merged origin commit.
- [ ] Deployment and availability claims came from verified onchain evidence.
- [ ] Exported verification material was regenerated, not copied from a dirty tree.
- [ ] Baskets and monitor impact was reviewed before an availability claim.

## Evidence

Link the active v4 code, verified manifest, Base transaction, or authoritative
source supporting factual changes.

For an onchain-state change, include the network, chain ID, verification block,
query used, and result. Never include an RPC URL or credential.

## Synchronization review

List every file required by the synchronization matrix in
`docs/MAINTENANCE.md`. State either `updated` or `reviewed — no change needed`
for each one.

## Safety checklist

- [ ] I used NARA v4 sources only.
- [ ] I followed `docs/MAINTENANCE.md`.
- [ ] I labeled features as live, unavailable, planned, deferred, or retired.
- [ ] I did not hand-edit exported verification sources, artifacts, or hashes.
- [ ] I updated “Last verified” only after actually rechecking those facts.
- [ ] I added no keys, credentials, seed phrases, private RPC URLs, or personal data.
- [ ] I made no return, safety, price, or regulatory-approval claims.
- [ ] I ran `npm run verify`.
- [ ] I ran `npm run verify:external`.
- [ ] I ran `npm run verify:onchain` when deployed or onchain facts changed.
- [ ] I inspected `git diff --check` and the complete diff.

## Handoff

Record the commands run, their results, unresolved assumptions or risks, and
confirm whether any production transaction occurred.
