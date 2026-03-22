# Admin Powers

NARA is designed so that the most important supply rules are harder to change than the surface-level experience built around them.

## Official Links

- Website: [naraprotocol.io](https://www.naraprotocol.io)
- App: [naraprotocol.io/mine](https://www.naraprotocol.io/mine)
- X: [@NARA_protocol](https://x.com/NARA_protocol)
- Farcaster: [@naraprotocol](https://warpcast.com/naraprotocol)
- Buy NARA: [Uniswap on Base](https://app.uniswap.org/swap?chain=base&outputCurrency=0xE444de61752bD13D1D37Ee59c31ef4e489bd727C)


## What Admins Cannot Do

At a high level, operators cannot:

- mint new supply beyond the fixed total
- turn the sealed reward reserve into a discretionary treasury pool
- treat the sealed bond inventory as an unrestricted wallet

Those constraints are part of the protocol thesis.

## What Admins Can Control

Operators still have limited control over live configuration and operations, including:

- fee settings within the live engine
- certain timing and parameter surfaces
- bond market wiring and capacity when bonds are eventually opened
- operational support for epoch advancement and product surfaces

## Bond Controls

The bond layer is intentionally more controlled than the token layer.

That is because bond opening affects distribution, liquidity, and ETH routing. The vault and market wiring are part of the controlled release system, not an always-open faucet.

## Practical Interpretation

NARA should not be described as a system with zero operator influence.

A better description is:

- the hard supply and reserve rules are constrained by code
- the launch timing, fee surfaces, and bond activation path still require operator judgment

That balance is important. The core should stay hard. The edges can stay adaptable.
