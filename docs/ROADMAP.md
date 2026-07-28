# Roadmap

This roadmap describes possible work in dependency order. It is not a schedule,
promise, solicitation, or commitment to deliver.

## Gate 1 — custody and launch readiness

- Complete multisignature custody migration and acceptance.
- Reconcile allocations and launch balances.
- Complete legal and operational launch review.
- Publish verified manifests and monitoring procedures.

## Gate 2 — controlled liquidity

- Re-run fresh-address and Base-state preflight.
- Initialize the reviewed NARA/USDC pool only after all blockers close.
- Add only the separately approved seed amounts.
- Verify the LP position, pool state, balances, roles, and monitoring.

## Gate 3 — baskets

- Deploy and verify basket manager and adapter contracts.
- Publish exact manifests and ABIs.
- Complete fork, integration, interface, and failure-mode tests.
- Move the baskets app from preview only after verification.

## Gate 4 — deferred protocol features

- Evaluate public positions, locks, and claims using v4 contracts and ABIs.
- Evaluate bonds separately.
- Consider a simple external team vesting arrangement.

Lockboard remains deferred. Lotto, Arena, mining, jackpots, and the v3 stack are
retired and are not roadmap items.

## How roadmap changes are accepted

A proposed change must state its security assumptions, dependencies, user risks,
legal review needs, verification evidence, and rollback or failure behavior.
Status changes require code and onchain evidence, not marketing language.
