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

## Source of truth

- Active protocol: NARA v4 only.
- Public deployed-source snapshot and artifacts:
  `verification/`
- Public token on Base:
  `0x65E247AA3aa9C0131b2984b894c3D24c41341D7A`
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
- Run `npm run verify` before committing.
- Never hand-edit exported files under `verification/sources/` or
  `verification/artifacts/`; regenerate them from the exact release commit.

## Change control

Use focused branches, pull requests, required review, and passing checks. Do not
send transactions, deploy contracts, or change production systems from work in
this documentation repository.

An update is incomplete until every affected row in the synchronization matrix
in `docs/MAINTENANCE.md` has been reviewed and the pull request records the
evidence and verification results.
