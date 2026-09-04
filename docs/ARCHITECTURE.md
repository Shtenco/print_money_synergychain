# Architecture — PRINT MONEY SYNERGYCHAIN

## 1. System boundary

V1 is intentionally split into four security/economic planes:

1. **SINERGY L1 G0** — chain id `8453001`, public PQ admission RPC on `9545`, private EVM execution backend on `9546`.
2. **Cross-domain messaging** — one `TrustedRelayerCrossDomainMessenger` on SINERGY and one on Base.
3. **Economic control** — `SinergyQEController` on L1 and `BaseQEExternalExecutor` on Base.
4. **External market adapter** — `BasePinnedPoolGradientAdapter` bound to the configured Base WETH/USDC Uniswap V3 pool.

## 2. Message flow

```text
SINERGY L1
  SinergyQEController.openQEIntent(...)
        |
        v
  SINERGY Messenger::SentMessage
        |
        v
  trusted relayer
        |
        v
  Base Messenger::relayMessage
        |
        v
  BaseQEExternalExecutor.onQEIntent
        |
        v
  BasePinnedPoolGradientAdapter.openGradient
        |
        v
  Base WETH/USDC market
```

The position may remain open across blocks. A later permissionless `closeQEIntent(intentId)` performs the inverse leg. If the final canonical NAV is below the L1 threshold, the complete CLOSE transaction reverts.

After settlement:

```text
BaseQEExternalExecutor
        |
        v
  Base Messenger::SentMessage
        |
        v
  trusted relayer
        |
        v  (hybrid_max PQ envelope)
  SINERGY PQ RPC
        |
        v
  SINERGY Messenger::relayMessage
        |
        v
  SinergyQEController.settleFromBase
        |
        v
  QT: qeDebt -> 0, qePrice -> neutral
```

## 3. Cross-domain authentication

The messenger intentionally keeps the OP-style application surface:

- `sendMessage(target, message, minGasLimit)`
- `relayMessage(...)`
- `xDomainMessageSender()`
- `xDomainSourceChainId()`

but does **not** claim OptimismPortal security. V1 is a trusted-relayer corridor.

Replay identity is committed by the relayer to:

```text
source chain id + source block hash + source tx hash + log index
```

and consumed once by the destination messenger.

## 4. Post-quantum admission

Public state-changing EVM submission is blocked by the G0 gateway. Transactions enter through `synergy_sendPqRawTransaction`.

Policies:

- `hybrid_online`: ML-DSA-87 envelope.
- `hybrid_max`: ML-DSA-87 + SLH-DSA-SHAKE-256s.
- `pq_only`: dual-PQ external authorization identity; G0 still uses an EVM backend transaction for execution.

The signed domain commits chain id, PQ account identity, replay nonce, expiry, policy and SHA-256 of the raw EVM transaction.

## 5. Economic contracts

### `SinergyQEController`

Controls:

- `qePremiumBps` — internal QE amplitude.
- `gradientTransferBps` — fraction of the permitted principal transferred to the external market.
- `minCanonicalGainUsdc6` — required external economic threshold.
- `qeDebtUsdc6` — internal debt ledger cleared by QT.

Only one active impulse is allowed in V1 so debt attribution remains exact.

### `BaseQEExternalExecutor`

Maintains the external position lifecycle:

```text
NONE -> OPEN -> SETTLED
             -> FORCED_UNWIND
```

Normal CLOSE is accepted only if:

```text
NAV_after >= NAV_before + minCanonicalGain
```

Expired risk can be force-unwound; losses remain explicit.

### `BasePinnedPoolGradientAdapter`

Positive QE:

```text
USDC -> WETH
```

Negative QE:

```text
WETH -> USDC
```

The transferred notional is:

```text
principal * gradientTransferBps / 10000
```

The adapter returns all resulting assets to the executor vault and must finish with zero adapter residual.

## 6. Generation boundary

G0 is a runnable integration generation, not the final consensus architecture.

Target G4:

```text
PQ validator consensus
    -> native revm/reth
    -> ML-DSA precompile
    -> SLH-DSA precompile
    -> NEXUS deterministic execution/proof surface
    -> proof/light-client bridge
```
