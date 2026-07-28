# Launch gates

NARA uses evidence-based gates rather than a promised launch date.

## Current gate

Controlled Stage A is deployed. The planned pool is registered but uninitialized,
official liquidity has not been added, and the baskets application remains in
preview.

## Required before liquidity activation

- Reconcile token custody and the complete 70,000 NARA liquidity envelope.
- Confirm the reviewed initial seed parameters and balances.
- Migrate required administration to accepted multisignature custody.
- Complete human custody and operations acceptance.
- Re-run fresh-address, chain-ID, bytecode, role, and balance preflight checks.
- Confirm pool price, token ordering, hook permissions, and slippage protections.
- Publish a verified manifest without secrets.
- Prepare monitoring, pause criteria, and incident-response procedures.
- Complete qualified legal review for intended jurisdictions and communications.

The working liquidity scenario is 60,000 NARA and 300 USDC, corresponding
arithmetically to $0.005 per NARA, an approximately $600 two-sided pool, and a
$5,000 implied fully diluted valuation. These are planning inputs, not a market
price, fundraising target, valuation opinion, return forecast, or guarantee.
Actual execution can differ and may be cancelled.

## Baskets-only launch surface

The only current launch frontend is the baskets application. It must remain
preview-only until verified basket manager and adapter manifests exist.
Lockboard is deferred. Lotto and Arena are not part of the current launch; their
old v3 implementations are inactive and possible v4 rebuilds are deferred.

## User-facing activation requirements

Before a value-bearing action, the interface must neutrally show:

- selected basket and token composition;
- exact contract addresses and network;
- input, expected output, fees, and approvals;
- slippage and deadline where relevant;
- exit mechanics and material risks; and
- a final user-controlled confirmation.

The interface must not label one token or basket as recommended, safest, best,
low risk, or likely to produce a return.

## After activation

Activation is not the end of launch controls. Monitoring must verify pool state,
roles, reserves, privileged changes, and frontend manifests. Unexpected state is
a reason to stop and investigate, not to continue automatically.
