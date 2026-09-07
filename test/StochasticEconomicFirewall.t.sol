// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

interface VmStochastic {
    function envOr(string calldata key, string calldata defaultValue) external returns (string memory value);
    function createSelectFork(string calldata urlOrAlias) external returns (uint256 forkId);
}
interface IChainlinkStochastic {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}
interface IAavePoolStochastic {
    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint128);
}

/// @notice 10k-cycle economic firewall using live Ethereum basefee, Chainlink ETH/USD
///         and live Aave V3 flash premium from the selected mainnet fork.
/// @dev External CPMM trades pay 30 bps. AICB exact resets are fee-exempt in the research AMM.
///      Two gas views are reported:
///      (1) system-only: external users pay their own trade gas; system pays reset gas;
///      (2) all-in: system is charged both external-trade + reset gas.
contract StochasticEconomicFirewallTest {
    VmStochastic constant vm = VmStochastic(address(uint160(uint256(keccak256("hevm cheat code")))));

    address constant ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    uint256 constant BPS = 10_000;
    uint256 constant EXTERNAL_FEE_BPS = 30;
    uint256 constant REINVEST_BPS = 5_132;
    uint256 constant MEV_BPS = 5;
    uint256 constant UNI_ROUNDTRIP_FEE_BPS = 2; // USDC->USDT->USDC on the real 1-bp V3 pool
    uint256 constant CYCLES = 10_000;
    uint256 constant EPOCH = 100;
    uint256 constant STRESS_SELL_COVERAGE = 1_000;

    // Measured on MainnetForkLatest.t.sol at fork block ~25.928m:
    // external BUY/SELL ~131-133k, AICB reset ~166-169k.
    uint256 constant RESET_GAS = 170_000;
    uint256 constant ALL_IN_CYCLE_GAS = 300_000;
    uint256 constant PRIORITY_FEE_WEI = 100_000_000; // 0.1 gwei

    event log_named_uint(string key, uint256 val);
    event log_named_int(string key, int256 val);

    struct Result {
        uint256 hardFinal;
        uint256 reserveFinal;
        uint256 lpFinal;
        uint256 grossProfit;
        uint256 reinvested;
        uint256 gasSystemBase;
        uint256 gasSystemTip;
        uint256 gasAllInBase;
        uint256 gasAllInTip;
        uint256 mevHaircut;
        uint256 flashAndV3Friction;
        int256 netSystemBase;
        int256 netSystemTip;
        int256 netAllInBase;
        int256 netAllInTip;
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

    function testTenThousandRandom005With5132StrictFirewall() external {
        _fork();
        uint256 ethUsd8 = _ethUsd8();
        uint256 premiumBps = IAavePoolStochastic(AAVE_POOL).FLASHLOAN_PREMIUM_TOTAL();
        Result memory r = _simulate(keccak256("SYNERGY-AICB-V2-SEED-42"), 1, true, ethUsd8, premiumBps);
        require(r.solvent, "AICB reserve insolvency");
        require(r.netSystemBase < 0, "$0.05 unexpectedly passes system-only basefee firewall");
        require(r.netAllInBase < r.netSystemBase, "all-in gas must be worse");
        require(r.netSystemTip < r.netSystemBase, "priority fee accounting");
        _logs(r, ethUsd8, premiumBps, 1);
    }

    function testTenThousandRandom005OptimisticNoReinvestStillFailsStrict() external {
        _fork();
        uint256 ethUsd8 = _ethUsd8();
        uint256 premiumBps = IAavePoolStochastic(AAVE_POOL).FLASHLOAN_PREMIUM_TOTAL();
        Result memory r = _simulate(keccak256("SYNERGY-AICB-V2-UPPER-BOUND"), 1, false, ethUsd8, premiumBps);
        require(r.solvent, "upper-bound reserve insolvency");
        require(r.netSystemBase < 0, "optimistic $0.05 upper bound unexpectedly passes");
        _logs(r, ethUsd8, premiumBps, 1);
    }

    /// @notice Finds first integer scale where the same relative model becomes net positive.
    /// scale=1 means initial HardUSDT=0.604160 and trade=0.05 USDT.
    function testScaleSweepFindsBreakEven() external {
        _fork();
        uint256 ethUsd8 = _ethUsd8();
        uint256 premiumBps = IAavePoolStochastic(AAVE_POOL).FLASHLOAN_PREMIUM_TOTAL();

        uint256 firstSystemBase;
        uint256 firstSystemTip;
        uint256 firstAllInBase;
        uint256 firstAllInTip;

        for (uint256 scale = 1; scale <= 64; ++scale) {
            Result memory r = _simulate(keccak256("SYNERGY-AICB-V2-SCALE"), scale, true, ethUsd8, premiumBps);
            require(r.solvent, "scale sweep insolvency");
            if (firstSystemBase == 0 && r.netSystemBase > 0) firstSystemBase = scale;
            if (firstSystemTip == 0 && r.netSystemTip > 0) firstSystemTip = scale;
            if (firstAllInBase == 0 && r.netAllInBase > 0) firstAllInBase = scale;
            if (firstAllInTip == 0 && r.netAllInTip > 0) firstAllInTip = scale;
            if (firstSystemBase != 0 && firstSystemTip != 0 && firstAllInBase != 0 && firstAllInTip != 0) break;
        }

        require(firstSystemBase != 0 && firstSystemTip != 0 && firstAllInBase != 0 && firstAllInTip != 0, "no break-even <=64x");
        require(firstSystemBase <= firstAllInBase, "gas ownership ordering");
        require(firstSystemTip <= firstAllInTip, "tip gas ownership ordering");

        emit log_named_uint("break-even scale system/base", firstSystemBase);
        emit log_named_uint("break-even trade microUSDT system/base", 50_000 * firstSystemBase);
        emit log_named_uint("break-even initial hard microUSDT system/base", 604_160 * firstSystemBase);
        emit log_named_uint("break-even scale system/+0.1gwei", firstSystemTip);
        emit log_named_uint("break-even trade microUSDT system/+0.1gwei", 50_000 * firstSystemTip);
        emit log_named_uint("break-even initial hard microUSDT system/+0.1gwei", 604_160 * firstSystemTip);
        emit log_named_uint("break-even scale all-in/base", firstAllInBase);
        emit log_named_uint("break-even trade microUSDT all-in/base", 50_000 * firstAllInBase);
        emit log_named_uint("break-even initial hard microUSDT all-in/base", 604_160 * firstAllInBase);
        emit log_named_uint("break-even scale all-in/+0.1gwei", firstAllInTip);
        emit log_named_uint("break-even trade microUSDT all-in/+0.1gwei", 50_000 * firstAllInTip);
        emit log_named_uint("break-even initial hard microUSDT all-in/+0.1gwei", 604_160 * firstAllInTip);
    }

    function _simulate(bytes32 seed, uint256 scale, bool reinvest, uint256 ethUsd8, uint256 premiumBps)
        internal view returns (Result memory r)
    {
        uint256 trade = 50_000 * scale;
        SimState memory s = SimState({
            l0: 50_000 * scale,
            l1: 50_000 * scale,
            reserve: 504_160 * scale,
            epochStartReserve: 504_160 * scale,
            reinvested: 0,
            solvent: true
        });
        uint256 hardStart = 604_160 * scale;

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

        uint256 notional = CYCLES * trade;
        r.mevHaircut = notional * MEV_BPS / BPS;
        r.flashAndV3Friction = notional * (premiumBps + UNI_ROUNDTRIP_FEE_BPS) / BPS;

        r.gasSystemBase = _gasMicroUsd(CYCLES * RESET_GAS, block.basefee, ethUsd8);
        r.gasSystemTip = _gasMicroUsd(CYCLES * RESET_GAS, block.basefee + PRIORITY_FEE_WEI, ethUsd8);
        r.gasAllInBase = _gasMicroUsd(CYCLES * ALL_IN_CYCLE_GAS, block.basefee, ethUsd8);
        r.gasAllInTip = _gasMicroUsd(CYCLES * ALL_IN_CYCLE_GAS, block.basefee + PRIORITY_FEE_WEI, ethUsd8);

        int256 grossNetFriction = int256(r.grossProfit) - int256(r.mevHaircut) - int256(r.flashAndV3Friction);
        r.netSystemBase = grossNetFriction - int256(r.gasSystemBase);
        r.netSystemTip = grossNetFriction - int256(r.gasSystemTip);
        r.netAllInBase = grossNetFriction - int256(r.gasAllInBase);
        r.netAllInTip = grossNetFriction - int256(r.gasAllInTip);
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

    function _logs(Result memory r, uint256 ethUsd8, uint256 premiumBps, uint256 scale) internal {
        emit log_named_uint("stochastic fork block", block.number);
        emit log_named_uint("scale", scale);
        emit log_named_uint("basefee wei", block.basefee);
        emit log_named_uint("ETH/USD 8 decimals", ethUsd8);
        emit log_named_uint("Aave flash premium bps", premiumBps);
        emit log_named_uint("hard final microUSDT", r.hardFinal);
        emit log_named_uint("AICB reserve final microUSDT", r.reserveFinal);
        emit log_named_uint("LP hard final microUSDT", r.lpFinal);
        emit log_named_uint("gross hard profit microUSDT", r.grossProfit);
        emit log_named_uint("explicit reinvest microUSDT", r.reinvested);
        emit log_named_uint("MEV 5bps microUSD", r.mevHaircut);
        emit log_named_uint("Aave + V3 roundtrip friction microUSD", r.flashAndV3Friction);
        emit log_named_uint("system gas base-only microUSD", r.gasSystemBase);
        emit log_named_uint("system gas +0.1gwei microUSD", r.gasSystemTip);
        emit log_named_uint("all-in gas base-only microUSD", r.gasAllInBase);
        emit log_named_uint("all-in gas +0.1gwei microUSD", r.gasAllInTip);
        emit log_named_int("NET system/base microUSD", r.netSystemBase);
        emit log_named_int("NET system/+0.1gwei microUSD", r.netSystemTip);
        emit log_named_int("NET all-in/base microUSD", r.netAllInBase);
        emit log_named_int("NET all-in/+0.1gwei microUSD", r.netAllInTip);
    }
}
