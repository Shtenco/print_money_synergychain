// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

interface VmV22 {
    function envOr(string calldata key, string calldata defaultValue) external returns (string memory value);
    function createSelectFork(string calldata urlOrAlias) external returns (uint256 forkId);
}
interface IChainlinkV22 {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}
interface IAaveV22 {
    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint128);
}
interface IBaseGasPriceOracleV22 {
    function getL1Fee(bytes memory data) external view returns (uint256);
    function getOperatorFee(uint256 gasUsed) external view returns (uint256);
}

contract DistributionFirewallV22Test {
    VmV22 constant vm = VmV22(address(uint160(uint256(keccak256("hevm cheat code")))));
    address constant ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant BASE_GPO = 0x420000000000000000000000000000000000000F;

    uint256 constant BPS = 10_000;
    uint256 constant EXTERNAL_FEE_BPS = 30;
    uint256 constant REINVEST_BPS = 5_132;
    uint256 constant CYCLES = 10_000;
    uint256 constant EPOCH = 100;
    uint256 constant STRESS_SELL_COVERAGE = 1_000;
    uint256 constant SEEDS = 64;
    uint256 constant TRADE = 50_000;
    uint256 constant HARD_START = 604_160;
    uint256 constant RESERVE_START = 504_160;
    uint256 constant LP_SIDE_START = 50_000;
    uint256 constant V3_ROUNDTRIP_BPS = 2;
    uint256 constant BATCH_OVERHEAD_GAS = 50_000;
    uint256 constant SYSTEM_EVENT_GAS = 120_000;
    uint256 constant ALLIN_EVENT_GAS = 250_000;

    event log_named_uint(string key, uint256 val);

    struct SimState { uint256 l0; uint256 l1; uint256 reserve; uint256 epochStartReserve; }
    struct Distribution { uint256 p5Gross; uint256 medianGross; uint256 p95Gross; uint256 insolvencies; }
    struct Core { uint256 p5Gross; uint256 premiumBps; uint256 ethUsd8; }
    struct Frontier {
        uint256 bestSystem; uint256 worstSystem; uint256 bestAllIn;
        uint256 worstAllIn; uint256 defaultSystem; uint256 stressSystem;
    }
    struct BaseFees {
        uint256 basefee;
        uint256[4] l1PerBatch;
        uint256[4] opSystemPerBatch;
        uint256[4] opAllInPerBatch;
    }

    function testV22Bias5000() external { _runBias(5_000, true); }
    function testV22Bias5500() external { _runBias(5_500, true); }
    function testV22Bias6000() external { _runBias(6_000, false); }
    function testV22Bias7000() external { _runBias(7_000, false); }

    function _runBias(uint256 sellBps, bool requireRobustBase) internal {
        (uint256 ethBasefee, uint256 ethUsd8, uint256 premiumBps) = _ethereumMetrics();
        BaseFees memory bf = _baseMetrics();
        emit log_named_uint("V22 seeds", SEEDS);
        emit log_named_uint("V22 cycles per seed", CYCLES);
        emit log_named_uint("SELL bias bps", sellBps);
        emit log_named_uint("ETH basefee wei", ethBasefee);
        emit log_named_uint("Base basefee wei", bf.basefee);
        emit log_named_uint("ETH/USD 8 decimals", ethUsd8);
        emit log_named_uint("Aave flash premium bps", premiumBps);

        Distribution memory d = _distribution(sellBps);
        _logDistribution(sellBps, d);
        uint256 insolvencyCutoff = (SEEDS * 5 + 99) / 100;
        if (d.insolvencies >= insolvencyCutoff || d.p5Gross == 0) {
            emit log_named_uint(_label("P5 solvency FAIL SELL bps ", sellBps), 1);
            if (requireRobustBase) revert("V2.2 strict bias failed P5 solvency");
            return;
        }

        Core memory c = Core(d.p5Gross, premiumBps, ethUsd8);
        Frontier memory ethF = _ethFrontier(c, ethBasefee);
        Frontier memory baseF = _baseFrontier(c, bf);
        _logFrontier("ETH", sellBps, ethF);
        _logFrontier("BASE", sellBps, baseF);
        emit log_named_uint(_label("BASE robust all-grid system PASS SELL bps ", sellBps), baseF.worstSystem != 0 ? 1 : 0);
        if (requireRobustBase) {
            require(baseF.worstSystem != 0, "V2.2 Base P5 fails some system grid cells");
            require(baseF.defaultSystem != 0, "V2.2 Base default P5 not positive at any scale");
        }
    }

    function _distribution(uint256 sellBps) internal pure returns (Distribution memory d) {
        uint256[64] memory gross;
        uint256 insolvent;
        for (uint256 s; s < SEEDS; ++s) {
            bytes32 seed = keccak256(abi.encode("SYNERGY-AICB-V22", sellBps, s));
            (uint256 hardFinal, bool solvent) = _simulate(seed, sellBps);
            if (!solvent) { insolvent++; gross[s] = 0; }
            else gross[s] = hardFinal > HARD_START ? hardFinal - HARD_START : 0;
        }
        _sort(gross);
        d.p5Gross = gross[(SEEDS * 5 + 99) / 100 - 1];
        d.medianGross = gross[SEEDS / 2];
        d.p95Gross = gross[(SEEDS * 95 + 99) / 100 - 1];
        d.insolvencies = insolvent;
    }

    function _simulate(bytes32 seed, uint256 sellBps) internal pure returns (uint256 hardFinal, bool solvent) {
        SimState memory s = SimState(LP_SIDE_START, LP_SIDE_START, RESERVE_START, RESERVE_START);
        for (uint256 i; i < CYCLES; ++i) {
            uint256 rnd = uint256(keccak256(abi.encode(seed, i)));
            bool poolOne = ((rnd >> 32) & 1) != 0;
            bool sell = (rnd % BPS) < sellBps;
            uint256 l = poolOne ? s.l1 : s.l0;
            (uint256 nextL, uint256 delta, bool spend) = _tradeAndReset(l, TRADE, !sell);
            if (spend) {
                if (s.reserve < delta) return (s.reserve + s.l0 + s.l1, false);
                s.reserve -= delta;
            } else s.reserve += delta;
            if (poolOne) s.l1 = nextL; else s.l0 = nextL;
            if ((i + 1) % EPOCH == 0) _reinvest(s);
        }
        return (s.reserve + s.l0 + s.l1, true);
    }

    function _reinvest(SimState memory s) internal pure {
        uint256 c0 = _sellResetCost(s.l0, TRADE);
        uint256 c1 = _sellResetCost(s.l1, TRADE);
        uint256 floor = STRESS_SELL_COVERAGE * (c0 > c1 ? c0 : c1);
        uint256 epochProfit = s.reserve > s.epochStartReserve ? s.reserve - s.epochStartReserve : 0;
        uint256 requested = epochProfit * REINVEST_BPS / BPS;
        uint256 available = s.reserve > floor ? s.reserve - floor : 0;
        uint256 amount = requested < available ? requested : available;
        uint256 per = amount / 2;
        uint256 actual = per * 2;
        if (actual != 0) { s.reserve -= actual; s.l0 += per; s.l1 += per; }
        s.epochStartReserve = s.reserve;
    }

    function _ethFrontier(Core memory c, uint256 basefee) internal pure returns (Frontier memory f) {
        f.bestSystem = type(uint256).max; f.bestAllIn = type(uint256).max;
        f.worstSystem = 1; f.worstAllIn = 1;
        for (uint256 bi; bi < 4; ++bi) f = _ethBatch(f, c, basefee, bi);
        if (f.bestSystem == type(uint256).max) f.bestSystem = 0;
        if (f.bestAllIn == type(uint256).max) f.bestAllIn = 0;
    }

    function _ethBatch(Frontier memory f, Core memory c, uint256 basefee, uint256 bi)
        internal pure returns (Frontier memory)
    {
        uint256 batch = _batchAt(bi);
        uint256 sysUnits = _totalGasUnits(batch, SYSTEM_EVENT_GAS);
        uint256 allUnits = _totalGasUnits(batch, ALLIN_EVENT_GAS);
        for (uint256 gi; gi < 3; ++gi) {
            uint256 gm = _gasMultAt(gi);
            uint256 gp = basefee * gm;
            uint256 sysFixed = _weiToMicroUsd(sysUnits * gp, c.ethUsd8);
            uint256 allFixed = _weiToMicroUsd(allUnits * gp, c.ethUsd8);
            f = _mevSweep(f, c, sysFixed, allFixed, batch, gm);
        }
        return f;
    }

    function _baseFrontier(Core memory c, BaseFees memory bf) internal pure returns (Frontier memory f) {
        f.bestSystem = type(uint256).max; f.bestAllIn = type(uint256).max;
        f.worstSystem = 1; f.worstAllIn = 1;
        for (uint256 bi; bi < 4; ++bi) f = _baseBatch(f, c, bf, bi);
        if (f.bestSystem == type(uint256).max) f.bestSystem = 0;
        if (f.bestAllIn == type(uint256).max) f.bestAllIn = 0;
    }

    function _baseBatch(Frontier memory f, Core memory c, BaseFees memory bf, uint256 bi)
        internal pure returns (Frontier memory)
    {
        uint256 batch = _batchAt(bi);
        for (uint256 gi; gi < 3; ++gi) {
            uint256 gm = _gasMultAt(gi);
            uint256 sysFixed = _baseFixed(c.ethUsd8, bf, bi, gm, false);
            uint256 allFixed = _baseFixed(c.ethUsd8, bf, bi, gm, true);
            f = _mevSweep(f, c, sysFixed, allFixed, batch, gm);
        }
        return f;
    }

    function _baseFixed(uint256 ethUsd8, BaseFees memory bf, uint256 bi, uint256 gasMult, bool allIn)
        internal pure returns (uint256)
    {
        uint256 batch = _batchAt(bi);
        uint256 perEvent = allIn ? ALLIN_EVENT_GAS : SYSTEM_EVENT_GAS;
        uint256 op = allIn ? bf.opAllInPerBatch[bi] : bf.opSystemPerBatch[bi];
        uint256 executionWei = _totalGasUnits(batch, perEvent) * bf.basefee * gasMult;
        uint256 batchDataWei = (CYCLES / batch) * (bf.l1PerBatch[bi] + op);
        return _weiToMicroUsd(executionWei + batchDataWei, ethUsd8);
    }

    function _mevSweep(Frontier memory f, Core memory c, uint256 sysFixed, uint256 allFixed, uint256 batch, uint256 gasMult)
        internal pure returns (Frontier memory)
    {
        for (uint256 mi; mi < 4; ++mi) {
            uint256 mevBps = _mevAt(mi);
            uint256 proportional = _proportionalFriction(c.premiumBps, mevBps);
            uint256 ss = _firstPositiveScale(c.p5Gross, proportional, sysFixed);
            uint256 sa = _firstPositiveScale(c.p5Gross, proportional, allFixed);
            f.bestSystem = _minScale(f.bestSystem, ss);
            f.bestAllIn = _minScale(f.bestAllIn, sa);
            f.worstSystem = _maxScale(f.worstSystem, ss);
            f.worstAllIn = _maxScale(f.worstAllIn, sa);
            if (batch == 20 && gasMult == 1 && mevBps == 25) f.defaultSystem = ss;
            if (batch == 1 && gasMult == 5 && mevBps == 50) f.stressSystem = ss;
        }
        return f;
    }

    function _ethereumMetrics() internal returns (uint256 basefee, uint256 ethUsd8, uint256 premiumBps) {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", "https://ethereum-rpc.publicnode.com");
        vm.createSelectFork(rpc);
        basefee = block.basefee;
        (, int256 px,, uint256 updatedAt,) = IChainlinkV22(ETH_USD).latestRoundData();
        require(px > 0 && updatedAt > 0, "ETH/USD missing");
        ethUsd8 = uint256(px);
        premiumBps = uint256(IAaveV22(AAVE_POOL).FLASHLOAN_PREMIUM_TOTAL());
    }

    function _baseMetrics() internal returns (BaseFees memory bf) {
        string memory rpc = vm.envOr("BASE_RPC_URL", "https://base-rpc.publicnode.com");
        vm.createSelectFork(rpc);
        require(BASE_GPO.code.length > 0, "Base GPO missing");
        bf.basefee = block.basefee;
        IBaseGasPriceOracleV22 gpo = IBaseGasPriceOracleV22(BASE_GPO);
        for (uint256 bi; bi < 4; ++bi) {
            uint256 batch = _batchAt(bi);
            bytes memory sample = _nonZeroBytes(200 + 64 * batch);
            bf.l1PerBatch[bi] = gpo.getL1Fee(sample);
            bf.opSystemPerBatch[bi] = gpo.getOperatorFee(BATCH_OVERHEAD_GAS + SYSTEM_EVENT_GAS * batch);
            bf.opAllInPerBatch[bi] = gpo.getOperatorFee(BATCH_OVERHEAD_GAS + ALLIN_EVENT_GAS * batch);
            emit log_named_uint(_label("Base L1 fee wei batch ", batch), bf.l1PerBatch[bi]);
            emit log_named_uint(_label("Base operator sys wei batch ", batch), bf.opSystemPerBatch[bi]);
        }
    }

    function _proportionalFriction(uint256 premiumBps, uint256 mevBps) internal pure returns (uint256) {
        return CYCLES * TRADE * (premiumBps + V3_ROUNDTRIP_BPS + mevBps) / BPS;
    }
    function _firstPositiveScale(uint256 p5Gross, uint256 proportional, uint256 fixedCost) internal pure returns (uint256) {
        if (p5Gross <= proportional) return 0;
        return fixedCost / (p5Gross - proportional) + 1;
    }
    function _totalGasUnits(uint256 batch, uint256 perEvent) internal pure returns (uint256) {
        return CYCLES * perEvent + (CYCLES / batch) * BATCH_OVERHEAD_GAS;
    }
    function _weiToMicroUsd(uint256 weiCost, uint256 ethUsd8) internal pure returns (uint256) {
        return weiCost * ethUsd8 / 1e20;
    }

    function _tradeAndReset(uint256 l, uint256 trade, bool buy)
        internal pure returns (uint256 nextL, uint256 reserveDelta, bool isSpend)
    {
        uint256 out = _amountOut(trade, l, l);
        if (buy) {
            uint256 x = l - out; uint256 y = l + trade;
            nextL = _sqrt(x * y); reserveDelta = y - nextL;
        } else {
            uint256 x = l + trade; uint256 y = l - out;
            nextL = _sqrt(x * y); reserveDelta = nextL - y; isSpend = true;
        }
    }
    function _sellResetCost(uint256 l, uint256 trade) internal pure returns (uint256) {
        (, uint256 d,) = _tradeAndReset(l, trade, false); return d;
    }
    function _amountOut(uint256 amountIn, uint256 rin, uint256 rout) internal pure returns (uint256) {
        uint256 afterFee = amountIn * (BPS - EXTERNAL_FEE_BPS);
        return rout * afterFee / (rin * BPS + afterFee);
    }
    function _sqrt(uint256 a) internal pure returns (uint256 z) {
        if (a == 0) return 0; z = a; uint256 x = a / 2 + 1;
        while (x < z) { z = x; x = (a / x + x) / 2; }
    }
    function _sort(uint256[64] memory a) internal pure {
        for (uint256 i = 1; i < SEEDS; ++i) {
            uint256 key = a[i]; uint256 j = i;
            while (j > 0 && a[j - 1] > key) { a[j] = a[j - 1]; unchecked { --j; } }
            a[j] = key;
        }
    }
    function _nonZeroBytes(uint256 n) internal pure returns (bytes memory b) {
        b = new bytes(n); for (uint256 i; i < n; ++i) b[i] = 0xff;
    }
    function _batchAt(uint256 i) internal pure returns (uint256) {
        if (i == 0) return 1; if (i == 1) return 5; if (i == 2) return 20; return 100;
    }
    function _gasMultAt(uint256 i) internal pure returns (uint256) {
        if (i == 0) return 1; if (i == 1) return 2; return 5;
    }
    function _mevAt(uint256 i) internal pure returns (uint256) {
        if (i == 0) return 5; if (i == 1) return 10; if (i == 2) return 25; return 50;
    }
    function _minScale(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) return a; return b < a ? b : a;
    }
    function _maxScale(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) return 0; return b > a ? b : a;
    }

    function _logDistribution(uint256 sellBps, Distribution memory d) internal {
        emit log_named_uint(_label("insolvencies SELL bps ", sellBps), d.insolvencies);
        emit log_named_uint(_label("P5 gross microUSDT SELL bps ", sellBps), d.p5Gross);
        emit log_named_uint(_label("median gross microUSDT SELL bps ", sellBps), d.medianGross);
        emit log_named_uint(_label("P95 gross microUSDT SELL bps ", sellBps), d.p95Gross);
    }
    function _logFrontier(string memory net, uint256 sellBps, Frontier memory f) internal {
        emit log_named_uint(string.concat(net, " best system scale SELL ", _u(sellBps)), f.bestSystem);
        emit log_named_uint(string.concat(net, " worst-grid system scale SELL ", _u(sellBps)), f.worstSystem);
        emit log_named_uint(string.concat(net, " best all-in scale SELL ", _u(sellBps)), f.bestAllIn);
        emit log_named_uint(string.concat(net, " worst-grid all-in scale SELL ", _u(sellBps)), f.worstAllIn);
        emit log_named_uint(string.concat(net, " default b20/g1/mev25 system scale SELL ", _u(sellBps)), f.defaultSystem);
        emit log_named_uint(string.concat(net, " stress b1/g5/mev50 system scale SELL ", _u(sellBps)), f.stressSystem);
    }
    function _label(string memory p, uint256 v) internal pure returns (string memory) { return string.concat(p, _u(v)); }
    function _u(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0"; uint256 x = v; uint256 n;
        while (x != 0) { n++; x /= 10; }
        bytes memory b = new bytes(n);
        while (v != 0) { n--; b[n] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return string(b);
    }
}
