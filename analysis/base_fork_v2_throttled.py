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

import requests
from eth_abi import decode
from web3 import Web3

BASE_CHAIN_ID = 8453
WETH = Web3.to_checksum_address("0x4200000000000000000000000000000000000006")
USDC = Web3.to_checksum_address("0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913")
QUOTER_V2 = Web3.to_checksum_address("0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a")
POOL = Web3.to_checksum_address("0x6c561B446416E1A00E8E93E221854d6eA4171372")
POOL_FEE = 3000
BPS = 10_000

QUOTER_ABI = [{
    "inputs": [{"components": [
        {"internalType": "address", "name": "tokenIn", "type": "address"},
        {"internalType": "address", "name": "tokenOut", "type": "address"},
        {"internalType": "uint256", "name": "amountIn", "type": "uint256"},
        {"internalType": "uint24", "name": "fee", "type": "uint24"},
        {"internalType": "uint160", "name": "sqrtPriceLimitX96", "type": "uint160"},
    ], "internalType": "struct IQuoterV2.QuoteExactInputSingleParams", "name": "params", "type": "tuple"}],
    "name": "quoteExactInputSingle",
    "outputs": [
        {"internalType": "uint256", "name": "amountOut", "type": "uint256"},
        {"internalType": "uint160", "name": "sqrtPriceX96After", "type": "uint160"},
        {"internalType": "uint32", "name": "initializedTicksCrossed", "type": "uint32"},
        {"internalType": "uint256", "name": "gasEstimate", "type": "uint256"},
    ],
    "stateMutability": "nonpayable", "type": "function"
}]

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
    xs = sorted(values)
    if len(xs) == 1:
        return xs[0]
    z = (len(xs) - 1) * p
    lo, hi = math.floor(z), math.ceil(z)
    return xs[lo] if lo == hi else xs[lo] * (hi - z) + xs[hi] * (z - lo)


class ThrottledBaseRPC:
    def __init__(self, url: str, min_delay: float) -> None:
        self.url = url
        self.delay = min_delay
        self.session = requests.Session()
        self.next_id = 1
        self.last_request_at = 0.0
        self.blocks: dict[int, dict[str, int]] = {}
        self.w3 = Web3()
        self.quoter = self.w3.eth.contract(address=QUOTER_V2, abi=QUOTER_ABI)

    def _sleep_gate(self) -> None:
        remaining = self.delay - (time.monotonic() - self.last_request_at)
        if remaining > 0:
            time.sleep(remaining)

    def call(self, method: str, params: list[Any], tries: int = 8) -> Any:
        last: Exception | None = None
        for attempt in range(tries):
            self._sleep_gate()
            rid = self.next_id
            self.next_id += 1
            try:
                response = self.session.post(
                    self.url,
                    json={"jsonrpc": "2.0", "id": rid, "method": method, "params": params},
                    timeout=45,
                )
                self.last_request_at = time.monotonic()
                response.raise_for_status()
                payload = response.json()
                if "error" in payload:
                    raise RuntimeError(payload["error"])
                return payload["result"]
            except Exception as exc:
                last = exc
                backoff = min(15.0, 1.5 * (2 ** attempt))
                print(f"rpc retry method={method} attempt={attempt + 1}: {exc}; sleep={backoff}s", flush=True)
                time.sleep(backoff)
        assert last is not None
        raise last

    def block(self, number: int) -> dict[str, int]:
        if number not in self.blocks:
            raw = self.call("eth_getBlockByNumber", [hex(number), False])
            self.blocks[number] = {
                "number": int(raw["number"], 16),
                "timestamp": int(raw["timestamp"], 16),
            }
        return self.blocks[number]

    def head(self) -> tuple[int, int]:
        n = int(self.call("eth_blockNumber", []), 16)
        return n, self.block(n)["timestamp"]

    def block_at_or_before(self, target_ts: int, head: int, head_ts: int) -> int:
        # Base target block time is ~2s. Start close to target, then converge using timestamps.
        guess = max(1, min(head, head - max(0, (head_ts - target_ts) // 2)))
        for _ in range(8):
            delta = self.block(guess)["timestamp"] - target_ts
            if abs(delta) <= 3:
                break
            guess = max(1, min(head, guess - int(delta / 2)))
        while guess > 1 and self.block(guess)["timestamp"] > target_ts:
            guess -= 1
        while guess < head and self.block(guess + 1)["timestamp"] <= target_ts:
            guess += 1
        return guess

    def quote(self, token_in: str, token_out: str, amount_in: int, block: int) -> int:
        data = self.quoter.functions.quoteExactInputSingle(
            (token_in, token_out, amount_in, POOL_FEE, 0)
        )._encode_transaction_data()
        raw = self.call("eth_call", [{"to": QUOTER_V2, "data": data}, hex(block)])
        decoded = decode(["uint256", "uint160", "uint32", "uint256"], bytes.fromhex(raw[2:]))
        out = int(decoded[0])
        if out <= 0:
            raise RuntimeError(f"zero quote block={block} amount={amount_in}")
        return out


def main() -> None:
    rpc_url = os.environ.get("BASE_RPC_URL", "https://mainnet.base.org")
    principal = float(os.environ.get("V2_PRINCIPAL_USDC", "10000"))
    lookback_hours = int(os.environ.get("V2_LOOKBACK_HOURS", "72"))
    anchors_n = int(os.environ.get("V2_ANCHORS", "2"))
    rpc_delay = float(os.environ.get("V2_RPC_DELAY", "0.85"))
    out_dir = Path(os.environ.get("V2_OUT_DIR", "results_throttled"))
    out_dir.mkdir(parents=True, exist_ok=True)

    qe_abs_grid = [100, 250, 500, 1000, 1500, 2000]
    transfer_grid = [250, 500, 1000, 2500, 5000, 10000]
    horizon_grid = [300, 900, 3600, 14_400, 43_200, 86_400]

    rpc = ThrottledBaseRPC(rpc_url, rpc_delay)
    if int(rpc.call("eth_chainId", []), 16) != BASE_CHAIN_ID:
        raise RuntimeError("wrong chain id")

    # Identity checks are direct eth_call so the run fails if the pinned venue changes.
    def view_sig(selector: str) -> str:
        return "0x" + Web3.keccak(text=selector)[:4].hex()

    token0_raw = rpc.call("eth_call", [{"to": POOL, "data": view_sig("token0()")}, "latest"])
    token1_raw = rpc.call("eth_call", [{"to": POOL, "data": view_sig("token1()")}, "latest"])
    fee_raw = rpc.call("eth_call", [{"to": POOL, "data": view_sig("fee()")}, "latest"])
    token0 = Web3.to_checksum_address("0x" + token0_raw[-40:])
    token1 = Web3.to_checksum_address("0x" + token1_raw[-40:])
    fee = int(fee_raw, 16)
    if {token0, token1} != {WETH, USDC} or fee != POOL_FEE:
        raise RuntimeError("pinned pool identity mismatch")

    head, head_ts = rpc.head()
    usable_end = head_ts - max(horizon_grid) - 60
    usable_start = usable_end - lookback_hours * 3600
    if anchors_n == 1:
        anchor_targets = [usable_end]
    else:
        anchor_targets = [
            int(usable_start + i * (usable_end - usable_start) / (anchors_n - 1))
            for i in range(anchors_n)
        ]
    anchors = []
    for target in anchor_targets:
        b = rpc.block_at_or_before(target, head, head_ts)
        anchors.append((b, rpc.block(b)["timestamp"]))

    p6 = int(round(principal * 1_000_000))
    notionals = [p6 * t // BPS for t in transfer_grid]
    rows: list[Row] = []

    for ai, (anchor_block, anchor_ts) in enumerate(anchors, 1):
        print(f"ANCHOR {ai}/{len(anchors)} block={anchor_block} ts={anchor_ts}", flush=True)

        # OPEN is computed once per transfer size and then held fixed for every future horizon.
        positive_open_weth: list[int] = []
        negative_open_usdc: list[int] = []
        for transfer_bps, notional in zip(transfer_grid, notionals):
            w = rpc.quote(USDC, WETH, notional, anchor_block)
            positive_open_weth.append(w)
            neg_u = rpc.quote(WETH, USDC, w, anchor_block)
            negative_open_usdc.append(neg_u)
            print(f"  open transfer={transfer_bps}bps complete", flush=True)

        for horizon in horizon_grid:
            close_block = rpc.block_at_or_before(anchor_ts + horizon, head, head_ts)
            close_ts = rpc.block(close_block)["timestamp"]
            print(f"  H={horizon}s close_block={close_block}", flush=True)

            for j, transfer_bps in enumerate(transfer_grid):
                # Positive QE: external USDC -> WETH at t0, inverse WETH -> USDC at t1.
                pos_before = notionals[j] / 1e6
                pos_after = rpc.quote(WETH, USDC, positive_open_weth[j], close_block) / 1e6

                # Negative QE follows the current adapter exactly.
                neg_before = negative_open_usdc[j] / 1e6
                neg_close_weth = rpc.quote(USDC, WETH, negative_open_usdc[j], close_block)
                neg_after = rpc.quote(WETH, USDC, neg_close_weth, close_block) / 1e6

                for sign, direction, before, after in (
                    (1, "positive_qe", pos_before, pos_after),
                    (-1, "negative_qe", neg_before, neg_after),
                ):
                    delta = after - before
                    delta_bps = delta / before * BPS
                    for amp in qe_abs_grid:
                        rows.append(Row(
                            anchor_block, anchor_ts, close_block, close_ts, horizon,
                            amp * sign, transfer_bps, principal,
                            principal * transfer_bps / BPS, direction,
                            before, after, delta, delta_bps,
                        ))

    grid_path = out_dir / "base_fork_v2_grid.csv"
    with grid_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(Row.__dataclass_fields__.keys()))
        writer.writeheader()
        for row in rows:
            writer.writerow(row.__dict__)

    # Collapse the intentionally duplicated amplitude dimension for economic ranking.
    unique: dict[tuple[str, int, int, int], Row] = {}
    for row in rows:
        unique.setdefault((row.direction, row.transfer_bps, row.horizon_seconds, row.anchor_block), row)
    grouped: dict[tuple[str, int, int], list[Row]] = {}
    for (direction, transfer_bps, horizon, _), row in unique.items():
        grouped.setdefault((direction, transfer_bps, horizon), []).append(row)

    summary: list[dict[str, Any]] = []
    for (direction, transfer_bps, horizon), xs in grouped.items():
        ds = [x.delta_usdc for x in xs]
        bs = [x.delta_bps for x in xs]
        summary.append({
            "direction": direction,
            "transfer_bps": transfer_bps,
            "horizon_seconds": horizon,
            "n_anchors": len(xs),
            "mean_delta_usdc": statistics.fmean(ds),
            "median_delta_usdc": statistics.median(ds),
            "mean_delta_bps": statistics.fmean(bs),
            "median_delta_bps": statistics.median(bs),
            "win_rate": sum(v > 0 for v in ds) / len(ds),
            "p05_delta_bps": percentile(bs, 0.05),
            "p95_delta_bps": percentile(bs, 0.95),
            "min_delta_bps": min(bs),
            "max_delta_bps": max(bs),
        })
    summary.sort(key=lambda x: (x["mean_delta_bps"], x["win_rate"]), reverse=True)

    amp_cells: dict[tuple[int, int, int, str], list[float]] = {}
    for row in rows:
        amp_cells.setdefault(
            (row.anchor_block, row.horizon_seconds, row.transfer_bps, row.direction), []
        ).append(row.delta_usdc)
    max_amp_diff = max(max(v) - min(v) for v in amp_cells.values())
    amplitude_invariant = max_amp_diff <= 1e-12

    payload = {
        "schema": "PRINT_MONEY_BASE_FORK_V2_THROTTLED/1",
        "generated_at_unix": int(time.time()),
        "base_chain_id": BASE_CHAIN_ID,
        "rpc": "official Base public RPC (URL intentionally not persisted as a secret)",
        "head_block": head,
        "head_timestamp": head_ts,
        "pool": POOL,
        "pool_fee": POOL_FEE,
        "principal_usdc": principal,
        "lookback_hours": lookback_hours,
        "anchors": [{"block": b, "timestamp": ts} for b, ts in anchors],
        "qe_abs_grid_bps": qe_abs_grid,
        "transfer_grid_bps": transfer_grid,
        "horizon_grid_seconds": horizon_grid,
        "rows": len(rows),
        "amplitude_invariant_within_sign": amplitude_invariant,
        "amplitude_max_abs_delta_usdc": max_amp_diff,
        "canonical_nav_scope": "USDC/WETH executor inventory; Uniswap fee and price impact embedded in QuoterV2; relayer gas excluded",
        "top_20": summary[:20],
    }
    (out_dir / "base_fork_v2_summary.json").write_text(json.dumps(payload, indent=2), encoding="utf-8")

    best = summary[0]
    lines = [
        "# BASE-FORK V2 — throttled real-state causal NAV results",
        "",
        f"- Base head block: `{head}`",
        f"- Historical anchors: `{len(anchors)}` over `{lookback_hours}h`",
        f"- Principal: `${principal:,.2f}`",
        f"- QE amplitude invariant within sign: **{amplitude_invariant}**; max difference `{max_amp_diff:.12f} USDC`",
        "",
        "## Best observed mechanical cell",
        "",
        f"- direction: `{best['direction']}`",
        f"- gradientTransferBps: `{best['transfer_bps']}`",
        f"- holding horizon: `{best['horizon_seconds']} s`",
        f"- mean causal NAV delta: `{best['mean_delta_usdc']:.6f} USDC` (`{best['mean_delta_bps']:.3f} bps`)",
        f"- median causal NAV delta: `{best['median_delta_usdc']:.6f} USDC`",
        f"- win rate: `{best['win_rate']:.1%}` across `{best['n_anchors']}` anchors",
        f"- p05/p95: `{best['p05_delta_bps']:.3f}` / `{best['p95_delta_bps']:.3f}` bps",
        "",
        "| rank | direction | transfer bps | horizon | mean Δ USDC | mean Δ bps | win | p05 | p95 |",
        "|---:|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for i, x in enumerate(summary[:15], 1):
        lines.append(
            f"| {i} | {x['direction']} | {x['transfer_bps']} | {x['horizon_seconds']}s | "
            f"{x['mean_delta_usdc']:.6f} | {x['mean_delta_bps']:.3f} | {x['win_rate']:.1%} | "
            f"{x['p05_delta_bps']:.3f} | {x['p95_delta_bps']:.3f} |"
        )
    lines += [
        "",
        "A positive historical cell means external Base market evolution between OPEN and CLOSE offset the round-trip drag for those sampled anchors. It does not mean QE itself created external wealth.",
        "",
        "This is a pilot screen, not sufficient evidence of persistent alpha. The next gate is a much larger walk-forward sample plus explicit relayer/gas accounting.",
    ]
    (out_dir / "BASE_FORK_V2_REPORT.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(json.dumps(payload, indent=2), flush=True)


if __name__ == "__main__":
    main()
