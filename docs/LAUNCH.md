# Launch gates

NARA uses evidence-based gates rather than treating one deployment as a complete
product launch.

## Completed liquidity checkpoint

- Fresh v4 core contracts were deployed and source-verified.
- Production ownership moved to a `2-of-3` Safe.
- The canonical NARA/USDC pool was atomically registered, initialized, and
  seeded with `60,000 NARA + 300 USDC`.
- Receipt-pinned exact-input buy and sell tests reconciled the Hook fee path.
- The Compounder passed bounded validation and the Vault binding was permanently
  frozen in a separate transaction.
- The Position NFT Phase 2 contracts were deployed, tested under recorded
  release gates, source-verified, and finalized through the production Safe.

These facts establish the canonical pool and Hook fee path. They do not declare
the entire protocol production-ready or every user-facing product available.

## Remaining product gates

- Keep the baskets application preview-only until basket contracts, adapters,
  manifests, integration tests, monitoring, and exit paths are verified.
- Complete and receipt-pin the public Engine lifecycle and interface evidence
  before describing public locking or rewards as available.
- Keep Position NFT consumer integration unavailable. The deployment is
  complete, but the separately approved value-bearing smoke, observation, and
  downstream handoff evidence is not complete (`integrationReady: false`).
- Open bonds, Lockboard, and composability only through their own reviewed
  deployment and availability gates.
- Maintain current monitoring, incident response, custody, and qualified legal
  review for intended jurisdictions and communications.

## User-facing activation requirements

Before a value-bearing action, an interface must neutrally show the selected
asset or product, exact contracts and network, input, expected output, fees,
approvals, slippage and deadline where relevant, exit mechanics, risks, and a
final user-controlled confirmation.

The interface must not label one token, basket, bond, or position as
recommended, safest, best, low risk, or likely to produce a return.

## After activation

Activation is not the end of launch controls. Monitoring must verify pool state,
roles, reserves, privileged changes, and frontend manifests. Unexpected state
is a reason to stop and investigate.
