# Economic Model — QE Gradient Machine

## 1. Objective

The system does not treat token issuance or internal accounting profit as external wealth. The purpose of QE is to create a controlled **internal price gradient** and use that gradient to direct a bounded external market action.

Core cycle:

```text
QE_L1
  -> ΔP_internal
  -> α * ΔP_external
  -> external market/order flow
  -> inverse close
  -> ΔNAV_Base
  -> settlement
  -> QT
```

with:

```text
α = gradientTransferBps / 10000
0 < α <= 1
```

## 2. Internal QE price

For a neutral internal price `P0` and QE amplitude `q`:

```text
P_internal = P0 * (1 + q)
```

The V1 controller bounds `|q|` to 20% (`MAX_ABS_QE_BPS = 2000`).

The corresponding internal QE debt is tracked explicitly:

```text
qeDebt = principal * |qePremiumBps| / 10000
```

This debt is internal accounting only. It has zero canonical external NAV.

## 3. Partial gradient transfer

The system separates two controls:

- **QE amplitude** — how far the internal price is moved.
- **gradientTransferBps** — how much external notional is allowed to express that signal.

Example:

```text
qePremiumBps       = +1000   (+10%)
gradientTransferBps = 2500   (25%)
principal           = 100 USDC
external notional   = 25 USDC
```

Positive QE directs the Base adapter to buy WETH with USDC. Negative QE directs it to sell WETH into USDC.

## 4. OPEN / HOLD / CLOSE

### OPEN

A bounded part of protocol-owned canonical Base inventory is exchanged against the configured external pool.

### HOLD

The position may stay open across blocks while unrelated traders, arbitrageurs, aggregators and MEV activity change the external executable state.

A flash loan cannot finance this cross-block holding period because flash principal must be repaid atomically in the same transaction.

### CLOSE

The inverse leg is attempted at current executable external prices.

The normal CLOSE is valid only if:

```text
NAV_after >= NAV_before + minCanonicalGain
```

Otherwise the entire CLOSE transaction reverts and the OPEN position remains intact.

## 5. Forced unwind

A profitable close cannot be guaranteed. Therefore V1 includes `forceUnwindExpired` after the intent deadline.

Forced unwind may realize a loss. That loss is counted explicitly in `cumulativeForcedCanonicalLossUsdc6` and returned to SINERGY L1 in the settlement receipt.

This prevents a failed cycle from being hidden by leaving it permanently open.

## 6. Canonical NAV

Canonical Base NAV is the external-value metric.

For the pinned WETH/USDC adapter it is conceptually:

```text
NAV = USDC balance + executable WETH->USDC liquidation quote
```

No internal QE debt, synthetic executor PnL or internal pool mark-up is added to canonical NAV.

## 7. What QE can and cannot do

QE can:

- create an internal control gradient;
- choose direction and bounded size of external execution;
- coordinate liquidity migration between internal accounting state and external markets;
- create a structured opportunity to capture external price recovery/order flow.

QE cannot, by accounting identity alone:

- mint Base USDC or WETH;
- turn internal debt cancellation into external reserves;
- guarantee that outside traders will restore the pool at a favorable price;
- guarantee profit after fees, slippage, gas and MEV.

## 8. Economic PASS

A production candidate should require at least:

```text
NAV_after > NAV_before
QE debt end = 0
adapter residual = 0
no hidden flash debt
all external costs accounted
```

For attribution research, the stronger test is a same-state counterfactual comparison:

```text
QE_CAUSAL_NAV = ΔNAV(QE path) - ΔNAV(control path)
```

This helps separate value caused by the strategy from an external arbitrage edge that existed independently.

## 9. Research roadmap

The next economic research layer should measure:

1. real Base-fork price impact as a function of `gradientTransferBps`;
2. expected outside-flow recovery distribution by holding horizon;
3. venue selection across Uniswap/Aerodrome/Pancake;
4. gas + MEV + slippage break-even surfaces;
5. inventory sizing and forced-unwind risk;
6. causal A/B tests versus identical no-QE and no-transfer baselines.
