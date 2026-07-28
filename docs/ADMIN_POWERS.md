# Administration and custody

## Why this matters

Some protocol actions depend on privileged accounts. If a privileged key is
lost, stolen, or misused, configuration or protocol operations may be disrupted.
Users should understand those dependencies before signing transactions.

## Current custody state

The final Stage A administrator and treasury are EOAs, meaning each is controlled
by a private key rather than a multisignature Safe. This is a launch blocker
because one compromised key can create a single point of failure.

Migration to accepted multisignature custody is required before activation.
Migration must be verified onchain; a plan or created Safe is not proof that
roles were transferred.

## What fixed supply protects

The NARA token has 1,000,000 permanently outstanding NARA and no admin mint. An
administrator cannot use the token contract to create additional permanent
NARA. The separate, code-controlled ERC-3156 flash-mint feature is capped at
100,000 temporary NARA and must settle within one transaction.

Fixed supply does not eliminate:

- theft or misuse of existing treasury tokens;
- unsafe contract approvals;
- protocol configuration risk;
- liquidity withdrawal or market risk;
- compromised interfaces or signers; or
- bugs in surrounding contracts.

## Required control standard

- Separate operational and treasury responsibilities.
- Require multiple independent signers for material actions.
- Use hardware-backed signing and secure recovery procedures.
- Publish role and ownership changes as verifiable transactions.
- Apply delays where supported and appropriate.
- Monitor privileged events and unexpected bytecode or role changes.
- Never commit keys, seed phrases, RPC credentials, or signing secrets.
- Document emergency authority and its limits before activation.

## No claim of decentralization

This documentation does not call NARA decentralized, trustless, or
permissionless. Those words require evidence about every relevant role,
dependency, upgrade path, custody arrangement, and interface.
