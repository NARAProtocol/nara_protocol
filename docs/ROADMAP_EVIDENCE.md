# Roadmap evidence gate

This gate keeps planned work, completed work, deployed state, and public
availability from drifting apart.

The machine-readable ledger is
[`ROADMAP_EVIDENCE.json`](ROADMAP_EVIDENCE.json). It records each public roadmap
item, the evidence state actually achieved, its user-availability boundary,
the exact roadmap and current-state claims, local supporting files, protected
repository commits, and upstream evidence paths.

## Required procedure

Before changing roadmap, current-state, launch, availability, or listing text:

1. Run the workspace `ROADMAPCHECK` command.
2. Compare the authoritative protocol roadmap and current state with merged
   source, named tests, verified manifests, and onchain evidence where relevant.
3. Check baskets and monitor protected `main` when they consume the feature.
4. Update [`ROADMAP.md`](ROADMAP.md), [`CURRENT_STATE.md`](CURRENT_STATE.md), and
   the evidence ledger together when their relationship changes.
5. Run `npm run roadmap:hashes`, place the printed hashes in the ledger, then
   run `npm run verify:roadmap`, `npm run verify:roadmap:upstream`, and
   `npm run verify`.

If implementation is ahead of the roadmap, update the roadmap. If the roadmap
is ahead of evidence, downgrade the roadmap wording. If evidence conflicts,
stop rather than choosing the most convenient statement.

## State rule

`roadmapStatus` describes roadmap placement. `workState` separately records
whether that exact bullet is `not_started`, `partial`, or `complete`.
`Completed` describes only a named roadmap task. It does not mean a product is
available. Public availability requires the `available` evidence state plus a
completed user flow and checked exit path.

The complete gate (`ROADMAPCHECK`, repository verification, and protected CI)
fails on:

- stale protected-main commits;
- changed roadmap or current-state content without refreshed hashes;
- completed work supported only by untested source;
- availability without user-flow and exit evidence;
- missing local or upstream evidence;
- unsupported state words; or
- roadmap/current-state claims that no longer appear in the public documents.

The repository verifier also requires exactly one ledger entry for every
tracked roadmap bullet. Protected CI runs the upstream mode, which checks the
current protected-main commits, hashes of the authoritative protocol roadmap
and current state, evidence-file existence, and JSON assertions.
