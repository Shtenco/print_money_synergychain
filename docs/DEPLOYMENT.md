# Deployment Plan

## Principle

This branch is **deployment-preparation only**. Do not broadcast Base Mainnet transactions until local/devnet and Base-fork validation are green.

## Phase 1 — local G0 node

Requirements:

- Linux/macOS shell
- Foundry (`anvil`, `forge`)
- Python 3.12+

```bash
export SYNERGY_DEVNET_MNEMONIC='NEW PRIVATE DEVNET MNEMONIC'
bash node/run-devnet.sh
```

Expected:

- SINERGY chain id: `8453001`
- public PQ RPC: `http://127.0.0.1:9545`
- private EVM backend: `http://127.0.0.1:9546`

Health check:

```bash
curl -s -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"synergy_health","params":[]}' \
  http://127.0.0.1:9545
```

## Phase 2 — PQ keys

```bash
python -m venv .venv
. .venv/bin/activate
pip install -r node/requirements.txt
python node/generate_pq_relayer_keys.py ~/.synergy-l1/keys
```

Keep secret files outside the repository.

## Phase 3 — Solidity tests

```bash
forge build
forge test -vvv
```

Required invariants include remote-sender authentication, replay rejection, QE debt creation, QT clearing, loss-close revert and successful canonical-gain settlement.

## Phase 4 — local messenger/controller wiring

Deploy on the local SINERGY devnet:

1. `TrustedRelayerCrossDomainMessenger(remoteChainId=8453, ...)`
2. `SinergyQEController(...)`

Use fresh development keys only.

## Phase 5 — Base fork

Fork Base from a pinned block and deploy only the local test copies of:

1. Base-side messenger
2. `BasePinnedPoolGradientAdapter`
3. `BaseQEExternalExecutor`

Wire `adapter.setExecutor(executor)` and test real pinned pool identity/quotes.

Measure:

- NAV before OPEN
- NAV immediately after OPEN
- NAV at candidate CLOSE
- DEX fees
- gas estimate
- forced-unwind result
- residual balances

## Phase 6 — bidirectional relayer in fork/devnet mode

Install:

```bash
python -m venv .venv-relayer
. .venv-relayer/bin/activate
pip install -r relayer/requirements.txt
```

Set only fresh credentials and local/fork endpoints. Validate Base->SINERGY and SINERGY->Base message replay behavior.

## Phase 7 — security review

Before mainnet:

- rotate every key ever exposed in chat, logs, shell history or prior `.env` files;
- use a dedicated Base relayer key;
- use distinct deployer and governance keys;
- set spending/inventory caps;
- audit messenger target authorization;
- test reorg handling and confirmation policy;
- review adapter codehash pinning;
- test emergency pause/risk-off procedure;
- verify Base pool addresses at deployment block.

## Phase 8 — controlled Base Mainnet pilot

Only after prior phases pass:

- deploy with fresh keys;
- fund the smallest practical canonical inventory;
- set conservative `gradientTransferBps`;
- set explicit `minCanonicalGain`;
- monitor every OPEN position;
- never count internal QE debt as profit;
- stop on any unexplained NAV discrepancy.

## Production target beyond G0

Replace the private Anvil backend with a real native execution/consensus node (`revm/reth` integration), move PQ verification into consensus-native precompiles, and replace trusted-relayer assumptions with proof/light-client verification.
