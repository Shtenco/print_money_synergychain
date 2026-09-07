# AICB V2.1 — Mainnet-Fork Economic Firewall

Status: **research prototype; not production/audited code**.

Commit tested: `9382185a1fd1707af4feb9a1b8190748309028f5`

GitHub Actions run: `34163149904` — SUCCESS.

## Real mainnet references used by fork test

- Ethereum USDC: `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`
- Ethereum USDT: `0xdAC17F958D2ee523a2206206994597C13D831ec7`
- Uniswap V3 USDC/USDT 0.01% pool: `0x3416cF6C708Da44DB2624D63ea0AAef7113527C6`
- Aave V3 Ethereum Pool: `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2`
- Chainlink ETH/USD: `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419`

Latest tested fork snapshot:

- block: `25,928,154`
- basefee: `45,379,389 wei`
- ETH/USD: `$2,491.2401`
- live Aave flash premium: `5 bps`
- Uniswap V3 liquidity() at referenced pool: `25,049,159,015,958,359`

## Real protocol friction probe

A real fork call borrowed `10,000 USDC` from Aave V3 and executed USDC→USDT→USDC against the real 1-bp Uniswap V3 pool.

- Aave premium: `5.000000 USDC`
- total flash + two-swap balance loss: `6.999901 USDC`
- implied extra two-swap friction: about `1.999901 USDC`
- measured gas: `482,488`

## Real USDT exact-reset smoke test

The internal research pools use real forked USDT while SYNA/SYNR remain research mintable assets.

- hard USDT before: `0.604160`
- hard USDT after one BUY→reset→SELL→reset sequence: `0.629189`
- gross hard delta before execution-cost accounting: `+0.025029 USDT`

Measured gas:

- external BUY: `130,958`
- AICB BUY reset: `168,566`
- external SELL: `132,937`
- AICB SELL reset: `165,588`

## 10,000-cycle strict stochastic firewall — original $0.05 scale

Assumptions:

- random pool and BUY/SELL direction from fixed deterministic seed;
- external AMM fee `30 bps`;
- exact AICB resets;
- `51.32%` profit reinvest waterfall every 100 cycles where reserve floor permits;
- reserve floor sized to 1,000 stressed SELL resets;
- `MEV = 5 bps` haircut;
- live Aave premium `5 bps`;
- two Uniswap 1-bp legs = `2 bps` additional nominal friction;
- system-only gas view: system pays reset gas (`170,000`/cycle), external users pay their own trade gas;
- all-in gas view: `300,000` gas/cycle;
- second scenario adds `0.1 gwei` priority fee.

At `scale=1`:

- trade size: `$0.05`
- initial hard USDT: `$0.604160`
- hard final: `$48.605096`
- AICB reserve final: `$46.861303`
- LP hard final: `$1.743793`
- gross hard profit before gas/friction: `$48.000936`
- explicit reinvest: `$1.055332`
- MEV haircut: `$0.250000`
- Aave + V3 nominal friction: `$0.350000`

Execution-cost-adjusted KPI:

| Accounting view | Net after 10k cycles |
|---|---:|
| System pays resets, basefee only | **-$144.785685** |
| System pays resets, +0.1 gwei | **-$568.296502** |
| All-in gas, basefee only | **-$291.751924** |
| All-in gas, +0.1 gwei | **-$1,039.123954** |

Therefore the original `$0.05` micro-scale **FAILS** the mainnet economic firewall even though gross hard-USDT rises before execution costs.

## Scale sweep — first positive point for the tested seed

The relative pool/trade geometry is held constant and all hard balances/trade size scale together.

| Scenario | First positive scale | Trade size | Initial hard USDT |
|---|---:|---:|---:|
| System gas, basefee only | **4×** | **$0.20** | **$2.416640** |
| System gas, +0.1 gwei | **13×** | **$0.65** | **$7.854080** |
| All-in gas, basefee only | **7×** | **$0.35** | **$4.229120** |
| All-in gas, +0.1 gwei | **22×** | **$1.10** | **$13.291520** |

These thresholds are **not universal guarantees**. They are first-positive integer scales for one fixed stochastic seed and one observed mainnet snapshot. The next validation layer must use many independent seeds, basefee regimes, directional order-flow bias, higher MEV/adverse-selection assumptions, oracle delay, and batched/keeper execution.

## Interpretation

The V2 result is deliberately stricter than the V1 accounting model:

1. Internal SYNA/SYNR minting never counts as hard value.
2. Real Aave and real Uniswap V3 friction are probed on a current mainnet fork.
3. `HardUSDT` can grow gross while the economic strategy still loses after gas.
4. At the original `$0.05` scale Ethereum L1 gas dominates the alpha.
5. Scaling transaction notional or reducing execution frequency/cost can cross break-even in the tested model.

The next target is V2.2: multi-seed Monte Carlo + biased SELL stress + gas/basefee grid + batched resets, with a pass condition based on a positive lower-tail distribution of `ΔHardUSDT_after_all_costs`, not a single seed.
