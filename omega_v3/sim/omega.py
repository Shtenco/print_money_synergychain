from dataclasses import dataclass
import json
U=10**6
@dataclass
class Ledger:
    treasury:int=7000*U
    lp:int=3000*U
    payout:int=0
    contributions:int=10000*U
    def nav(self):return self.treasury+self.lp
    def profit(self):return self.nav()+self.payout-self.contributions
    def own_buy(self,usdc):
        assert self.treasury>=usdc>=0
        self.treasury-=usdc;self.lp+=usdc
    def fee(self,usdc):
        assert usdc>=0
        self.treasury+=usdc
    def expense(self,usdc):
        assert self.treasury>=usdc>=0
        self.treasury-=usdc
    def shock(self,usdc):
        assert self.lp>=usdc>=0
        self.lp-=usdc
    def distribute(self):
        if self.profit()>0:
            x=self.profit()*30//100
            self.treasury-=x;self.payout+=x
    def report(self):
        return dict(hardnav=self.nav()/U,operator_payout=self.payout/U,consolidated_profit=self.profit()/U)
def simulate(case):
    l=Ledger()
    for _ in range(6):l.own_buy(U//2)
    if case in ('services','stress'):
        for _ in range(30):
            l.fee(5*U);l.expense(U//2)
    if case=='stress':l.shock(400*U)
    l.distribute()
    return l.report()
if __name__=='__main__':
    print(json.dumps({s:simulate(s) for s in ['internal','services','stress']},indent=2))
