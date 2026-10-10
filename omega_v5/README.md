# SYNERGY OMEGA V5 — external-cash-flow research and Base fork tests

This is NOT evidence of profitable arbitrage or a production deployment.

## Deliverable
Solidity RevenueVault, MockUSDC, Foundry tests, Base native USDC chainId 8453 smoke test, and independent economic bookkeeping design. The complete local source package is shared in the companion ZIP. The fork smoke does not claim real profitable transactions. Actual Base RPC and Foundry were not available in the authoring environment.

Run:
```bash
cd omega_v5
forge test --match-contract RevenueVaultTest -vvv
BASE_RPC_URL="YOUR_RPC" forge test --match-contract BaseForkSmoke -vvv
```
- Base USDC address: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`.
- Independent service fee = external transfer; refundable balances are obligations and subtracted from HardNAV.
- Self-funding does not produce protocol revenue.
- Realized earnings can be distributed only within cap and reserve coverage.
- A 30% owner payout decreases protocol HardNAV; consolidated owner+protocol NAV is not the same metric.
- Future gates: actual A-F token+LP deployment, Curve and Uniswap v3/v4 implementations, full Base fork swaps and receipts, LVR pricing, external trade P&L, stress redemption with liabilities.

Do not treat scenario gross revenue, internally marked TVL, or flash capital as profit.