from dataclasses import dataclass
from math import sqrt
@dataclass
class Pool:
    usd:float=500.
    coin:float=500.
    amp:float=1.
    fee:float=.003
    def __post_init__(self):
        assert self.amp>=1
        self.vx=(self.amp-1)*self.coin
        self.vy=(self.amp-1)*self.usd
    def price(self): return (self.usd+self.vy)/(self.coin+self.vx)
    def bound(self,epsilon):return (self.coin+self.vx)*(1/sqrt(1-epsilon)-1)
    def sell(self,n):
        eff=n*(1-self.fee)
        out=(self.usd+self.vy)*eff/(self.coin+self.vx+eff)
        if out>=self.usd:raise ValueError("insufficient real USDC")
        self.usd-=out;self.coin+=n
        return out
    def buy(self,usd):
        eff=usd*(1-self.fee)
        out=(self.coin+self.vx)*eff/(self.usd+self.vy+eff)
        if out>=self.coin:raise ValueError("insufficient real token")
        self.usd+=usd;self.coin-=out
        return out
class Experiment:
    def __init__(self):
        self.pools=[Pool() for _ in range(6)]
        self.vault=7000.
        self.debt=0.
        self.payout=0.
    def cash(self):return self.vault+sum(p.usd for p in self.pools)
    def hardnav(self):return self.cash()-self.debt
    def tvl(self):return sum(p.usd+p.coin*p.price() for p in self.pools)
    def circle(self,mint=25,eps=.02,independent_credit_headroom=0):
        for i,p in enumerate(self.pools):
            allowed=min(mint,p.bound(eps),independent_credit_headroom)
            if allowed<=0:continue
            self.debt+=allowed
            amount=p.sell(allowed)
            self.pools[(i+1)%6].buy(amount)
    def independent_service(self,gross,cost):
        assert gross>=cost>=0
        self.vault+=gross-cost
        profit=gross-cost
        payment=.3*profit
        self.vault-=payment;self.payout+=payment
    def stress(self,loss):
        self.vault-=loss
if __name__=="__main__":
    x=Experiment();x.circle();assert x.hardnav()==10000
    y=Experiment();y.circle(independent_credit_headroom=10000);assert y.hardnav()<10000
    z=Experiment();z.independent_service(150,15);assert z.hardnav()==10094.5
    print(dict(internal_nav=x.hardnav(),unbacked_nav=y.hardnav(),service_nav=z.hardnav(),service_tvl=z.tvl()))
