# Beginner guide

This page assumes you are starting from zero.

> ⚠️ **Technical live testing — not public product availability:** NARA uses
> real assets on Base mainnet. Transactions are irreversible, liquidity may be
> limited or unavailable, and some products and interfaces remain unavailable.
> Do not treat live testing as proof of production readiness, an audit, safety,
> legal approval, or availability in every jurisdiction.

## Five ideas to understand first

### 1. A blockchain is a public record

Base is a blockchain network. Transactions and contract activity are recorded
publicly. A confirmed transaction normally cannot be reversed by NARA, Base, a
wallet provider, or a bank.

### 2. A wallet controls an address

A wallet app lets you use a blockchain address. The wallet does not hold coins
like a physical wallet; it holds the secret needed to authorize transactions.

- A **public address** can be shared so others can send assets to it.
- A **seed phrase** or **private key** controls the address and must never be shared.
- If the secret is lost, there may be no recovery process.
- If someone gets the secret, they can usually take the assets.

NARA contributors will never ask for your seed phrase or private key.

### 3. A token is a smart-contract record

NARA is an ERC-20 token contract on Base. The name `NARA` or written form `$NARA`
does not prove that a token is genuine. The contract address is the reliable
identifier:

```text
0xB6333F5D4cEd8dffA80F3F13697D6aA3BB3f19c1
```

### 4. Gas is a network fee

Base transactions require a small amount of ETH for gas. Gas is paid to the
network for processing; it is not a NARA purchase and is not normally refundable.
A failed transaction can still consume gas.

### 5. A contract approval is permission

Some apps ask you to approve a contract to move tokens. Read the asset, amount,
spender address, network, fees, slippage, and expected result before signing.
Unlimited approvals can remain active until revoked.

## What can a beginner do today?

You can inspect the deployed contracts and read this documentation. The
canonical NARA/USDC pool is initialized and seeded, and receipt-pinned
exact-input buy and sell tests verified its Hook fee path. This does not mean
that every wallet, interface, trade size, or exit is available or suitable.
Confirm the current pool ID, expected output, fees, slippage, deadline, and exit
path before considering any transaction.

Do not follow a social-media link claiming that official NARA trading is already
open. Check [Current state](CURRENT_STATE.md) first.

## When a user interface becomes available

A value-bearing action should follow this sequence:

1. Open an official link.
2. Confirm the wallet is on Base.
3. Choose the action yourself.
4. Review the exact token and contract addresses.
5. Review amounts, fees, approvals, slippage, deadline, expected output, and exit.
6. Read the risk notice.
7. Confirm in the wallet only if the details match.
8. Save the transaction hash and verify it on a Base block explorer.

Connecting a wallet does not itself move funds. Signing a transaction or
permission can.

## Common scams

- A fake NARA token with the same name or symbol
- A fake website or sponsored search result
- A direct message offering “support”
- A request to “verify” a seed phrase
- A surprise token or NFT that links to a malicious website
- A promise of guaranteed returns, recovery, airdrops, or special access
- Pressure to act immediately

Stop if anything is unclear. A real opportunity does not require revealing a
wallet secret.

## Crypto is not a bank account

NARA is not legal tender, a bank deposit, insurance, or a guaranteed investment.
There may be no liquid market or buyer when you want to exit. Smart contracts and
interfaces can fail. Only use crypto after understanding that losses can be total
and irreversible.
