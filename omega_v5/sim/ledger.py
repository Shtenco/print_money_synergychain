from decimal import Decimal as D

def evaluate(fees=(), costs=(), refunds=(), initial=D("10000")):
    gross=sum(map(D,fees),D(0))
    expense=sum(map(D,costs),D(0))
    liability=sum(map(D,refunds),D(0))
    assert gross>=liability and expense>=0
    net=gross-liability-expense
    payout=max(net,D(0))*D(".30")
    nav=initial+gross-expense-payout-liability
    return {"hardnav":nav,"payout":payout,"net_income":net}

if __name__=="__main__":
    assert evaluate()["hardnav"]==10000
    assert evaluate([5]*30,[D(".5")]*30)["hardnav"]==D("10094.5")
    assert evaluate([100],[],[70])["hardnav"]==D("10021")
    assert evaluate([5]*30,[D(".5")]*30+[400])["hardnav"]==D("9735")
    print("4/4 offline accounting tests passed")
