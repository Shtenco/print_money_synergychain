# SYNERGY OMEGA V3 — HardNAV Base Fork research

Research branch, not audited production. Six self-funded 0.5 USDC buys do not create dollars. HardNAV is based on independent dollar assets net of obligations; own-token marks and internal transfers are not profit.

**Fork smoke test**: requires Foundry and BASE_RPC_URL. Uses native Circle Base USDC at 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913, checks chain 8453 and decimals, deploys research escrow, asserts self-operations cannot create recognized revenue. Run from this directory:

```sh
export BASE_RPC_URL='https://your-base-rpc'
forge test --match-contract BaseForkTest -vvv
```

The fork test has NOT yet been run; the environment used to author this lacks Foundry and Base RPC. This is a smoke test, NOT full six-level EVM AMM / live borrower backtest.

Local Python economic simulation (full Python script and test suite distributed in corresponding ZIP): starts with 7000 USDC treasury + 3000 USDC protocol pool, 6 self funded buys 0.5 => profit $0. 30 independent assumed $5 service payments less $0.50 expenses each => +$135 consolidated profit; after 30% operator payout, protocol HardNAV is $10094.50. Stress loss of $400 => -$265 consolidated. Payment inputs are assumptions, not evidence of real customers. Financial OS must validate receipts before recognizing profit.

**TODO before any live deployment**: true ERC20 collateralized A-F tokens, on-chain LP accounting, revenue source evidence, borrowers, oracles, economic risk controls, exact gas accounting, tests against deployed pools, solvency and liquidation stress. Never infer profits from internally increased TVL.
