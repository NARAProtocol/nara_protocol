# NARA Canonical Overview

NARA is a Base-native time-preference protocol centered on a live engine that fairly distributes protocol earnings to committed lockers.

## What NARA Actually Is

NARA combines:

- a fixed `1,000,000 NARA` supply
- a sealed `700,000 NARA` reward reserve
- a sealed `250,000 NARA` bond inventory vault
- quadratic, duration-weighted locking
- an engine that distributes both NARA and ETH by active weight

The important idea is not just token locking. The important idea is a reusable earnings engine for the protocol.

## The Core Engine Thesis

`NARAEngineV2` is the center of the system.

It exists to:

- keep track of committed positions
- turn amount and time into weight
- distribute sealed NARA emissions fairly
- distribute protocol ETH fairly
- act as the reward layer for current and future products

That means the protocol can grow beyond one page or one campaign. If a new product creates ETH earnings and routes them into the engine, lockers share that flow without needing a new reward philosophy each time.

## What Makes NARA Different

Most tokens ask one question: will price go up?

NARA asks a harder one: how much of the system do you want to commit to, and for how long?

The protocol is designed so that:

- supply is constrained by code
- reward reserves are sealed
- longer commitment earns structurally more weight
- product earnings can be shared through a common engine
- the core can stay stable while surfaces on top evolve

## What Is Live Today

- locking is live on Base
- the reward reserve and bond vault are already deployed
- treasury and owner have already locked `30,000 NARA` for one year
- the epoch engine is advancing in production
- the current onboarding surface is the lockboard at `/mine`

## What Is Not Live Today

- public bond sales
- lock-position wrappers
- secondary markets for locked positions
- the broader composability layer the protocol is designed to support over time

## The Right Mental Model

Think about NARA in layers:

- token layer: fixed supply and thin float
- reserve layer: sealed NARA allocations
- engine layer: fair distribution of NARA and ETH to lockers
- surface layer: board, dashboards, future wrappers, and future products

The surface can change. The engine layer is the durable thesis.

## Why The Board Is Not The Product

The lockboard is useful because it makes the first public lock wave legible and shareable.

But the board is not the protocol. It is only the current launch surface feeding users into the engine.

## The Long Game

The long-term opportunity is a protocol layer on Base that can support:

- committed locking
- ETH-generating product surfaces
- analytics and monitoring
- wrappers and aggregation
- lending and collateral integrations
- more advanced market structure around locked positions

For live numbers and addresses, read `CURRENT_STATE.md`.
For the build path from here, read `ROADMAP.md`.

## Official Links

[??](https://www.naraprotocol.io) [??](https://www.naraprotocol.io/mine) [?](https://x.com/NARA_protocol) [??](https://warpcast.com/naraprotocol) [??](https://app.uniswap.org/swap?chain=base&outputCurrency=0xE444de61752bD13D1D37Ee59c31ef4e489bd727C)
