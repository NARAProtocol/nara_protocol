# Public version history

## Current line

NARA v4 is the only active protocol line. The current public token address and
deployment checkpoint are in [Current state](CURRENT_STATE.md).

### `docs-v4.0.2`

Aligned the public token and live-pool status with the protected v4 release,
added the exact deployed and Safe-finalized Position NFT evidence while keeping
consumer integration fail-closed, strengthened the technical-live-testing and
legal-review warnings, and pinned the reviewed baskets and monitor releases.

### `docs-v4.0.1`

Published the decoded engine constructor and CREATE2 reproduction evidence.
Confirmed NARAEngine source publication on Basescan, Blockscout, and Sourcify.
Blockscout and Sourcify classify the internally created engine as a
runtime/partial match.

### `docs-v4.0.0`

Published the first sanitized v4 source, artifact, deployment, and runtime-code
verification package.

## Historical tags

The Git tags `v0.1.0-predeploy` and `v0.1.0-beta` point to pre-deployment,
historical code from before the clean v4 launch. They are retained only for
record integrity.

Do not deploy, integrate, or infer current addresses from those tags. They do
not describe the active Base deployment.

## Future releases

Each current public release should identify:

- the signed `main` commit;
- its documentation verification date;
- the Base verification block;
- the source release commit;
- material status changes; and
- the verified pool status and the block or transaction checkpoint supporting it.
