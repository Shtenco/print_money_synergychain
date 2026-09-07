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

/// @notice V2.2 distribution firewall.
/// @dev 64 independent deterministic seeds x 10k cycles for each SELL bias.
///      Gross hard-USDT distributions are then transformed through the full
///      MEV x gas x batching x network grid. Scaling is homogeneous: all hard
///      balances and trade notional scale together while execution gas remains
///      mostly fixed per EVM action/batch.
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
    uint256 constant TRADE = 50_000; // $0.05, micro-USDT
    uint256 constant HARD_START = 604_160; // $0.604160
    uint256 constant RESERVE_START = 504_160;
    uint256 constant LP_SIDE_START = 50_000;
    uint256 constant V3_ROUNDTRIP_BPS = 2; // real 1bp USDC/USDT pool, two legs

    // Batch gas model is anchored to V2.1 measured ~170k reset and ~300k all-in/event:
    // batch=1 -> 50k overhead + 120k system-event = 170k
    // batch=1 -> 50k overhead + 250k all-in-event = 300k
    uint256 constant BATCH_OVERHEAD_GAS = 50_000;
    uint256 constant SYSTEM_EVENT_GAS = 120_000;
    uint256 constant ALLIN_EVENT_GAS = 250_000;

    event log_named_uint(string key, uint256 val);

    struct SimState {
        uint256 l0;
        uint256 l1;
        uint256 reserve;
        uint256 epochStartReserve;
        bool solvent;
    }

    struct Distribution {
        uint256 p5Gross;
        uint256 medianGross;
        uint256 p95Gross;
        uint256 insolvencies;
    }

    struct Frontier {
        uint256 bestSystem;
        uint256 worstSystem;
        uint256 bestAllIn;
        uint256 worstAllIn;
        uint256 defaultSystem;
        uint256 stressSystem;
    }

    struct BaseFees {
        uint256 basefee;
        uint256[4] l1PerBatch;
        uint256[4] opSystemPerBatch;
        uint256[4] opAllInPerBatch;
    }

    function testV22P5DistributionFirewall() external {
        (uint256 ethBasefee, uint256 ethUsd8, uint256 premiumBps) = _ethereumMetrics();
        BaseFees memory bf = _baseMetrics();

        emit log_named_uint("V22 seeds", SEEDS);
        emit log_named_uint("V22 cycles per seed", CYCLES);
        emit log_named_uint("ETH basefee wei", ethBasefee);
        emit log_named_uint("Base basefee wei", bf.basefee);
        emit log_named_uint("ETH/USD 8 decimals", ethUsd8);
        emit log_named_uint("Aave flash premium bps", premiumBps);

        uint256[4] memory biases = [uint256(5_000), 5_500, 6_000, 7_000];
        uint256 robustPasses;

        for (uint256 i; i < biases.length; ++i) {
            uint256 sellBps = biases[i];
            Distribution memory d = _distribution(sellBps);
            _logDistribution(sellBps, d);

            // If at least ceil(5% * N) paths are insolvent, the P5 economic
            // criterion is an automatic FAIL at every homogeneous scale.
            uint256 insolvencyCutoff = (SEEDS * 5 + 99) / 100;
            if (d.insolvencies >= insolvencyCutoff || d.p5Gross == 0) {
                emit log_named_uint(_label("P5 insolvency/no-scale SELL bps ", sellBps), 1);
                continue;
            }

            Frontier memory ethF = _ethereumFrontier(d.p5Gross, premiumBps, ethBasefee, ethUsd8);
            Frontier memory baseF = _baseFrontier(d.p5Gross, premiumBps, bf, ethUsd8);
            _logFrontier("ETH", sellBps, ethF);
            _logFrontier("BASE", sellBps, baseF);

            if (baseF.worstSystem != 0) robustPasses++;
        }

        // At least balanced and moderate 55/45 SELL regimes should have a
        // finite robust Base scale if the architecture remains economically viable.
        require(robustPasses >= 2, "V2.2: fewer than two robust Base bias regimes");
    }

    function _distribution(uint256 sellBps) internal pure returns (Distribution memory d) {
        uint256[64] memory gross;
        uint256 insolvent;

        for (uint256 s; s < SEEDS; ++s) {
            bytes32 seed = keccak256(abi.encode("SYNERGY-AICB-V22", sellBps, s));
            (uint256 hardFinal, bool solvent) = _simulate(seed, sellBps);
            if (!solvent) {
                insolvent++;
                gross[s] = 0;
            } else {
                gross[s] = hardFinal > HARD_START ? hardFinal - HARD_START : 0;
            }
        }

        _sort(gross);
        uint256 p5Index = (SEEDS * 5 + 99) / 100 - 1;
        uint256 p95Index = (SEEDS * 95 + 99) / 100 - 1;
        d = Distribution({
            p5Gross: gross[p5Index],
            medianGross: gross[SEEDS / 2],
            p95Gross: gross[p95Index],
            insolvencies: insolvent
        });
    }

    function _simulate(bytes32 seed, uint256 sellBps) internal pure returns (uint256 hardFinal, bool solvent) {
        SimState memory s = SimState({
            l0: LP_SIDE_START,
            l1: LP_SIDE_START,
            reserve: RESERVE_START,
            epochStartReserve: RESERVE_START,
            solvent: true
        });

        for (uint256 i; i < CYCLES; ++i) {
            uint256 rnd = uint256(keccak256(abi.encode(seed, i)));
            bool poolOne = ((rnd >> 32) & 1) != 0;
            bool sell = (rnd % BPS) < sellBps;
            uint256 l = poolOne ? s.l1 : s.l0;
            (uint256 nextL, uint256 reserveDelta, bool isSpend) = _tradeAndReset(l, TRADE, !sell);

            if (isSpend) {
                if (s.reserve < reserveDelta) return (s.reserve + s.l0 + s.l1, false);
                s.reserve -= reserveDelta;
            } else {
                s.reserve += reserveDelta;
            }
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
        if (actual != 0) {
            s.reserve -= actual;
            s.l0 += per;
            s.l1 += per;
        }
        s.epochStartReserve = s.reserve;
    }

    function _ethereumFrontier(uint256 p5Gross, uint256 premiumBps, uint256 basefee, uint256 ethUsd8)
        internal pure returns (Frontier memory f)
    {
        uint256[4] memory batches = [uint256(1), 5, 20, 100];
        uint256[3] memory gasMult = [uint256(1), 2, 5];
        uint256[4] memory mev = [uint256(5), 10, 25, 50];
        f.bestSystem = type(uint256).max;
        f.bestAllIn = type(uint256).max;

        for (uint256 bi; bi < batches.length; ++bi) {
            uint256 batch = batches[bi];
            uint256 sysGasUnits = _totalGasUnits(batch, SYSTEM_EVENT_GAS);
            uint256 allGasUnits = _totalGasUnits(batch, ALLIN_EVENT_GAS);
            for (uint256 gi; gi < gasMult.length; ++gi) {
                uint256 gp = basefee * gasMult[gi];
                uint256 sysFixed = _weiToMicroUsd(sysGasUnits * gp, ethUsd8);
                uint256 allFixed = _weiToMicroUsd(allGasUnits * gp, ethUsd8);
                for (uint256 mi; mi < mev.length; ++mi) {
                    uint256 proportional = _proportionalFriction(premiumBps, mev[mi]);
                    uint256 ss = _firstPositiveScale(p5Gross, proportional, sysFixed);
                    uint256 sa = _firstPositiveScale(p5Gross, proportional, allFixed);
                    f.bestSystem = _minScale(f.bestSystem, ss);
                    f.bestAllIn = _minScale(f.bestAllIn, sa);
                    f.worstSystem = _maxScale(f.worstSystem, ss);
                    f.worstAllIn = _maxScale(f.worstAllIn, sa);

                    if (batch == 20 && gasMult[gi] == 1 && mev[mi] == 25) f.defaultSystem = ss;
                    if (batch == 1 && gasMult[gi] == 5 && mev[mi] == 50) f.stressSystem = ss;
                }
            }
        }
        if (f.bestSystem == type(uint256).max) f.bestSystem = 0;
        if (f.bestAllIn == type(uint256).max) f.bestAllIn = 0;
    }

    function _baseFrontier(uint256 p5Gross, uint256 premiumBps, BaseFees memory bf, uint256 ethUsd8)
        internal pure returns (Frontier memory f)
    {
        uint256[4] memory batches = [uint256(1), 5, 20, 100];
        uint256[3] memory gasMult = [uint256(1), 2, 5];
        uint256[4] memory mev = [uint256(5), 10, 25, 50];
        f.bestSystem = type(uint256).max;
        f.bestAllIn = type(uint256).max;

        for (uint256 bi; bi < batches.length; ++bi) {
            uint256 batch = batches[bi];
            uint256 nBatches = CYCLES / batch;
            uint256 sysGasUnits = _totalGasUnits(batch, SYSTEM_EVENT_GAS);
            uint256 allGasUnits = _totalGasUnits(batch, ALLIN_EVENT_GAS);
            for (uint256 gi; gi < gasMult.length; ++gi) {
                uint256 gp = bf.basefee * gasMult[gi];
                uint256 sysWei = sysGasUnits * gp + nBatches * (bf.l1PerBatch[bi] + bf.opSystemPerBatch[bi]);
                uint256 allWei = allGasUnits * gp + nBatches * (bf.l1PerBatch[bi] + bf.opAllInPerBatch[bi]);
                uint256 sysFixed = _weiToMicroUsd(sysWei, ethUsd8);
                uint256 allFixed = _weiToMicroUsd(allWei, ethUsd8);
                for (uint256 mi; mi < mev.length; ++mi) {
                    uint256 proportional = _proportionalFriction(premiumBps, mev[mi]);
                    uint256 ss = _firstPositiveScale(p5Gross, proportional, sysFixed);
                    uint256 sa = _firstPositiveScale(p5Gross, proportional, allFixed);
                    f.bestSystem = _minScale(f.bestSystem, ss);
                    f.bestAllIn = _minScale(f.bestAllIn, sa);
                    f.worstSystem = _maxScale(f.worstSystem, ss);
                    f.worstAllIn = _maxScale(f.worstAllIn, sa);
                    if (batch == 20 && gasMult[gi] == 1 && mev[mi] == 25) f.defaultSystem = ss;
                    if (batch == 1 && gasMult[gi] == 5 && mev[mi] == 50) f.stressSystem = ss;
                }
            }
        }
        if (f.bestSystem == type(uint256).max) f.bestSystem = 0;
        if (f.bestAllIn == type(uint256).max) f.bestAllIn = 0;
    }

    function _baseMetrics() internal returns (BaseFees memory bf) {
        string memory rpc = vm.envOr("BASE_RPC_URL", "https://base-rpc.publicnode.com");
        vm.createSelectFork(rpc);
        require(BASE_GPO.code.length > 0, "Base GPO missing");
        bf.basefee = block.basefee;
        IBaseGasPriceOracleV22 gpo = IBaseGasPriceOracleV22(BASE_GPO);
        uint256[4] memory batches = [uint256(1), 5, 20, 100];
        for (uint256 i; i < batches.length; ++i) {
            uint256 batch = batches[i];
            bytes memory sample = _nonZeroBytes(200 + 64 * batch);
            bf.l1PerBatch[i] = gpo.getL1Fee(sample);
            bf.opSystemPerBatch[i] = gpo.getOperatorFee(BATCH_OVERHEAD_GAS + SYSTEM_EVENT_GAS * batch);
            bf.opAllInPerBatch[i] = gpo.getOperatorFee(BATCH_OVERHEAD_GAS + ALLIN_EVENT_GAS * batch);
            emit log_named_uint(_label("Base L1 fee wei batch ", batch), bf.l1PerBatch[i]);
            emit log_named_uint(_label("Base operator sys wei batch ", batch), bf.opSystemPerBatch[i]);
        }
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

    function _proportionalFriction(uint256 premiumBps, uint256 mevBps) internal pure returns (uint256) {
        uint256 notional = CYCLES * TRADE;
        return notional * (premiumBps + V3_ROUNDTRIP_BPS + mevBps) / BPS;
    }

    function _firstPositiveScale(uint256 p5Gross, uint256 proportionalAtScale1, uint256 fixedCost)
        internal pure returns (uint256)
    {
        if (p5Gross <= proportionalAtScale1) return 0;
        uint256 margin = p5Gross - proportionalAtScale1;
        uint256 s = fixedCost / margin + 1;
        return s == 0 ? 1 : s;
    }

    function _totalGasUnits(uint256 batch, uint256 perEvent) internal pure returns (uint256) {
        uint256 nBatches = CYCLES / batch;
        return CYCLES * perEvent + nBatches * BATCH_OVERHEAD_GAS;
    }

    function _weiToMicroUsd(uint256 weiCost, uint256 ethUsd8) internal pure returns (uint256) {
        return weiCost * ethUsd8 / 1e20;
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

    function _sqrt(uint256 a) internal pure returns (uint256 z) {
        if (a == 0) return 0;
        z = a;
        uint256 x = a / 2 + 1;
        while (x < z) { z = x; x = (a / x + x) / 2; }
    }

    function _sort(uint256[64] memory a) internal pure {
        for (uint256 i = 1; i < SEEDS; ++i) {
            uint256 key = a[i];
            uint256 j = i;
            while (j > 0 && a[j - 1] > key) {
                a[j] = a[j - 1];
                unchecked { --j; }
            }
            a[j] = key;
        }
    }

    function _nonZeroBytes(uint256 n) internal pure returns (bytes memory b) {
        b = new bytes(n);
        for (uint256 i; i < n; ++i) b[i] = 0xff;
    }

    function _minScale(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) return a;
        return b < a ? b : a;
    }

    function _maxScale(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) return 0;
        return b > a ? b : a;
    }

    function _logDistribution(uint256 sellBps, Distribution memory d) internal {
        emit log_named_uint(_label("SELL bps ", sellBps), sellBps);
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

    function _label(string memory p, uint256 v) internal pure returns (string memory) {
        return string.concat(p, _u(v));
    }

    function _u(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 x = v;
        uint256 n;
        while (x != 0) { n++; x /= 10; }
        bytes memory b = new bytes(n);
        while (v != 0) {
            n--;
            b[n] = bytes1(uint8(48 + v % 10));
            v /= 10;
        }
        return string(b);
    }
}
