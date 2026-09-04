# BASE-FORK V2 — real-state causal NAV study

## Goal

Measure the two-phase PRINT MONEY engine on real Base Mainnet state before any live capital is used.

The study separates two questions that must not be conflated:

1. **Contract mechanics on a real fork** — does the deployed V1 contract path behave correctly against the actual Base WETH/USDC pool?
2. **Causal economics across time** — if OPEN occurs at historical block `t0` and CLOSE occurs at the genuinely later block `t0+h`, does outside market flow offset round-trip drag and produce positive canonical NAV?

## Real venue

- Base Mainnet chain id: `8453`
- WETH: `0x4200000000000000000000000000000000000006`
- USDC: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`
- Uniswap V3 WETH/USDC 0.30% pool: `0x6c561B446416E1A00E8E93E221854d6eA4171372`
- QuoterV2: `0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a`
- SwapRouter02: `0x2626664c2603336E57B271c5C0b26F421741e481`

The workflow uses the official Base archive-capable RPC endpoint by default.

## Parameter grid

Default V2 grid:

- `abs(qePremiumBps)` = `100, 250, 500, 1000, 1500, 2000`
- `gradientTransferBps` = `250, 500, 1000, 2500, 5000, 10000`
- holding horizon = `5m, 15m, 1h, 4h, 12h, 24h`
- principal = `10,000 USDC`
- historical anchors = `6` over a `72h` lookback by default

## Critical V1 structural fact

In the current contracts, `qePremiumBps` amplitude does **not** scale Base trade size.

The adapter uses:

```text
transferNotional = principalUsdc6 × gradientTransferBps / 10000
```

and only uses the sign of `qePremiumBps`:

```text
qePremiumBps > 0  => USDC -> WETH on OPEN
qePremiumBps < 0  => WETH -> USDC on OPEN
```

Therefore the V2 optimizer explicitly audits amplitude invariance instead of pretending that amplitude is an independent sizing dimension. If every other variable is fixed, all positive QE amplitudes must produce the same Base path, and all negative amplitudes must produce the same Base path.

If a future policy wants stronger QE to create a larger external impulse, that coupling belongs in V3 and must be explicit.

## Causal NAV definition

### Positive QE

At start block `t0`:

```text
N USDC -> WETH_open
```

At later block `t1 = t0 + h`:

```text
WETH_open -> USDC_close
```

Marginal canonical NAV delta:

```text
DeltaNAV = USDC_close - N
```

### Negative QE

The calculation follows the current adapter literally.

At `t0`, first size the WETH leg using a USDC->WETH quote, then sell that WETH into USDC. At `t1`, buy WETH back from the resulting USDC and value the final WETH using the same canonical USDC liquidation rule used by the executor.

This is intentionally not replaced by a simpler theoretical short model: the point is to audit the code that actually exists.

## What is causal here

OPEN quotes are evaluated only against the state at `t0`.

CLOSE quotes and final canonical valuation are evaluated only against the actual later archived Base state at `t1`.

No future price is used to construct the OPEN leg. The future block is used only for ex-post evaluation of the chosen horizon.

## Costs

Uniswap V3 fee and price impact are embedded in QuoterV2 outputs.

The executor's canonical NAV is USDC/WETH inventory NAV. Relayer ETH gas is paid outside that inventory and is therefore reported separately from this V2 NAV metric rather than silently mixed into it.

## Fork smoke controls

`test/BaseForkV2.t.sol` runs the actual contracts against a real Base fork.

The control test deliberately attempts OPEN and immediate CLOSE against the same market state. A clean round trip must not manufacture canonical gain. The normal CLOSE must revert if NAV has not recovered, then `forceUnwindExpired` must close the position and record any canonical loss explicitly.

Both positive and negative QE directions are tested.

## Output

The causal optimizer writes:

- `results/base_fork_v2_grid.csv`
- `results/base_fork_v2_summary.json`
- `results/BASE_FORK_V2_REPORT.md`

The report ranks mechanical cells by mean causal NAV delta and win rate, but the result is **research evidence**, not a claim of guaranteed profit.

## Next gates

V2 is only a first real-state screen. Any candidate edge must then survive:

1. larger multi-week/month archive sample;
2. walk-forward segmentation by date;
3. independent holdout periods;
4. gas/relayer operational cost accounting;
5. principal-size sensitivity and price-impact scaling;
6. alternative Base venues and best-route comparison;
7. forced-unwind tail analysis;
8. only then a minimal-capital canary.
