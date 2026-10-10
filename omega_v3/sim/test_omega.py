import unittest
from omega import Ledger,simulate,U
class OmegaTest(unittest.TestCase):
    def test_internal_zero(self):self.assertEqual(simulate('internal')['consolidated_profit'],0)
    def test_fees(self):self.assertEqual(simulate('services')['consolidated_profit'],135)
    def test_stress(self):self.assertEqual(simulate('stress')['consolidated_profit'],-265)
    def test_internal_conservation(self):
        l=Ledger()
        for _ in range(6):l.own_buy(U//2)
        self.assertEqual(l.nav(),10_000*U)
if __name__=='__main__':unittest.main()
