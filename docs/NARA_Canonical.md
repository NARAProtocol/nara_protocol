# NARA Canonical Overview

NARA is a Base-native time-preference protocol.

It combines:

- a fixed `1,000,000 NARA` supply
- a sealed `700,000 NARA` reward reserve
- a sealed `250,000 NARA` bond inventory vault
- quadratic, duration-weighted locking
- ETH reward routing into committed lockers

## What Makes NARA Different

Most tokens ask one question: will price go up?

NARA asks a harder one: how much of the system do you want to commit to, and for how long?

The protocol is designed so that:

- supply is constrained by code
- locker rewards come from a sealed reserve, not open-ended inflation
- longer commitment earns structurally more weight
- future protocol ETH flow can route into the same lockers
- the core can stay stable while the surfaces on top evolve

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

## The Core User Idea

A simple mental model:

- hold NARA for exposure
- lock NARA for NARA and ETH reward flow
- later, when conditions are right, bonds become a controlled discounted entry path
- over time, wrappers and integrations can make locked positions more useful and portable

## Important Framing

The lockboard is not the protocol.

It is the current launch surface used to kick-start participation and make the first public locking wave legible. If it works, it can keep evolving. If it does not, the surface can change while the protocol thesis stays intact.

## The Long Game

The long-term opportunity is not one page or one campaign.

The long-term opportunity is a protocol layer on Base that can support:

- committed locking
- ETH-generating product surfaces
- analytics and monitoring
- wrappers and aggregation
- lending and collateral integrations
- more advanced market structure around locked positions

For live numbers and addresses, read `CURRENT_STATE.md`.
For the build path from here, read `ROADMAP.md`.
