# SINERGY L1 G0 Node

G0 is the smallest runnable integration node for chain id `8453001`.

## Ports

- public PQ RPC: `127.0.0.1:9545`
- private EVM backend: `127.0.0.1:9546`

The backend must not be exposed publicly.

## Start

```bash
export SYNERGY_DEVNET_MNEMONIC='NEW PRIVATE DEVNET MNEMONIC'
bash node/run-devnet.sh
```

## PQ policies

- `hybrid_online` — ML-DSA-87 authorization envelope.
- `hybrid_max` — ML-DSA-87 + SLH-DSA-SHAKE-256s.
- `pq_only` — dual-PQ external authorization identity; G0 still executes an EVM transaction internally.

## RPC extensions

- `synergy_health`
- `synergy_chainProfile`
- `synergy_getPqNonce`
- `synergy_buildPqPreimage`
- `synergy_sendPqRawTransaction`

Public `eth_sendRawTransaction`, wallet signing methods, Anvil/admin/engine methods and similar state-changing bypasses are blocked.

## State

By default state is stored under `~/.synergy-l1`:

- Anvil state snapshot
- PQ replay nonce SQLite database
- optional generated PQ key directory

Back up state before upgrades and never commit keys or state databases.

## Generation warning

G0 is an admission-security prototype. The production objective is a native validator/execution client where PQ verification is consensus critical rather than a gateway in front of a classical EVM backend.
