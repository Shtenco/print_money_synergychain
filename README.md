# print_money_synergychain

SYNERGY print-machine / QE / AMM research surface.

Status: **R&D / falsifiable economic model, not an autonomous value source, not production-authorized.**

## 2026-09-05 convergence

This repository is now explicitly coupled to:

- `Shtenco/synergy_pay_system` — MetaPay Classic Finance/CEX/P2P/DEX route and settlement evidence;
- `Shtenco/ai_financial_system` — DEX/AMM/flash/QE research;
- `Shtenco/synergy_financial_os` — canonical accounting, external P&L and NAV;
- `Shtenco/synergy_system` — economic constitution and governance.

The print-machine is treated as an **opportunity amplifier / internal market-geometry engine**. Mint, burn, internal revaluation, own-token market cap and movement of protocol-owned reserves do not create canonical external profit.

The only compounding loop counted as wealth is:

```text
real MetaPay/Classic P&L
        +
real DEX arbitrage P&L
        ↓
Financial OS settlement/accounting
        ↓
HardNAV / liquidity / capacity
        ↓
human-authorized bounded allocation
        ↓
DEX / CEX / bank / P2P inventory
        ↓
new externally closable route
        ↓
real settlement
        ↓
repeat
```

Mathematically:

```text
R[t+1] = R[t] + P_classic[t] + P_dex[t] - C[t] - distributions[t]
```

Only externally settled `P_classic` and `P_dex` count as canonical P&L.

## Falsifiable reference model

`model/hybrid_print_machine.py` deliberately enforces:

- huge internal mint does not change HardNAV;
- arbitrary internal revaluation does not change HardNAV;
- moving owned external cash into a DEX reserve changes location, not wealth;
- a route can increase external wealth only through positive realized external settlement after costs;
- flash principal must be repaid;
- independent external counterparty/market evidence is required.

Run:

```bash
python -m pytest -q
```

## Important accounting boundary

An external cash inflow from selling an issued/internal token can be real cash, but it is **not automatically arbitrage profit**. Financial OS must classify whether the inflow is revenue, equity/capital, liability or another accounting class.

## No authority escalation

This repository does not authorize autonomous payment, signing, deployment or capital allocation. AI/NEXUS may analyze and propose only. Human/multisig/operator authority remains required.
