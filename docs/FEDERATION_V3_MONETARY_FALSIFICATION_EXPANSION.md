# Federation V3 — Monetary / Liquidity Falsification expansion

Historical Part V/IX contains ambitious fund, currency, liquidity and growth ideas. This repository exists to test those mechanisms under the strict external-value firewall.

## Core invariants
- `mint != profit`;
- `rebase != profit`;
- `internal mark-up != HardNAV`;
- `moving own cash into own LP != profit`;
- `flash principal != owned capital`;
- only externally settled, reconciled value may increase HardNAV.

## Research scope
- AMM/QE/QT mechanisms;
- triangular and multi-loop liquidity systems;
- bridge/reserve mechanics;
- temporary flash liquidity;
- token issuance/burn/buyback;
- capacity and solvency constraints;
- external arbitrage/fee/revenue sources;
- failure and insolvency simulations.

## Required outputs
Every experiment must publish:
`DeltaHardNAV`, `DeltaExternalCash`, `DeltaLiabilities`, `ExternalPnL`, `InternalMarkChange`, `FlashDebt`, `Solvency`, `Liquidity`, `ExecutionCosts`.

## Rule
The purpose of this repo is falsification: prove when an apparent “printing machine” is only internal accounting/revaluation, and isolate the external mechanism when real profit exists.
