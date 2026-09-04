# Security Model

## Trust assumptions in V1

V1 uses a trusted relayer. Therefore the relayer key is a privileged security boundary. The messenger authenticates the configured relayer, source chain id, source sender and replay identity, but it does not independently prove remote-chain consensus.

## PQ admission

Base->SINERGY relay transactions must enter through the SINERGY PQ gateway using `hybrid_max`:

- ML-DSA-87
- SLH-DSA-SHAKE-256s
- EVM transaction commitment
- chain id binding
- expiration
- persistent PQ nonce

Ordinary public write RPC methods are blocked.

## Key separation

Use separate identities for:

1. deployer;
2. governance;
3. Base relayer ECDSA signer;
4. SINERGY backend ECDSA signer;
5. ML-DSA-87 authorization key;
6. SLH-DSA authorization key.

Any key previously posted in chat, logs, screenshots or public/private repository history must be considered exposed and rotated before live use.

## Contract controls

- remote application sender is checked through `xDomainMessageSender()`;
- source chain is checked through `xDomainSourceChainId()`;
- `sourceEventId` is one-time consumable;
- adapter codehash is pinned by executor;
- adapter receives assets only during an active callback;
- adapter must finish settlement with zero residual;
- a normal CLOSE cannot settle below `minCanonicalGain`;
- expired risk is force-unwound instead of hidden.

## Economic security

Internal accounting values are never accepted as proof of profit. The binding result is canonical external NAV after complete settlement.

Threats that remain:

- external pool price manipulation;
- MEV/front-running/sandwiching;
- reorg/confirmation assumptions;
- relayer compromise;
- oracle/quote manipulation if additional venues are added;
- inventory drawdown during forced unwind;
- smart-contract bugs;
- RPC/provider outage;
- economic model failure even when software behaves correctly.

## G0 limitations

G0 protects admission to an EVM backend but is not yet native PQ consensus. A compromised backend/validator model is outside the guarantee of the admission gateway. The production architecture must integrate PQ verification into consensus/execution itself.
