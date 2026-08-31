## Summary

Describe the reader-facing change.

## Evidence

Link the active v4 code, verified manifest, Base transaction, or authoritative
source supporting factual changes.

## Roadmap-to-evidence review

| Roadmap item | `roadmapStatus` | `workState` | `evidenceState` | Immutable evidence | `availability` | Documentation action |
|---|---|---|---|---|---|---|
| | `completed` / `next_gate` / `future_gate` / `deferred` / `retired` | `not_started` / `partial` / `complete` / `retired` | exact release-protocol state or `null` | | `unavailable` / `preview` / `technical_live_testing` / `available` | |

## Safety checklist

- [ ] I used NARA v4 sources only.
- [ ] I used the exact roadmap, work, evidence, and availability states above; I did not use ambiguous `live` wording.
- [ ] I added no keys, credentials, seed phrases, private RPC URLs, or personal data.
- [ ] I made no return, safety, price, or regulatory-approval claims.
- [ ] I ran `npm run verify:roadmap` and resolved every roadmap/current-state mismatch.
- [ ] I ran `npm run verify:roadmap:upstream` and resolved protected-main or evidence drift.
- [ ] I ran `npm run verify`.
