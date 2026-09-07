// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MintableToken} from "../src/MintableToken.sol";
import {Fixed5050CPMM} from "../src/Fixed5050CPMM.sol";
import {AICBController} from "../src/AICBController.sol";
import {Trader} from "../src/Trader.sol";

contract AICBSystemTest {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant TRADE = 0.05 ether;
    uint256 internal constant INITIAL_SIDE = 0.05 ether;
    uint256 internal constant INITIAL_CB = 0.10 ether;
    uint256 internal constant EXTERNAL_ARB_PROFIT = 0.40416 ether;

    MintableToken usdt;
    MintableToken syna;
    MintableToken synr;
    Fixed5050CPMM poolA;
    Fixed5050CPMM poolR;
    Fixed5050CPMM poolAR;
    AICBController cb;
    Trader buyer;
    Trader seller;

    function setUp() public {
        usdt = new MintableToken("Mock USDT 18", "USDT18");
        syna = new MintableToken("Synergy A", "SYNA");
        synr = new MintableToken("Synergy R", "SYNR");

        poolA = new Fixed5050CPMM(syna, usdt);
        poolR = new Fixed5050CPMM(synr, usdt);
        poolAR = new Fixed5050CPMM(syna, synr);
        cb = new AICBController(usdt, syna, synr, poolA, poolR, poolAR);
        buyer = new Trader();
        seller = new Trader();

        // CB may mint/burn only endogenous tokens. It is NEVER a USDT minter.
        syna.setMinter(address(cb), true);
        synr.setMinter(address(cb), true);
        require(!usdt.minter(address(cb)), "CB MUST NOT MINT USDT");

        // Seed three 50/50 pools with $0.10 nominal TVL each at P=1.
        _seed(poolA, syna, usdt, INITIAL_SIDE);
        _seed(poolR, synr, usdt, INITIAL_SIDE);
        _seed(poolAR, syna, synr, INITIAL_SIDE);

        // Initial genuine AICB hard reserve.
        usdt.mint(address(cb), INITIAL_CB);

        // Given external arb profit 0.39447 + 0.00969 = 0.40416, reinvest 100% into hard LP.
        usdt.mint(address(this), EXTERNAL_ARB_PROFIT);
        usdt.approve(address(cb), EXTERNAL_ARB_PROFIT);
        cb.bootstrapExternalArbProfit(EXTERNAL_ARB_PROFIT);

        require(poolA.reserveQuote() == 0.25208 ether, "A LP bootstrap");
        require(poolR.reserveQuote() == 0.25208 ether, "R LP bootstrap");
        require(cb.aicbReserveUsdt() == INITIAL_CB, "CB reserve untouched");
        require(cb.hardUsdt() == 0.60416 ether, "hard bootstrap accounting");

        // Pre-fund truly external order flow for up to 10,000 cycles.
        usdt.mint(address(buyer), 1_100 ether);
        syna.mint(address(seller), 1_100 ether);
        synr.mint(address(seller), 1_100 ether);
        synr.mint(address(buyer), 600 ether); // internal SYNA/SYNR buys

        buyer.approveMax(usdt, address(poolA));
        buyer.approveMax(usdt, address(poolR));
        buyer.approveMax(synr, address(poolAR));
        seller.approveMax(syna, address(poolA));
        seller.approveMax(synr, address(poolR));
        seller.approveMax(syna, address(poolAR));

        // Freeze mock USDT issuance from the test deployer after funding external actors.
        // No participant in the tested system can mint additional hard quote during cycles.
        usdt.setMinter(address(this), false);
    }

    function testBootstrapAccountingFirewall() public view {
        require(!usdt.minter(address(cb)), "CB can mint hard quote");
        require(cb.totalExternalArbReinvested() == EXTERNAL_ARB_PROFIT, "arb reinvest mismatch");
        require(cb.hardLpUsdt() == 0.50416 ether, "hard LP mismatch");
        require(cb.aicbReserveUsdt() == 0.10 ether, "CB mismatch");
        require(cb.hardUsdt() == 0.60416 ether, "total hard mismatch");
    }

    /// @notice Full ERC20 + three-pool integration test. 100 cycles is intentionally on-chain heavy.
    function testIntegration100Cycles() public {
        uint256 hard0 = cb.hardUsdt();
        for (uint256 i = 0; i < 100; ++i) {
            cb.beginEpoch();
            _hardCycle(poolA);
            _hardCycle(poolR);
            _internalCycle();
            cb.settleEpoch();
            _assertParity(poolA, 20);
            _assertParity(poolR, 20);
            _assertParity(poolAR, 20);
        }

        uint256 hard = cb.hardUsdt();
        uint256 lp = cb.hardLpUsdt();
        uint256 reserve = cb.aicbReserveUsdt();

        require(hard > hard0, "hard value did not grow");
        require(lp > 0.50416 ether, "LP did not grow");
        require(reserve > INITIAL_CB, "CB reserve did not grow");

        // Allow < 0.05% integration deviation from closed-form due integer swap/sqrt rounding.
        _assertApprox(hard, 1.7282501949453322 ether, 5e14);
        _assertApprox(lp, 1.0810430880459443 ether, 5e14);
        _assertApprox(reserve, 0.6472071068993878 ether, 5e14);
    }

    /// @notice Cheap EVM state-machine verification of the exact same recurrence for 100 cycles.
    function testEvmMath100Cycles() public pure {
        (uint256 lp, uint256 reserve, uint256 hard, uint256 buyDev) = _model(100);
        _assertApproxPure(lp, 1.0810430880459443 ether, 1000);
        _assertApproxPure(reserve, 0.6472071068993878 ether, 1000);
        _assertApproxPure(hard, 1.7282501949453322 ether, 1000);
        require(buyDev < 0.194 ether, "unexpected excursion");
    }

    function testEvmMath1000Cycles() public pure {
        (uint256 lp, uint256 reserve, uint256 hard, uint256 buyDev) = _model(1_000);
        _assertApproxPure(lp, 3.161545643765114 ether, 2000);
        _assertApproxPure(reserve, 2.620684589604167 ether, 2000);
        _assertApproxPure(hard, 5.7822302333692805 ether, 4000);
        require(buyDev < 0.065 ether, "buy excursion > 6.5%");
    }

    function testEvmMath10000Cycles() public pure {
        (uint256 lp, uint256 reserve, uint256 hard, uint256 buyDev) = _model(10_000);
        _assertApproxPure(lp, 10.049852545009934 ether, 20_000);
        _assertApproxPure(reserve, 9.154643668961118 ether, 20_000);
        _assertApproxPure(hard, 19.20449621397105 ether, 40_000);
        require(buyDev <= 0.02 ether, "final BUY excursion exceeds 2%");
    }

    function testSellFirstSolvencyAtBootstrap() public {
        // Worst ordering check: SELL happens before the compensating BUY.
        uint256 start = cb.aicbReserveUsdt();
        seller.sell(poolA, TRADE);
        seller.sell(poolR, TRADE);
        cb.resetHardPool(poolA);
        cb.resetHardPool(poolR);
        uint256 afterReset = cb.aicbReserveUsdt();
        require(afterReset < start, "sell-first should consume reserve");
        require(afterReset > 0, "CB insolvent");
        _assertParity(poolA, 20);
        _assertParity(poolR, 20);
    }

    function _hardCycle(Fixed5050CPMM pool) internal {
        buyer.buy(pool, TRADE);
        cb.resetHardPool(pool);
        seller.sell(pool, TRADE);
        cb.resetHardPool(pool);
    }

    function _internalCycle() internal {
        buyer.buy(poolAR, TRADE);
        cb.resetInternalPool();
        seller.sell(poolAR, TRADE);
        cb.resetInternalPool();
    }

    function _seed(Fixed5050CPMM pool, MintableToken base, MintableToken quote, uint256 side) internal {
        base.mint(address(this), side);
        quote.mint(address(this), side);
        base.approve(address(pool), side);
        quote.approve(address(pool), side);
        pool.addLiquidity(side, side);
    }

    function _assertParity(Fixed5050CPMM pool, uint256 toleranceWei) internal view {
        uint256 p = pool.priceWad();
        uint256 d = p > WAD ? p - WAD : WAD - p;
        require(d <= toleranceWei, "pool not reset to parity");
    }

    function _assertApprox(uint256 got, uint256 expected, uint256 tolerance) internal pure {
        uint256 d = got > expected ? got - expected : expected - got;
        require(d <= tolerance, "integration value outside tolerance");
    }

    function _assertApproxPure(uint256 got, uint256 expected, uint256 tolerance) internal pure {
        uint256 d = got > expected ? got - expected : expected - got;
        require(d <= tolerance, "math value outside tolerance");
    }

    /// @dev Closed-form integer recurrence executed by the EVM test contract itself.
    function _model(uint256 cycles)
        internal
        pure
        returns (uint256 hardLp, uint256 reserve, uint256 hard, uint256 finalBuyDeviation)
    {
        uint256 L = 0.25208 ether; // quote reserve PER hard pool
        reserve = INITIAL_CB;
        for (uint256 i = 0; i < cycles; ++i) {
            uint256 perPoolProfit = (TRADE * TRADE) / (L + TRADE);
            uint256 totalProfit = 2 * perPoolProfit;
            uint256 reinvest = (totalProfit * 5_132) / 10_000;
            uint256 perPoolAdd = reinvest / 2;
            L += perPoolAdd;
            // Dust from odd reinvest wei stays in the controller.
            reserve += totalProfit - (2 * perPoolAdd);
        }
        hardLp = 2 * L;
        hard = hardLp + reserve;
        uint256 pBuy = (((L + TRADE) * (L + TRADE)) * WAD) / (L * L);
        finalBuyDeviation = pBuy - WAD;
    }
}
