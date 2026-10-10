# SYNERGY OMEGA V4: inflation-bounded graph AMM

Research-only architecture derived from Uniswap v3 concentrated liquidity, Uniswap v4 hooks/dynamic fees, Curve StableSwap and Aave GHO facilitator caps. **Not** a deployment nor a tested Base fork.

## Invariants
- Initial independent USDC = 10,000; six protocol-owned pools, 500 USDC + 500 A..F each; vault = 7,000 USDC.
- Reported spot TVL = sum(USDC reserve + internal-token reserve × own-pool spot price); this is NOT redeemable HardNAV.
- HardNAV = independent dollar assets – external liabilities. Never count self-issued tokens, circular collateral, or a flash loan as new NAV.
- Any mint of redeemable tokens raises liabilities unless real independent eligible collateral is locked and verified; no free mint from LP spot price.
- Self-funded A→B→C→D→E→F→A swaps conserve consolidated USDC (less actual external costs). Fee booked from own wallet is NOT revenue.
- For fee-zero CPMM, relative price after selling Δx: (x/(x+Δx))². Max Δx at ε drop: x*(1/sqrt(1–ε)–1).
- Virtual CPMM uses (x+vx)*(y+vy)=k only as an approximate experimental curve; virtual USDC is never spendable. Actual Curve StableSwap and Uniswap v3 math must be integrated separately.
- Route only swaps meeting executable independent oracle/slippage and LVR budgets. No arbitrage P&L recognized from internal quote changes.
- Only independently paid external service fees and realized market gains net of expenses may be distributed (70% retained for collateral, up to 30% payout), subject to liquidity and solvency.

## Reproducible V4 Python experiment
The complete 7-test executable prototype, scenario outputs and documentation are in the accompanying downloadable package shared in the project conversation. Key results: circular issuance blocked with zero independent collateral => HardNAV 10,000; unsafe hypothetical $30.204559 debt issue with zero extra dollars => HardNAV 9,969.795441; assumed 30 independent $5 service payments and $15 total costs => +$135 before a $40.50 operator payout, post-payout entity HardNAV 10,094.50; $400 stress loss before payout => HardNAV 9,735.

These are **local Python accounting experiments**, not actual EVM execution, fork receipts, or an estimate of DeFi returns.

## Next integration gates
1. Authentic ERC20 A-F collateral vaults, redemption limits and liquidation; independent collateral oracle.
2. Real Uniswap v4 PoolManager/Hook and v3 concentrated pools, plus comparison with Curve invariant.
3. Exact external execution receipts, fees and LVR measurement, not mock P&L.
4. Foundry on Base RPC chain 8453: invariant/fuzz tests, sandwich/MEV, oracle manipulation, insolvency and rapid redemption.
5. Export verified external receipts into synergy_financial_os canonical accounting and refuse to recognize hypothetical volume as profit.

Official references:
- https://developers.uniswap.org/docs/get-started/concepts/hooks
- https://developers.uniswap.org/docs/protocols/v4/guides/custom-accounting
- https://aave.com/docs/ecosystem/gho
- https://docs.curve.finance/
