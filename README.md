# NARA Protocol

NARA is a Base-native time-preference protocol built around fixed supply, sealed reserves, weight-based locking, and future ETH flow to lockers.

## Official Links

[??](https://www.naraprotocol.io) [??](https://www.naraprotocol.io/mine) [?](https://x.com/NARA_protocol) [??](https://warpcast.com/naraprotocol) [??](https://app.uniswap.org/swap?chain=base&outputCurrency=0xE444de61752bD13D1D37Ee59c31ef4e489bd727C)


## Live Status

As of 2026-03-22:

- `1,000,000 NARA` total supply, fixed forever
- `700,000 NARA` sealed in the reward reserve
- `250,000 NARA` sealed in the bond vault
- `30,000 NARA` already locked by treasury and owner in one-year positions
- locking is live on Base
- bonds are deployed but intentionally closed
- the current public onboarding surface is `/mine`

## Start Here

- [docs/User_Guide.md](docs/User_Guide.md) for the simple user path
- [docs/NARA_Canonical.md](docs/NARA_Canonical.md) for the protocol overview
- [docs/CURRENT_STATE.md](docs/CURRENT_STATE.md) for the live addresses and current snapshot
- [docs/ROADMAP.md](docs/ROADMAP.md) for where the protocol is going
- [docs/Technical_Architecture.md](docs/Technical_Architecture.md) for the contract and system design
- [docs/REWARDS.md](docs/REWARDS.md) for how NARA and ETH rewards work
- [docs/Risk_Assessment.md](docs/Risk_Assessment.md) for the current risk picture
- [docs/ADMIN_POWERS.md](docs/ADMIN_POWERS.md) for what operators can and cannot do
- [docs/LAUNCH.md](docs/LAUNCH.md) for the current launch surface and why it exists

## Important Note

This repository is now a public documentation surface for the live protocol.

The canonical live contract addresses and onchain status live in [docs/CURRENT_STATE.md](docs/CURRENT_STATE.md).
If this repo still contains historical exploratory contracts or earlier design artifacts, do not treat them as the live Base deployment.

## Core Positioning

NARA is not just a board, a bond page, or a token ticker.

The protocol thesis is larger:

- finite NARA emissions from a sealed reserve
- ETH flow that can route into lockers
- time-weighted commitment
- a core system that can support future wrappers, analytics, and composability

The first launch surface may change over time. The protocol thesis should not.
