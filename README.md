# SYNERGY AICB Exact-Reset — EVM Research Prototype

Three-pool model:

- `SYNA/USDT` — hard quote pool
- `SYNR/USDT` — hard quote pool
- `SYNA/SYNR` — internal triangular leg

## Accounting firewall

The AICB contract **cannot mint USDT**. It can mint/burn only endogenous `SYNA` and `SYNR`.
`hardUsdt()` counts only:

1. USDT held by AICB;
2. USDT reserves in `SYNA/USDT`;
3. USDT reserves in `SYNR/USDT`.

No mark-to-market value of newly minted SYNA/SYNR is counted as hard value.

## Bootstrap

Each pool starts at `0.05 / 0.05`, price 1. External arb profit is supplied as an already-realized hard-USDT input:

`0.39447 + 0.00969 = 0.40416 USDT`

The controller reinvests 100% of this amount into the two USDT pools, making each hard quote reserve `0.25208 USDT`. AICB separately starts with `0.10 USDT`.

Initial hard accounting after bootstrap:

- hard LP USDT: `0.50416`
- AICB USDT: `0.10`
- total hard USDT: `0.60416`

## Exact-reset policy

For a pool with base reserve `x`, quote reserve `y`, and `k = x*y`, target parity uses:

`target = floor(sqrt(k))`

If `y > x`, the AICB mints endogenous base and sells enough toward `target`.
If `x > y`, it spends genuine USDT to buy base, then burns the acquired base.

The AI layer is deliberately separated from the safety kernel: an off-chain policy can decide *when* to call maintenance, but the contract bounds *what* it can do.

## Profit split

Positive hard-USDT market-making PnL per epoch is split:

- `51.32%` -> LP reinvestment
- `48.68%` -> AICB reserve

The `0.40416` external-arbitrage profit is treated separately and reinvested 100% at bootstrap.

## Expected path at 51.32%

| cycles | hard LP USDT | AICB USDT | total hard USDT | next BUY excursion |
|---:|---:|---:|---:|---:|
| 100 | 1.0810430880 | 0.6472071069 | 1.7282501949 | +19.356% |
| 1,000 | 3.1615456438 | 2.6206845896 | 5.7822302334 | +6.426% |
| 10,000 | 10.0498525450 | 9.1546436690 | 19.2044962140 | +1.99998% |

These values require continuous external BUY/SELL flow. They are **not value created by token minting**. The net hard-USDT increase is slippage/spread transferred from external order flow to the system.

## Tests

Run:

```bash
forge test -vvv
```

The suite includes:

- accounting firewall: AICB cannot mint hard quote;
- bootstrap reinvestment of `0.40416`;
- full ERC20 + three-pool integration for 100 cycles;
- EVM-executed integer state-machine tests for 100 / 1,000 / 10,000 cycles;
- final 10,000-cycle transient BUY excursion <= 2%;
- exact-reset parity checks after every integration cycle;
- SELL-first solvency at bootstrap.

## Research status

This is an economic/EVM prototype, **not production financial infrastructure**. It intentionally uses a fee-free simplified CPMM, mock 18-decimal USDT, no oracle latency, no MEV, no gas-cost economics, no ERC20 edge cases, no LP-share accounting, and no external Uniswap fork. A mainnet-fork version is the next validation layer.
