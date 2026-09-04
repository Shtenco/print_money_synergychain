# Project Status

## Current generation

**PRINT MONEY SYNERGYCHAIN V1 — CODE/CI integration generation**

### Implemented

- SINERGY L1 G0 chain profile (`8453001`).
- PQ admission RPC (`9545`) over a private EVM backend (`9546`).
- ML-DSA-87 and SLH-DSA-SHAKE-256s authorization path.
- ICrossDomainMessenger-style trusted Base↔SINERGY corridor.
- source-event replay guard and remote sender/source-chain checks.
- `SinergyQEController` with QE amplitude, partial gradient transfer and QT debt clearing.
- two-phase Base OPEN/CLOSE executor.
- pinned Base WETH/USDC Uniswap V3 adapter.
- permissionless profitable close attempt.
- forced unwind after deadline with explicit loss accounting.
- bidirectional relayer.
- Solidity and PQ Python CI.

### Not yet production complete

- native multi-validator PQ consensus;
- native `revm/reth` PQ precompile integration;
- light-client/proof bridge replacing trusted relayer;
- production key management/HSM;
- Base Mainnet deployment;
- full current-state Base-fork economic validation of the two-phase strategy;
- MEV-protected routing;
- formal verification/audit;
- production observability and incident response.

## Next milestones

### G1 — reproducible local node

- systemd/container packaging;
- deterministic genesis/config;
- health metrics;
- automated restart/state backup.

### G2 — Base fork economic lab

- pinned Base block tests;
- price-impact curves vs `gradientTransferBps`;
- OPEN holding-horizon experiments;
- forced-unwind distributions;
- gas/slippage/MEV sensitivity.

### G3 — controlled live corridor

- fresh keys;
- minimal Base inventory;
- deploy messenger/executor with strict caps;
- shadow mode and human approval.

### G4 — native PQ L1

- validator consensus;
- native execution client;
- ML-DSA/SLH-DSA precompiles;
- deterministic NEXUS execution/proof boundary;
- proof/light-client bridge.

## Economic acceptance rule

No version should be promoted because synthetic PnL looks positive. Promotion requires repeatable positive canonical external NAV after every fee, gas, slippage and complete settlement cost is included.
