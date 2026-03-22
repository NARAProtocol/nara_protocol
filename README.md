# NARA Protocol

NARA is a Base-native time-preference protocol built around a live engine that fairly distributes protocol earnings to committed lockers.

Today, that engine distributes finite NARA from a sealed reserve. Over time, the same engine is designed to route ETH from current and future protocol products into the same reward layer.

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

## What We Actually Built

The core product is not a badge board.

The core product is an engine that can:

- track committed NARA positions
- weight them fairly by amount and duration
- distribute sealed NARA emissions by active weight
- distribute ETH earnings by active weight
- serve as the shared reward layer for future protocol products

That is why the board matters only as an entry surface. The board can change. The engine thesis should remain.

## Important Note

This repository is the public documentation surface for the live protocol.

The canonical live addresses and current onchain state are in [docs/CURRENT_STATE.md](docs/CURRENT_STATE.md).
If this repo still contains historical exploratory contracts or earlier design artifacts, do not treat them as the live Base deployment.

## Official Links

[??](https://www.naraprotocol.io) [??](https://www.naraprotocol.io/mine) [?](https://x.com/NARA_protocol) [??](https://warpcast.com/naraprotocol) [??](https://app.uniswap.org/swap?chain=base&outputCurrency=0xE444de61752bD13D1D37Ee59c31ef4e489bd727C)
