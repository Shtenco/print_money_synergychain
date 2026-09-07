// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

interface VmStochastic {
    function envOr(string calldata key, string calldata defaultValue) external returns (string memory value);
    function createSelectFork(string calldata urlOrAlias) external returns (uint256 forkId);
}
interface IChainlinkStochastic {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice 10k-cycle economic firewall using real latest-mainnet basefee + Chainlink ETH/USD.
/// @dev Mirrors a fee-paying external CPMM trade followed by a fee-exempt exact AICB reset.
contract StochasticEconomicFirewallTest {
    VmStochastic constant vm = VmStochastic(address(uint160(uint256(keccak256("hevm cheat code")))));
    address constant ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    uint256 constant BPS = 10_000;
    uint256 constant EXTERNAL_FEE_BPS = 30;
    uint256 constant REINVEST_BPS = 5_132;
    uint256 constant MEV_BPS = 5;
    uint256 constant CYCLES = 10_000;
    uint256 constant EPOCH = 100;
    uint256 constant STRESS_SELL_COVERAGE = 1_000;
    uint256 constant RESET_GAS = 170_000;
    uint256 constant PRIORITY_FEE_WEI = 100_000_000; // 0.1 gwei

    event log_named_uint(string key, uint256 val);
    event log_named_int(string key, int256 val);

    struct Result {
        uint256 hardFinal;
        uint256 reserveFinal;
        uint256 lpFinal;
        uint256 grossProfit;
        uint256 reinvested;
        uint256 gasBaseOnly;
        uint256 gasWithTip;
        uint256 mevHaircut;
        int256 netBaseOnly;
        int256 netWithTip;
        bool solvent;
    }

    struct SimState {
        uint256 l0;
        uint256 l1;
        uint256 reserve;
        uint256 epochStartReserve;
        uint256 reinvested;
        bool solvent;
    }

    function testTenThousandRandom005With5132SolvencyWaterfall() external {
        _fork();
        uint256 ethUsd8 = _ethUsd8();
        Result memory r = _simulate(keccak256("SYNERGY-AICB-V2-SEED-42"), 50_000, true, ethUsd8);
        require(r.solvent, "AICB reserve insolvency");
        require(r.netBaseOnly < 0, "$0.05 unexpectedly passes basefee-only firewall");
        require(r.netWithTip < r.netBaseOnly, "priority fee accounting");
        _logs(r, ethUsd8);
    }

    function testTenThousandRandom005OptimisticNoReinvestStillFails() external {
        _fork();
        uint256 ethUsd8 = _ethUsd8();
        Result memory r = _simulate(keccak256("SYNERGY-AICB-V2-UPPER-BOUND"), 50_000, false, ethUsd8);
        require(r.solvent, "upper-bound reserve insolvency");
        require(r.netBaseOnly < 0, "optimistic $0.05 upper bound unexpectedly passes");
        _logs(r, ethUsd8);
    }

    function _simulate(bytes32 seed, uint256 trade, bool reinvest, uint256 ethUsd8)
        internal view returns (Result memory r)
    {
        SimState memory s = SimState({
            l0: 50_000,
            l1: 50_000,
            reserve: 504_160,
            epochStartReserve: 504_160,
            reinvested: 0,
            solvent: true
        });
        uint256 hardStart = 604_160;

        for (uint256 i; i < CYCLES; ++i) {
            if (!_advance(s, seed, i, trade)) {
                s.solvent = false;
                break;
            }
            if (reinvest && (i + 1) % EPOCH == 0) _reinvest(s, trade);
        }

        r.solvent = s.solvent;
        r.reserveFinal = s.reserve;
        r.lpFinal = s.l0 + s.l1;
        r.hardFinal = s.reserve + r.lpFinal;
        r.grossProfit = r.hardFinal > hardStart ? r.hardFinal - hardStart : 0;
        r.reinvested = s.reinvested;
        r.mevHaircut = CYCLES * trade * MEV_BPS / BPS;
        r.gasBaseOnly = _gasMicroUsd(CYCLES * RESET_GAS, block.basefee, ethUsd8);
        r.gasWithTip = _gasMicroUsd(CYCLES * RESET_GAS, block.basefee + PRIORITY_FEE_WEI, ethUsd8);
        r.netBaseOnly = int256(r.hardFinal) - int256(hardStart) - int256(r.gasBaseOnly) - int256(r.mevHaircut);
        r.netWithTip = int256(r.hardFinal) - int256(hardStart) - int256(r.gasWithTip) - int256(r.mevHaircut);
    }

    function _advance(SimState memory s, bytes32 seed, uint256 i, uint256 trade) internal pure returns (bool) {
        uint256 rnd = uint256(keccak256(abi.encode(seed, i)));
        bool poolOne = (rnd & 1) != 0;
        bool buy = (rnd & 2) != 0;
        uint256 l = poolOne ? s.l1 : s.l0;
        (uint256 nextL, uint256 reserveDelta, bool isSpend) = _tradeAndReset(l, trade, buy);
        if (isSpend) {
            if (s.reserve < reserveDelta) return false;
            s.reserve -= reserveDelta;
        } else {
            s.reserve += reserveDelta;
        }
        if (poolOne) s.l1 = nextL; else s.l0 = nextL;
        return true;
    }

    function _reinvest(SimState memory s, uint256 trade) internal pure {
        uint256 c0 = _sellResetCost(s.l0, trade);
        uint256 c1 = _sellResetCost(s.l1, trade);
        uint256 floor = STRESS_SELL_COVERAGE * (c0 > c1 ? c0 : c1);
        uint256 epochProfit = s.reserve > s.epochStartReserve ? s.reserve - s.epochStartReserve : 0;
        uint256 requested = epochProfit * REINVEST_BPS / BPS;
        uint256 available = s.reserve > floor ? s.reserve - floor : 0;
        uint256 amount = requested < available ? requested : available;
        uint256 per = amount / 2;
        uint256 actual = per * 2;
        if (actual != 0) {
            s.reserve -= actual;
            s.l0 += per;
            s.l1 += per;
            s.reinvested += actual;
        }
        s.epochStartReserve = s.reserve;
    }

    function _tradeAndReset(uint256 l, uint256 trade, bool buy)
        internal pure returns (uint256 nextL, uint256 reserveDelta, bool isSpend)
    {
        uint256 out = _amountOut(trade, l, l);
        if (buy) {
            uint256 x = l - out;
            uint256 y = l + trade;
            nextL = _sqrt(x * y);
            reserveDelta = y - nextL;
        } else {
            uint256 x = l + trade;
            uint256 y = l - out;
            nextL = _sqrt(x * y);
            reserveDelta = nextL - y;
            isSpend = true;
        }
    }

    function _sellResetCost(uint256 l, uint256 trade) internal pure returns (uint256) {
        (, uint256 d,) = _tradeAndReset(l, trade, false);
        return d;
    }

    function _amountOut(uint256 amountIn, uint256 rin, uint256 rout) internal pure returns (uint256) {
        uint256 afterFee = amountIn * (BPS - EXTERNAL_FEE_BPS);
        return rout * afterFee / (rin * BPS + afterFee);
    }

    function _gasMicroUsd(uint256 gasUnits, uint256 gasPriceWei, uint256 ethUsd8) internal pure returns (uint256) {
        return gasUnits * gasPriceWei * ethUsd8 / 1e20;
    }

    function _sqrt(uint256 a) internal pure returns (uint256 z) {
        if (a == 0) return 0;
        z = a;
        uint256 x = a / 2 + 1;
        while (x < z) { z = x; x = (a / x + x) / 2; }
    }

    function _ethUsd8() internal view returns (uint256) {
        (, int256 px,, uint256 updatedAt,) = IChainlinkStochastic(ETH_USD).latestRoundData();
        require(px > 0 && updatedAt > 0, "ETHUSD");
        return uint256(px);
    }

    function _fork() internal {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", "https://ethereum-rpc.publicnode.com");
        vm.createSelectFork(rpc);
    }

    function _logs(Result memory r, uint256 ethUsd8) internal {
        emit log_named_uint("stochastic fork block", block.number);
        emit log_named_uint("basefee wei", block.basefee);
        emit log_named_uint("ETH/USD 8 decimals", ethUsd8);
        emit log_named_uint("hard final microUSDT", r.hardFinal);
        emit log_named_uint("AICB reserve final microUSDT", r.reserveFinal);
        emit log_named_uint("LP hard final microUSDT", r.lpFinal);
        emit log_named_uint("gross hard profit microUSDT", r.grossProfit);
        emit log_named_uint("explicit reinvest microUSDT", r.reinvested);
        emit log_named_uint("gas base-only microUSD", r.gasBaseOnly);
        emit log_named_uint("gas +0.1gwei tip microUSD", r.gasWithTip);
        emit log_named_uint("MEV 5bps microUSD", r.mevHaircut);
        emit log_named_int("NET base-only microUSD", r.netBaseOnly);
        emit log_named_int("NET +0.1gwei tip microUSD", r.netWithTip);
    }
}
