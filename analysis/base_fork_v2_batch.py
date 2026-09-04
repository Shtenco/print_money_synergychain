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
WETH = Web3.to_checksum_address('0x4200000000000000000000000000000000000006')
USDC = Web3.to_checksum_address('0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913')
QUOTER_V2 = Web3.to_checksum_address('0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a')
POOL = Web3.to_checksum_address('0x6c561B446416E1A00E8E93E221854d6eA4171372')
POOL_FEE = 3000
BPS = 10_000

QUOTER_ABI = [{'inputs':[{'components':[{'internalType':'address','name':'tokenIn','type':'address'},{'internalType':'address','name':'tokenOut','type':'address'},{'internalType':'uint256','name':'amountIn','type':'uint256'},{'internalType':'uint24','name':'fee','type':'uint24'},{'internalType':'uint160','name':'sqrtPriceLimitX96','type':'uint160'}],'internalType':'struct IQuoterV2.QuoteExactInputSingleParams','name':'params','type':'tuple'}],'name':'quoteExactInputSingle','outputs':[{'internalType':'uint256','name':'amountOut','type':'uint256'},{'internalType':'uint160','name':'sqrtPriceX96After','type':'uint160'},{'internalType':'uint32','name':'initializedTicksCrossed','type':'uint32'},{'internalType':'uint256','name':'gasEstimate','type':'uint256'}],'stateMutability':'nonpayable','type':'function'}]
POOL_ABI=[{'inputs':[],'name':'token0','outputs':[{'type':'address'}],'stateMutability':'view','type':'function'},{'inputs':[],'name':'token1','outputs':[{'type':'address'}],'stateMutability':'view','type':'function'},{'inputs':[],'name':'fee','outputs':[{'type':'uint24'}],'stateMutability':'view','type':'function'}]

@dataclass(frozen=True)
class Row:
    anchor_block:int; anchor_ts:int; close_block:int; close_ts:int; horizon_seconds:int; qe_bps:int; transfer_bps:int; principal_usdc:float; transfer_notional_usdc:float; direction:str; nav_before_usdc:float; nav_after_usdc:float; delta_usdc:float; delta_bps:float

def percentile(v:list[float],p:float)->float:
    x=sorted(v)
    if len(x)==1:return x[0]
    q=(len(x)-1)*p; lo,hi=math.floor(q),math.ceil(q)
    return x[lo] if lo==hi else x[lo]*(hi-q)+x[hi]*(q-lo)

class Rpc:
    def __init__(self,url:str):
        self.url=url; self.w3=Web3(Web3.HTTPProvider(url,request_kwargs={'timeout':30})); self.quoter=self.w3.eth.contract(address=QUOTER_V2,abi=QUOTER_ABI); self.pool=self.w3.eth.contract(address=POOL,abi=POOL_ABI); self.s=requests.Session(); self.i=1; self.blocks={}
    def retry(self,fn,tries=6):
        last=None
        for k in range(tries):
            try:return fn()
            except Exception as e:last=e; time.sleep(min(4,.3*(2**k)))
        raise last
    def rpc(self,m,p):
        rid=self.i; self.i+=1
        def go():
            z=self.s.post(self.url,json={'jsonrpc':'2.0','id':rid,'method':m,'params':p},timeout=30); z.raise_for_status(); d=z.json()
            if 'error'in d:raise RuntimeError(d['error'])
            return d['result']
        return self.retry(go)
    def block(self,n:int):
        if n not in self.blocks:
            d=self.rpc('eth_getBlockByNumber',[hex(n),False]); self.blocks[n]={'number':int(d['number'],16),'timestamp':int(d['timestamp'],16)}
        return self.blocks[n]
    def head(self):
        n=int(self.rpc('eth_blockNumber',[]),16); return n,self.block(n)['timestamp']
    def block_at_or_before(self,target,head,head_ts):
        g=max(1,head-max(0,(head_ts-target)//2))
        for _ in range(10):
            d=self.block(g)['timestamp']-target
            if abs(d)<=3:break
            g=max(1,min(head,g-int(d/2)))
        while g>1 and self.block(g)['timestamp']>target:g-=1
        while g<head and self.block(g+1)['timestamp']<=target:g+=1
        return g
    def batch_quotes(self,tin,tout,amounts,block):
        payload=[]; ids=[]
        for a in amounts:
            data=self.quoter.functions.quoteExactInputSingle((tin,tout,a,POOL_FEE,0))._encode_transaction_data(); rid=self.i; self.i+=1; ids.append(rid); payload.append({'jsonrpc':'2.0','id':rid,'method':'eth_call','params':[{'to':QUOTER_V2,'data':data},hex(block)]})
        def go():
            z=self.s.post(self.url,json=payload,timeout=60); z.raise_for_status(); arr=z.json(); by={int(x['id']):x for x in arr}; out=[]
            for rid in ids:
                x=by[rid]
                if 'error'in x:raise RuntimeError(x['error'])
                out.append(int(decode(['uint256','uint160','uint32','uint256'],bytes.fromhex(x['result'][2:]))[0]))
            return out
        return self.retry(go)

def main():
    url=os.getenv('BASE_RPC_URL','https://mainnet.base.org'); principal=float(os.getenv('V2_PRINCIPAL_USDC','10000')); lookback=int(os.getenv('V2_LOOKBACK_HOURS','72')); anchors_n=int(os.getenv('V2_ANCHORS','4')); out=Path(os.getenv('V2_OUT_DIR','results_batch')); out.mkdir(parents=True,exist_ok=True)
    qe=[100,250,500,1000,1500,2000]; transfers=[250,500,1000,2500,5000,10000]; horizons=[300,900,3600,14400,43200,86400]
    r=Rpc(url)
    if int(r.rpc('eth_chainId',[]),16)!=BASE_CHAIN_ID:raise RuntimeError('wrong chain')
    if {Web3.to_checksum_address(r.pool.functions.token0().call()),Web3.to_checksum_address(r.pool.functions.token1().call())}!={WETH,USDC} or int(r.pool.functions.fee().call())!=POOL_FEE:raise RuntimeError('pool mismatch')
    head,head_ts=r.head(); end=head_ts-max(horizons)-30; start=end-lookback*3600; ats=[end] if anchors_n==1 else [int(start+i*(end-start)/(anchors_n-1)) for i in range(anchors_n)]; anchors=[(r.block_at_or_before(ts,head,head_ts),ts) for ts in ats]; anchors=[(b,r.block(b)['timestamp']) for b,_ in anchors]
    p6=int(round(principal*1e6)); notionals=[p6*t//BPS for t in transfers]; rows=[]
    for ai,(ab,ats0) in enumerate(anchors,1):
        print(f'anchor {ai}/{len(anchors)} block={ab}',flush=True); open_weth=r.batch_quotes(USDC,WETH,notionals,ab); neg_before6=r.batch_quotes(WETH,USDC,open_weth,ab)
        for h in horizons:
            cb=r.block_at_or_before(ats0+h,head,head_ts); cts=r.block(cb)['timestamp']; pos_after6=r.batch_quotes(WETH,USDC,open_weth,cb); neg_weth=r.batch_quotes(USDC,WETH,neg_before6,cb); neg_after6=r.batch_quotes(WETH,USDC,neg_weth,cb)
            for j,t in enumerate(transfers):
                for sign,d,before,after in [(1,'positive_qe',notionals[j]/1e6,pos_after6[j]/1e6),(-1,'negative_qe',neg_before6[j]/1e6,neg_after6[j]/1e6)]:
                    delta=after-before; dbps=delta/before*BPS
                    for a in qe:rows.append(Row(ab,ats0,cb,cts,h,a*sign,t,principal,principal*t/BPS,d,before,after,delta,dbps))
            print(f'  horizon={h}s close={cb}',flush=True)
    with (out/'base_fork_v2_grid.csv').open('w',newline='',encoding='utf-8') as f:
        w=csv.DictWriter(f,fieldnames=list(Row.__dataclass_fields__.keys())); w.writeheader(); [w.writerow(x.__dict__) for x in rows]
    uniq={}
    for x in rows:uniq.setdefault((x.direction,x.transfer_bps,x.horizon_seconds,x.anchor_block),x)
    agg={}
    for (d,t,h,a),x in uniq.items():agg.setdefault((d,t,h),[]).append(x)
    s=[]
    for (d,t,h),xs in agg.items():
        ds=[x.delta_usdc for x in xs]; bs=[x.delta_bps for x in xs]; s.append({'direction':d,'transfer_bps':t,'horizon_seconds':h,'n_anchors':len(xs),'mean_delta_usdc':statistics.fmean(ds),'median_delta_usdc':statistics.median(ds),'mean_delta_bps':statistics.fmean(bs),'median_delta_bps':statistics.median(bs),'win_rate':sum(v>0 for v in ds)/len(ds),'p05_delta_bps':percentile(bs,.05),'p95_delta_bps':percentile(bs,.95),'min_delta_bps':min(bs),'max_delta_bps':max(bs)})
    s.sort(key=lambda x:(x['mean_delta_bps'],x['win_rate']),reverse=True)
    cells={}
    for x in rows:cells.setdefault((x.anchor_block,x.horizon_seconds,x.transfer_bps,x.direction),[]).append(x.delta_usdc)
    maxamp=max(max(v)-min(v) for v in cells.values()); inv=maxamp<=1e-12; payload={'schema':'PRINT_MONEY_BASE_FORK_V2_BATCH/1','generated_at_unix':int(time.time()),'base_chain_id':BASE_CHAIN_ID,'head_block':head,'head_timestamp':head_ts,'pool':POOL,'pool_fee':POOL_FEE,'principal_usdc':principal,'lookback_hours':lookback,'anchors':[{'block':b,'timestamp':ts} for b,ts in anchors],'qe_abs_grid_bps':qe,'transfer_grid_bps':transfers,'horizon_grid_seconds':horizons,'rows':len(rows),'amplitude_invariant_within_sign':inv,'amplitude_max_abs_delta_usdc':maxamp,'canonical_nav_scope':'USDC/WETH executor inventory; Uniswap fee + price impact embedded; relayer gas excluded','top_20':s[:20]}; (out/'base_fork_v2_summary.json').write_text(json.dumps(payload,indent=2),encoding='utf-8')
    best=s[0]; lines=['# BASE-FORK V2 BATCH — causal NAV results','',f'- head block: `{head}`',f'- anchors: `{len(anchors)}` over `{lookback}h`',f'- principal: `${principal:,.2f}`',f'- amplitude invariant within sign: **{inv}** (max difference `{maxamp:.12f} USDC`)','','## Best observed cell','',f"- direction: `{best['direction']}`",f"- gradientTransferBps: `{best['transfer_bps']}`",f"- holding horizon: `{best['horizon_seconds']} s`",f"- mean causal NAV delta: `{best['mean_delta_usdc']:.6f} USDC` / `{best['mean_delta_bps']:.3f} bps`",f"- win rate: `{best['win_rate']:.1%}` across `{best['n_anchors']}` anchors",'','| rank | direction | transfer bps | horizon | mean Δ USDC | mean Δ bps | win | p05 | p95 |','|---:|---|---:|---:|---:|---:|---:|---:|---:|']
    for i,x in enumerate(s[:15],1):lines.append(f"| {i} | {x['direction']} | {x['transfer_bps']} | {x['horizon_seconds']}s | {x['mean_delta_usdc']:.6f} | {x['mean_delta_bps']:.3f} | {x['win_rate']:.1%} | {x['p05_delta_bps']:.3f} | {x['p95_delta_bps']:.3f} |")
    lines+=['','Positive cells reflect observed external Base market evolution between OPEN and CLOSE; they do not imply QE itself created external wealth.']; (out/'BASE_FORK_V2_REPORT.md').write_text('\n'.join(lines)+'\n',encoding='utf-8'); print(json.dumps(payload,indent=2))

if __name__=='__main__':main()
