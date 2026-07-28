# Baskets

## What a basket means

A basket is a user-selected group of tokens presented together. The planned NARA
interface uses four neutral categories:

- CORE
- AI
- FINANCE
- CULTURE

Comparable baskets must receive equal visual weight. The interface must explain
composition, weights, fees, risks, and exits without deciding which asset is
appropriate for a user.

## Current status

The baskets application is the only current launch frontend, but it is preview
only. It must fail closed until verified basket manager and adapter deployment
manifests exist. A preview is not a live investment product.

## Required user flow

```text
Connect Wallet
    -> Choose a basket to preview
    -> View Basket
    -> Review tokens, weights, fees, approvals, slippage, deadline, risks, exits
    -> User-controlled confirmation
```

The interface must not use “recommended,” “best,” “safest,” “low risk,”
“trending,” projected returns, winner badges, or preferential ordering to steer
an asset choice.

## Risks

Basket use can combine token, smart-contract, adapter, liquidity, pricing,
approval, and third-party risks. A basket does not create diversification,
protection, insurance, or reduced risk merely because it contains multiple
tokens.
