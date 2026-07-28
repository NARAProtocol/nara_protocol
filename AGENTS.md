# Rules for AI and coding agents

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

- Write for a reader starting from zero in crypto.
- Separate deployed, activated, planned, deferred, and retired states.
- Do not call a feature live without verified evidence.
- Do not claim safety, approval, insurance, returns, or price outcomes.
- Do not steer users toward an asset or personalized decision.
- Do not print or store private keys, seed phrases, credentials, or private RPC URLs.
- Update `docs/CURRENT_STATE.md` when a verified deployment state changes.
- Run `npm run verify` before committing.

## Change control

Use focused branches, pull requests, required review, and passing checks. Do not
send transactions, deploy contracts, or change production systems from work in
this documentation repository.
