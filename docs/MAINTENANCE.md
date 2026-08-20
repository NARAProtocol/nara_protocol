# Repository maintenance protocol

This is the mandatory update procedure for maintainers, cold AI agents, and
new contributors. It prevents documentation from drifting away from deployed
code and observable Base state.

## Authority order

When two sources disagree, use this order:

1. bytecode and state observed at the documented Base verification block;
2. generated active-v4 deployment manifests and artifacts;
3. active-v4 contract source at the release commit;
4. tests and deployment records from that commit;
5. public documentation;
6. plans, issue descriptions, chat history, and archived v3 material.

Lower-ranked material must never override higher-ranked evidence. Stop and
record the conflict if higher-ranked sources disagree with each other.

## Required reading before any edit

Read these files in order:

1. [`../AGENTS.md`](../AGENTS.md)
2. [`CURRENT_STATE.md`](CURRENT_STATE.md)
3. [`../verification/deployment.json`](../verification/deployment.json)
4. [`../verification/release.json`](../verification/release.json)
5. the document being changed
6. every document named in the synchronization matrix below

Do not infer current state from token names, explorer search results, old
addresses, archived code, or a previous conversation.

## Classify the change first

Use exactly one primary class:

| Change class | Examples | Minimum evidence |
|---|---|---|
| Editorial | Grammar, navigation, clearer explanation | Existing authoritative source |
| Code behavior | Function, event, error, role, limit, fee, ABI | Active-v4 source and generated artifact |
| Deployment | New address, replacement, constructor, release | Verified manifest, transaction and runtime code |
| Onchain state | Balance, role, pool state, sealed/frozen state | Named network, block number and reproducible query |
| Product status | Activated, unavailable, deferred, retired | Deployment evidence plus observable configuration |
| Legal or risk | Warning, availability limitation, jurisdiction statement | Observable facts; qualified legal review where required |

If evidence is missing, describe the item as unverified or planned. Never
upgrade it to deployed, active, safe, approved, audited, or available.

## Synchronization matrix

Review every row affected by the change. “Review” means either update the file
or explicitly confirm that no change is required in the pull request.

| Changed fact | Files that must be reviewed |
|---|---|
| Address, transaction, block or runtime hash | `verification/deployment.json`, `docs/CURRENT_STATE.md`, `README.md`, `verification/README.md` |
| Compiler, dependency, source commit or artifact | `verification/release.json`, `verification/README.md`, exported `verification/sources/`, exported `verification/artifacts/` |
| Engine constructor or CREATE2 evidence | `verification/engine-constructor.json`, `verification/README.md`, `docs/Technical_Architecture.md` |
| Supply, allocation or wallet purpose | `docs/TOKEN_AND_ALLOCATION.md`, `docs/CURRENT_STATE.md`, `README.md` |
| Pool or liquidity state | `docs/LIQUIDITY.md`, `docs/CURRENT_STATE.md`, `docs/LAUNCH.md`, `README.md` |
| Feature availability | `docs/CURRENT_STATE.md`, the feature page, `docs/ROADMAP.md`, `README.md` |
| Admin role or custody | `docs/ADMIN_POWERS.md`, `docs/Risk_Assessment.md`, `docs/LAUNCH.md`, `docs/CURRENT_STATE.md` |
| User-facing behavior | `docs/User_Guide.md`, `docs/GLOSSARY.md`, the relevant technical page |
| Legal or security wording | `LEGAL.md`, `SECURITY.md`, `docs/Risk_Assessment.md`, affected user pages |

## Update procedure

1. Create a focused branch. Do not work directly on protected `main`.
2. Record the exact fact being changed and its evidence.
3. Inspect active-v4 code or onchain state. Do not begin by rewriting prose.
4. For a deployed-source update, regenerate the verification package with
   `scripts/export-verification.mjs`; never hand-edit exported source, artifacts,
   or their hashes.
5. Update the smallest complete set of files from the synchronization matrix.
6. Use exact status words: `deployed`, `activated`, `available`, `unavailable`,
   `planned`, `deferred`, `inactive`, or `retired`.
7. Update “Last verified” only when the stated facts were actually rechecked.
   A text-only edit does not refresh an onchain verification date.
8. Check every address character, chain ID, block, transaction, amount, decimal,
   role, fee, cap, function name, and link against its source.
9. Search the repository for superseded wording and old values.
10. Run the required checks and inspect the diff before committing.
11. Open a pull request containing evidence and the completed synchronization
    checklist. Merge only after required checks and review pass.

## Required checks

Run from the repository root:

```powershell
npm run verify
npm run verify:external
git diff --check
git diff --stat
git diff
```

When a deployed address, runtime hash, or observed state changes, also run:

```powershell
$env:BASE_RPC_URL = "your Base mainnet RPC endpoint"
npm run verify:onchain
Remove-Item Env:BASE_RPC_URL
```

Never print or commit the RPC endpoint. Record only the command result, network,
chain ID, and verification block.

## Cross-repository order

Private engineering code is the implementation source. This public repository
is the publication and verification layer. When a release affects both:

1. finalize and test the active-v4 engineering change;
2. merge the immutable release commit through protected CI;
3. verify the deployment or observed state;
4. reconcile affected basket and monitor consumers against that exact commit
   and deployment evidence;
5. regenerate this repository's verification package from the exact release;
6. update synchronized public documentation;
7. run public repository checks;
8. merge through a reviewed pull request.

Never publish a planned address as deployed, copy uncommitted source into the
public snapshot, or change public artifacts independently of the release. In
the FIELD workspace, follow
`../docs/NARA_CROSS_REPOSITORY_RELEASE_PROTOCOL.md` for repository ownership,
change IDs, state gates, and the cross-repository handoff.

## Security stop conditions

Stop the update and report the problem privately when:

- source, artifact, constructor, address, or runtime hashes disagree;
- a required address or transaction cannot be independently verified;
- a diff contains a key, seed phrase, credential, private RPC URL, `.env`
  content, signing command, or personal data;
- a requested statement claims guaranteed safety, returns, legal approval,
  insurance, or investment suitability;
- the only evidence is archived v3 code, a screenshot, chat text, or an
  automated scanner without reproducible evidence.

Do not “fix” a deployed contract by editing its published source snapshot. A
deployed contract can only be documented accurately, mitigated operationally,
or replaced through a separately approved deployment process.

## Handoff record

Every pull request must state:

- primary change class;
- evidence inspected;
- verification block when onchain facts changed;
- synchronized files reviewed;
- commands run and their results;
- unresolved assumptions or risks;
- confirmation that no secrets or production transactions were involved.

This record is what allows the next cold agent to continue without relying on
private memory or earlier chat history.
