#!/usr/bin/env python3
from __future__ import annotations

import csv
import json
import math
import os
import statistics
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from web3 import Web3

BASE_CHAIN_ID = 8453
WETH = Web3.to_checksum_address('0x4200000000000000000000000000000000000006')
USDC = Web3.to_checksum_address('0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913')
QUOTER_V2 = Web3.to_checksum_address('0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a')
POOL = Web3.to_checksum_address('0x6c561B446416E1A00E8E93E221854d6eA4171372')
POOL_FEE = 3000
BPS = 10_000

QUOTER_ABI = [{
    'inputs': [{
        'components': [
            {'internalType': 'address', 'name': 'tokenIn', 'type': 'address'},
            {'internalType': 'address', 'name': 'tokenOut', 'type': 'address'},
            {'internalType': 'uint256', 'name': 'amountIn', 'type': 'uint256'},
            {'internalType': 'uint24', 'name': 'fee', 'type': 'uint24'},
            {'internalType': 'uint160', 'name': 'sqrtPriceLimitX96', 'type': 'uint160'},
        ],
        'internalType': 'struct IQuoterV2.QuoteExactInputSingleParams',
        'name': 'params',
        'type': 'tuple',
    }],
    'name': 'quoteExactInputSingle',
    'outputs': [
        {'internalType': 'uint256', 'name': 'amountOut', 'type': 'uint256'},
        {'internalType': 'uint160', 'name': 'sqrtPriceX96After', 'type': 'uint160'},
        {'internalType': 'uint32', 'name': 'initializedTicksCrossed', 'type': 'uint32'},
        {'internalType': 'uint256', 'name': 'gasEstimate', 'type': 'uint256'},
    ],
    'stateMutability': 'nonpayable',
    'type': 'function',
}]

POOL_ABI = [
    {'inputs': [], 'name': 'token0', 'outputs': [{'type': 'address'}], 'stateMutability': 'view', 'type': 'function'},
    {'inputs': [], 'name': 'token1', 'outputs': [{'type': 'address'}], 'stateMutability': 'view', 'type': 'function'},
    {'inputs': [], 'name': 'fee', 'outputs': [{'type': 'uint24'}], 'stateMutability': 'view', 'type': 'function'},
]

@dataclass(frozen=True)
class Row:
    anchor_block: int
    anchor_ts: int
    close_block: int
    close_ts: int
    horizon_seconds: int
    qe_bps: int
    transfer_bps: int
    principal_usdc: float
    transfer_notional_usdc: float
    direction: str
    nav_before_usdc: float
    nav_after_usdc: float
    delta_usdc: float
    delta_bps: float


def percentile(values: list[float], p: float) -> float:
    if not values:
        return float('nan')
    xs = sorted(values)
    if len(xs) == 1:
        return xs[0]
    x = (len(xs) - 1) * p
    lo = math.floor(x)
    hi = math.ceil(x)
    if lo == hi:
        return xs[lo]
    return xs[lo] * (hi - x) + xs[hi] * (x - lo)


class RetryWeb3:
    def __init__(self, url: str) -> None:
        self.w3 = Web3(Web3.HTTPProvider(url, request_kwargs={'timeout': 45}))
        self.quoter = self.w3.eth.contract(address=QUOTER_V2, abi=QUOTER_ABI)
        self.pool = self.w3.eth.contract(address=POOL, abi=POOL_ABI)
        self.block_cache: dict[int, dict[str, Any]] = {}
        self.quote_cache: dict[tuple[str, str, int, int], int] = {}

    def call_retry(self, fn, *, tries: int = 7):
        last: Exception | None = None
        for i in range(tries):
            try:
                return fn()
            except Exception as exc:
                last = exc
                time.sleep(min(8.0, 0.5 * (2 ** i)))
        assert last is not None
        raise last

    def block(self, n: int) -> dict[str, Any]:
        if n not in self.block_cache:
            self.block_cache[n] = dict(self.call_retry(lambda: self.w3.eth.get_block(n)))
        return self.block_cache[n]

    def quote(self, token_in: str, token_out: str, amount_in: int, block: int) -> int:
        key = (token_in, token_out, amount_in, block)
        if key in self.quote_cache:
            return self.quote_cache[key]
        params = (token_in, token_out, amount_in, POOL_FEE, 0)
        out = self.call_retry(
            lambda: self.quoter.functions.quoteExactInputSingle(params).call(block_identifier=block)
        )[0]
        out = int(out)
        if out <= 0:
            raise RuntimeError(f'zero quote at block={block} amount={amount_in}')
        self.quote_cache[key] = out
        return out

    def block_at_or_before(self, target_ts: int, lo: int, hi: int) -> int:
        while lo < hi:
            mid = (lo + hi + 1) // 2
            ts = int(self.block(mid)['timestamp'])
            if ts <= target_ts:
                lo = mid
            else:
                hi = mid - 1
        return lo


def main() -> None:
    rpc = os.environ.get('BASE_RPC_URL', 'https://mainnet.base.org')
    principal_usdc = float(os.environ.get('V2_PRINCIPAL_USDC', '10000'))
    lookback_hours = int(os.environ.get('V2_LOOKBACK_HOURS', '72'))
    anchors_n = int(os.environ.get('V2_ANCHORS', '6'))
    out_dir = Path(os.environ.get('V2_OUT_DIR', 'results'))
    out_dir.mkdir(parents=True, exist_ok=True)

    qe_abs_grid = [100, 250, 500, 1000, 1500, 2000]
    transfer_grid = [250, 500, 1000, 2500, 5000, 10000]
    horizon_grid = [300, 900, 3600, 14_400, 43_200, 86_400]

    c = RetryWeb3(rpc)
    chain_id = int(c.call_retry(lambda: c.w3.eth.chain_id))
    if chain_id != BASE_CHAIN_ID:
        raise RuntimeError(f'RPC chain id {chain_id} != Base {BASE_CHAIN_ID}')

    token0 = Web3.to_checksum_address(c.call_retry(lambda: c.pool.functions.token0().call()))
    token1 = Web3.to_checksum_address(c.call_retry(lambda: c.pool.functions.token1().call()))
    fee = int(c.call_retry(lambda: c.pool.functions.fee().call()))
    if {token0, token1} != {WETH, USDC} or fee != POOL_FEE:
        raise RuntimeError('Pinned pool identity mismatch')

    head = int(c.call_retry(lambda: c.w3.eth.block_number))
    head_block = c.block(head)
    head_ts = int(head_block['timestamp'])
    max_h = max(horizon_grid)
    earliest_ts = head_ts - lookback_hours * 3600 - max_h - 120

    lo_guess = max(1, head - int((lookback_hours * 3600 + max_h + 600) / 1.5))
    while int(c.block(lo_guess)['timestamp']) > earliest_ts and lo_guess > 1:
        lo_guess = max(1, lo_guess - 100_000)

    usable_end_ts = head_ts - max_h - 30
    usable_start_ts = usable_end_ts - lookback_hours * 3600
    if anchors_n == 1:
        anchor_ts_list = [usable_end_ts]
    else:
        step = (usable_end_ts - usable_start_ts) / (anchors_n - 1)
        anchor_ts_list = [int(usable_start_ts + i * step) for i in range(anchors_n)]

    anchor_blocks: list[tuple[int, int]] = []
    search_lo = lo_guess
    for ts in anchor_ts_list:
        b = c.block_at_or_before(ts, search_lo, head)
        bt = int(c.block(b)['timestamp'])
        anchor_blocks.append((b, bt))
        search_lo = b

    core: dict[tuple[int, int, int, int], tuple[float, float]] = {}
    rows: list[Row] = []
    principal_6 = int(round(principal_usdc * 1_000_000))

    for anchor_block, anchor_ts in anchor_blocks:
        for horizon in horizon_grid:
            target_ts = anchor_ts + horizon
            close_block = c.block_at_or_before(target_ts, anchor_block, head)
            close_ts = int(c.block(close_block)['timestamp'])
            for transfer_bps in transfer_grid:
                notional_6 = principal_6 * transfer_bps // BPS
                if notional_6 <= 0:
                    continue
                key = (anchor_block, close_block, transfer_bps, 1)
                if key not in core:
                    open_weth = c.quote(USDC, WETH, notional_6, anchor_block)
                    close_usdc = c.quote(WETH, USDC, open_weth, close_block)
                    pos_before = notional_6 / 1e6
                    pos_after = close_usdc / 1e6
                    core[key] = (pos_before, pos_after)

                neg_key = (anchor_block, close_block, transfer_bps, -1)
                if neg_key not in core:
                    open_input_weth = c.quote(USDC, WETH, notional_6, anchor_block)
                    before_usdc = c.quote(WETH, USDC, open_input_weth, anchor_block)
                    open_out_usdc = before_usdc
                    close_out_weth = c.quote(USDC, WETH, open_out_usdc, close_block)
                    after_usdc = c.quote(WETH, USDC, close_out_weth, close_block)
                    core[neg_key] = (before_usdc / 1e6, after_usdc / 1e6)

                for sign, direction in ((1, 'positive_qe'), (-1, 'negative_qe')):
                    before, after = core[(anchor_block, close_block, transfer_bps, sign)]
                    delta = after - before
                    delta_bps = (delta / before * BPS) if before else float('nan')
                    for amp in qe_abs_grid:
                        rows.append(Row(
                            anchor_block=anchor_block,
                            anchor_ts=anchor_ts,
                            close_block=close_block,
                            close_ts=close_ts,
                            horizon_seconds=horizon,
                            qe_bps=amp * sign,
                            transfer_bps=transfer_bps,
                            principal_usdc=principal_usdc,
                            transfer_notional_usdc=principal_usdc * transfer_bps / BPS,
                            direction=direction,
                            nav_before_usdc=before,
                            nav_after_usdc=after,
                            delta_usdc=delta,
                            delta_bps=delta_bps,
                        ))

    csv_path = out_dir / 'base_fork_v2_grid.csv'
    with csv_path.open('w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=list(Row.__dataclass_fields__.keys()))
        writer.writeheader()
        for r in rows:
            writer.writerow(r.__dict__)

    groups: dict[tuple[str, int, int], list[Row]] = {}
    for r in rows:
        groups.setdefault((r.direction, r.transfer_bps, r.horizon_seconds), []).append(r)

    summary_rows: list[dict[str, Any]] = []
    for (direction, transfer_bps, horizon), items in groups.items():
        by_anchor: dict[int, Row] = {}
        for r in items:
            by_anchor.setdefault(r.anchor_block, r)
        xs = list(by_anchor.values())
        deltas = [r.delta_usdc for r in xs]
        bpss = [r.delta_bps for r in xs]
        summary_rows.append({
            'direction': direction,
            'transfer_bps': transfer_bps,
            'horizon_seconds': horizon,
            'n_anchors': len(xs),
            'mean_delta_usdc': statistics.fmean(deltas),
            'median_delta_usdc': statistics.median(deltas),
            'mean_delta_bps': statistics.fmean(bpss),
            'median_delta_bps': statistics.median(bpss),
            'win_rate': sum(x > 0 for x in deltas) / len(deltas),
            'p05_delta_bps': percentile(bpss, 0.05),
            'p95_delta_bps': percentile(bpss, 0.95),
            'min_delta_bps': min(bpss),
            'max_delta_bps': max(bpss),
        })

    summary_rows.sort(key=lambda x: (x['mean_delta_bps'], x['win_rate']), reverse=True)

    invariant = True
    inv_max_abs_usdc = 0.0
    cells: dict[tuple[int, int, int, str], list[Row]] = {}
    for r in rows:
        cells.setdefault((r.anchor_block, r.horizon_seconds, r.transfer_bps, r.direction), []).append(r)
    for cell in cells.values():
        vals = [r.delta_usdc for r in cell]
        inv_max_abs_usdc = max(inv_max_abs_usdc, max(vals) - min(vals))
        if max(vals) - min(vals) > 1e-12:
            invariant = False

    summary_payload = {
        'schema': 'PRINT_MONEY_BASE_FORK_V2/1',
        'generated_at_unix': int(time.time()),
        'base_chain_id': BASE_CHAIN_ID,
        'head_block': head,
        'head_timestamp': head_ts,
        'pool': POOL,
        'pool_fee': POOL_FEE,
        'principal_usdc': principal_usdc,
        'lookback_hours': lookback_hours,
        'anchors': [{'block': b, 'timestamp': ts} for b, ts in anchor_blocks],
        'qe_abs_grid_bps': qe_abs_grid,
        'transfer_grid_bps': transfer_grid,
        'horizon_grid_seconds': horizon_grid,
        'rows': len(rows),
        'amplitude_invariant_within_sign': invariant,
        'amplitude_max_abs_delta_usdc': inv_max_abs_usdc,
        'canonical_nav_scope': 'USDC/WETH executor inventory only; Uniswap fee/price impact embedded in QuoterV2; relayer gas excluded',
        'top_20': summary_rows[:20],
    }
    (out_dir / 'base_fork_v2_summary.json').write_text(json.dumps(summary_payload, indent=2), encoding='utf-8')

    best = summary_rows[0]
    report = []
    report.append('# BASE-FORK V2 — causal NAV parameter sweep')
    report.append('')
    report.append(f'- Base head block sampled: `{head}`')
    report.append(f'- Pinned pool: `{POOL}` (WETH/USDC, fee {POOL_FEE/1e4:.2f}%)')
    report.append(f'- Principal: `${principal_usdc:,.2f}`; transfer notional = principal × gradientTransferBps / 10000')
    report.append(f'- Historical lookback: {lookback_hours}h, anchors: {len(anchor_blocks)}')
    report.append('- Causal rule: OPEN quote only at t0; CLOSE and final canonical valuation only at t0+h.')
    report.append('- Uniswap fee and price impact are embedded in QuoterV2 outputs; relayer/gas cost is outside executor USDC/WETH NAV and is not subtracted here.')
    report.append('')
    report.append('## Structural finding')
    report.append('')
    report.append(f'`qePremiumBps` amplitude invariance within a fixed sign is **{invariant}**; max observed difference = `{inv_max_abs_usdc:.12f} USDC`.')
    report.append('This is expected from the current V1 contracts: Base execution size is controlled by `gradientTransferBps × principal`, while `qePremiumBps` only selects direction (`>0` or `<0`).')
    report.append('Therefore V2 does **not** pretend that QE amplitude is an independently optimized Base sizing parameter. A future V3 may deliberately couple amplitude to transfer size if that economic policy is desired.')
    report.append('')
    report.append('## Best observed mechanical cell')
    report.append('')
    report.append(f"- direction: `{best['direction']}`")
    report.append(f"- gradientTransferBps: `{best['transfer_bps']}`")
    report.append(f"- holding horizon: `{best['horizon_seconds']} s`")
    report.append(f"- mean causal NAV delta: `{best['mean_delta_usdc']:.6f} USDC` (`{best['mean_delta_bps']:.3f} bps`)")
    report.append(f"- median: `{best['median_delta_usdc']:.6f} USDC`")
    report.append(f"- win rate: `{best['win_rate']:.1%}` across `{best['n_anchors']}` independent start anchors")
    report.append(f"- observed tail: p05 `{best['p05_delta_bps']:.3f} bps`, p95 `{best['p95_delta_bps']:.3f} bps`")
    report.append('')
    report.append('## Top 10 cells')
    report.append('')
    report.append('| rank | direction | transfer bps | horizon | mean Δ USDC | mean Δ bps | win rate | p05 bps | p95 bps |')
    report.append('|---:|---|---:|---:|---:|---:|---:|---:|---:|')
    for i, s in enumerate(summary_rows[:10], 1):
        report.append(
            f"| {i} | {s['direction']} | {s['transfer_bps']} | {s['horizon_seconds']}s | "
            f"{s['mean_delta_usdc']:.6f} | {s['mean_delta_bps']:.3f} | {s['win_rate']:.1%} | "
            f"{s['p05_delta_bps']:.3f} | {s['p95_delta_bps']:.3f} |"
        )
    report.append('')
    report.append('## Interpretation')
    report.append('')
    report.append('A positive cell is evidence that the observed external market path over that holding horizon more than offset the two-phase round-trip drag for those sampled anchors. It is not evidence that self-created QE produced canonical external wealth. Negative cells are the control expected when outside flow does not compensate fees/price impact.')
    report.append('')
    report.append('The next gate after this archive sweep is walk-forward expansion over more independent days/weeks and a fork execution smoke test of the actual contracts. No live capital is required for either step.')
    (out_dir / 'BASE_FORK_V2_REPORT.md').write_text('\n'.join(report) + '\n', encoding='utf-8')

    print(json.dumps(summary_payload, indent=2))


if __name__ == '__main__':
    main()
