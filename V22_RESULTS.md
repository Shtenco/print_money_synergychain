# AICB V2.2 — P5 Distribution Firewall

Status: **research prototype; not production/audited code**.

Tested commit: `bd689c89fcfd3051deef7572800036cbbfc9c37b`

GitHub Actions run: `34165059321` — **SUCCESS**.

## What V2.2 tests

For each order-flow regime V2.2 runs **64 independent deterministic seeds × 10,000 market events** and takes the discrete 5th percentile (4th-lowest result of 64 samples).

SELL-share regimes:

- 50% SELL / 50% BUY
- 55% SELL / 45% BUY
- 60% SELL / 40% BUY
- 70% SELL / 30% BUY

Every path uses the V2 exact-reset CPMM state machine, 30 bps external AMM fee, 51.32% reinvest waterfall every 100 events where the reserve floor permits, and a reserve floor sized to 1,000 stressed SELL resets.

For solvent P5 regimes the grid then applies:

- MEV haircut: `5 / 10 / 25 / 50 bps`
- gas multiplier: `1x / 2x / 5x`
- batching: `1 / 5 / 20 / 100` events
- system-only gas and all-in gas views
- Ethereum and Base execution-cost models
- live Aave premium from Ethereum fork (`5 bps`)
- two nominal Uniswap V3 1-bp legs (`2 bps`)

The economic pass condition is based on **P5 net hard-USDT after modeled costs**, never on minted SYNA/SYNR value.

## Live fork metrics during the successful run

Mainnet smoke test:

- Ethereum fork block: `25,928,318`
- basefee: `60,916,459 wei` in the mainnet smoke test
- ETH/USD: `$2,492.23876228`
- Aave V3 flash premium: `5 bps`
- real 10,000 USDC flash + USDC→USDT→USDC probe total loss: `6.999901 USDC`
- flash premium component: `5.000000 USDC`
- measured flash + two-swap gas: `489,207`

The separate V2.2 bias tests observed Ethereum basefee around `53.6–57.5m wei`; Base basefee was `5,000,000 wei`.

## Distribution results

| SELL share | Insolvent paths | P5 gross hard PnL | Median gross | P95 gross | P5 solvency |
|---:|---:|---:|---:|---:|---|
| 50% | **0 / 64** | **$45.484655** | $49.152182 | $53.940931 | **PASS** |
| 55% | **0 / 64** | **$13.889077** | $18.961519 | $26.213989 | **PASS** |
| 60% | **64 / 64** | $0 | $0 | $0 | **FAIL** |
| 70% | **64 / 64** | $0 | $0 | $0 | **FAIL** |

The 60/40 and 70/30 failures happen before gas/MEV optimization: the AICB hard quote reserve is exhausted by persistent net SELL pressure. Homogeneous scaling of trade size, LP and reserve together does not remove this structural imbalance in this model.

## Break-even scale frontier — 50/50

Base geometry at scale 1:

- trade = `$0.05`
- initial hard USDT = `$0.604160`

### Ethereum

| Grid view | Scale | Trade | Initial hard USDT |
|---|---:|---:|---:|
| Best system cell | **4×** | $0.20 | $2.416640 |
| Default system (`batch=20, gas=1x, MEV=25bps`) | **4×** | $0.20 | $2.416640 |
| Worst system cell | **27×** | $1.35 | $16.312320 |
| Best all-in cell | **8×** | $0.40 | $4.833280 |
| Worst all-in cell | **48×** | $2.40 | $28.999680 |

### Base

| Grid view | Scale | Trade | Initial hard USDT |
|---|---:|---:|---:|
| Best system cell | **1×** | $0.05 | $0.604160 |
| Default system (`batch=20, gas=1x, MEV=25bps`) | **1×** | $0.05 | $0.604160 |
| Worst system cell | **3×** | $0.15 | $1.812480 |
| Best all-in cell | **1×** | $0.05 | $0.604160 |
| Worst all-in cell | **5×** | $0.25 | $3.020800 |

Thus the balanced-order-flow regime has a finite positive P5 scale in **every tested Base system-cost grid cell**.

## Break-even scale frontier — 55/45 SELL bias

### Ethereum

| Grid view | Scale | Trade | Initial hard USDT |
|---|---:|---:|---:|
| Best system cell | **13×** | $0.65 | $7.854080 |
| Default system (`batch=20, gas=1x, MEV=25bps`) | **15×** | $0.75 | $9.062400 |
| Worst system cell | **111×** | $5.55 | $67.061760 |
| Best all-in cell | **28×** | $1.40 | $16.916480 |
| Worst all-in cell | **195×** | $9.75 | $117.811200 |

### Base

| Grid view | Scale | Trade | Initial hard USDT |
|---|---:|---:|---:|
| Best system cell | **2×** | $0.10 | $1.208320 |
| Default system (`batch=20, gas=1x, MEV=25bps`) | **2×** | $0.10 | $1.208320 |
| Worst system cell | **10×** | $0.50 | $6.041600 |
| Best all-in cell | **3×** | $0.15 | $1.812480 |
| Worst all-in cell | **17×** | $0.85 | $10.270720 |

Again Base has a finite positive P5 scale in every tested system-cost grid cell, but 55/45 requires materially more hard capital than 50/50.

## Fundamental result

V2.2 separates two different failure modes:

1. **Execution-cost failure** — solvable by batching, cheaper L2 execution or larger notional. This is what dominates balanced/55-45 flow on Ethereum.
2. **Hard-reserve solvency failure** — not solved by homogeneous scaling. This dominates 60/40 and 70/30 SELL-biased flow in the current exact-reset architecture.

Therefore the next architecture should not merely optimize gas. It needs an explicit net-flow defense, for example a dynamic peg corridor / asymmetric reset strength / inventory-sensitive fee / external redemption collateral or replenishment rule, and it must prove that this defense does not manufacture hard value internally.

## Important Base-cost limitation

The Base part is a real Base fork for `block.basefee` and the GasPriceOracle predeploy, but its L1 data-fee estimate currently uses synthetic non-zero calldata samples. In this run `getL1Fee` returned roughly `0.683–0.698 gwei` per modeled batch and the operator-fee query returned zero. The fact that the sampled L1 fee was nearly constant across batch sizes means this part should be treated as an **approximation**, not a production-grade transaction-cost measurement.

The next validation should execute actual batched keeper transactions on a Base fork and measure their receipts / exact encoded calldata cost rather than infer batching economics from synthetic payloads.
