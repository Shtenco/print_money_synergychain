# Base ↔ SINERGY Trusted Relayer

V1 relayer watches `SentMessage` events on the configured messenger on each chain and submits `relayMessage` on the destination.

## Security properties

- configurable confirmation depth;
- replay id commits source chain id, block hash, transaction hash and log index;
- destination messenger must be configured with the relayer account;
- Base→SINERGY writes use `hybrid_max` PQ admission;
- SINERGY→Base writes use a dedicated Base ECDSA relayer key;
- cursors and delivered events are persisted in SQLite.

## Install

```bash
python -m venv .venv-relayer
. .venv-relayer/bin/activate
pip install -r relayer/requirements.txt
```

## Required configuration

```text
BASE_RPC_URL
SINERGY_RPC_URL
BASE_SINERGY_MESSENGER
SINERGY_BASE_MESSENGER
BASE_RELAYER_PRIVATE_KEY
SINERGY_RELAYER_ECDSA_PRIVATE_KEY
SINERGY_RELAYER_ML_DSA_87_PUBLIC_KEY_FILE
SINERGY_RELAYER_ML_DSA_87_SECRET_KEY_FILE
SINERGY_RELAYER_SLH_DSA_PUBLIC_KEY_FILE
SINERGY_RELAYER_SLH_DSA_SECRET_KEY_FILE
```

Optional:

```text
BASE_CONFIRMATIONS=20
SINERGY_CONFIRMATIONS=2
BASE_START_BLOCK=<deployment block>
SINERGY_START_BLOCK=0
RELAYER_POLL_SECONDS=2
RELAYER_DB=~/.synergy-l1/base_sinergy_relayer.sqlite3
```

## Key warning

Use newly generated relayer keys. Do not reuse a deployer key and do not reuse any private key that has appeared in chat, shell history, logs or a repository.

## V1 trust boundary

This is not a light-client bridge. A compromised trusted relayer can attempt invalid delivery. Destination application contracts therefore also verify the remote application sender and source chain. Production should replace this trust assumption with proof/light-client verification.
