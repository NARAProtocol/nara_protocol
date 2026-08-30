# Roadmap

This roadmap describes dependency order. It is not a schedule, promise,
solicitation, or commitment to deliver.

## Completed checkpoint — core liquidity

- Deploy and source-verify the fresh v4 core.
- Transfer production control to multisignature custody.
- Register, initialize, and seed the canonical NARA/USDC pool.
- Verify receipt-pinned exact-input buy and sell behavior.
- Validate the Compounder and permanently freeze the Vault binding.
- Deploy, test under recorded release gates, source-verify, and Safe-finalize
  the Position NFT Phase 2 contracts.

## Next gate — public integration

- Keep current deployment manifests, public evidence, and monitoring aligned.
- Complete Engine lifecycle and public-interface evidence.
- Complete separately approved Position NFT value-bearing smoke, observation,
  and downstream integration gates; deployment itself is already complete.
- Reconcile allocation and periphery evidence without reusing retired addresses.

## Basket gate

- Deploy and verify basket manager and adapter contracts.
- Publish exact manifests and generated interfaces.
- Complete fork, integration, interface, monitoring, and failure-mode tests.
- Move the baskets app from preview only after the full user flow and exit path
  are evidenced.

## Deferred features

- Evaluate bonds separately.
- Evaluate Lockboard and composability through independent releases.
- Consider clean v4 Lotto and Arena rebuilds separately from archived v3 code.

Mining, jackpots, and the v3 stack are retired and are not roadmap items.

## How roadmap changes are accepted

A proposed change must state its security assumptions, dependencies, user
risks, legal-review needs, verification evidence, and rollback or failure
behavior. Status changes require code and onchain evidence, not marketing copy.
