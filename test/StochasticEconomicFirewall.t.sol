// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

interface VmStochastic {
    function envOr(string calldata key, string calldata defaultValue) external returns (string memory value);
    function createSelectFork(string calldata urlOrAlias) external returns (uint256 forkId);
}
interface IChainlinkStochastic {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice 10k-cycle economic firewall using the real latest-mainnet basefee + Chainlink ETH/USD.
/// @dev This is an EVM state-machine mirror of the fee-paying external CPMM trade followed by fee-exempt exact AICB reset.
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
    uint256 constant RESET_GAS = 170_000; // conservative rounding above measured 165,588..168,566
    uint256 constant PRIORITY_FEE_WEI = 100_000_000; // 0.1 gwei realistic scenario

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

    function testTenThousandRandom005With5132SolvencyWaterfall() external {
        _fork();
        (, int256 px,, uint256 updatedAt,) = IChainlinkStochastic(ETH_USD).latestRoundData();
        require(px > 0 && updatedAt > 0, "ETHUSD");
        uint256 ethUsd8 = uint256(px);

        Result memory r = _simulate(keccak256("SYNERGY-AICB-V2-SEED-42"), 50_000, true, ethUsd8);
        require(r.solvent, "AICB reserve insolvency");
        // The firewall is deliberately expected to REJECT the $0.05 Ethereum-mainnet configuration.
        require(r.netBaseOnly < 0, "$0.05 unexpectedly passes even basefee-only firewall");
        require(r.netWithTip < r.netBaseOnly, "priority fee accounting");

        _logs("005", r, ethUsd8);
    }

    function testTenThousandRandom005OptimisticNoReinvestStillFails() external {
        _fork();
        (, int256 px,, uint256 updatedAt,) = IChainlinkStochastic(ETH_USD).latestRoundData();
        require(px > 0 && updatedAt > 0, "ETHUSD");
        Result memory r = _simulate(keccak256("SYNERGY-AICB-V2-UPPER-BOUND"), 50_000, false, uint256(px));
        require(r.solvent, "upper-bound reserve insolvency");
        // No explicit LP reinvest maximizes shallow-pool spread capture. If even this loses after basefee,
        // a deeper 51.32% reinvest path cannot rescue the five-cent mainnet economics.
        require(r.netBaseOnly < 0, "optimistic $0.05 upper bound unexpectedly passes");
        _logs("005-upper", r, uint256(px));
    }

    function _simulate(bytes32 seed, uint256 trade, bool reinvest, uint256 ethUsd8) internal view returns (Result memory r) {
        uint256 l0 = 50_000; // 0.050000 USDT quote side
        uint256 l1 = 50_000;
        uint256 reserve = 504_160; // 0.100000 AICB + 0.404160 already-realized arb profit
        uint256 hardStart = reserve + l0 + l1; // 0.604160
        uint256 epochStartReserve = reserve;
        bool solvent = true;

        for (uint256 i; i < CYCLES; ++i) {
            uint256 rnd = uint256(keccak256(abi.encode(seed, i)));
            bool poolOne = (rnd & 1) != 0;
            bool buy = (rnd & 2) != 0;
            uint256 l = poolOne ? l1 : l0;
            (uint256 nextL, uint256 reserveDelta, bool isSpend) = _tradeAndReset(l, trade, buy);

            if (isSpend) {
                if (reserve < reserveDelta) { solvent = false; break; }
                reserve -= reserveDelta;
            } else {
                reserve += reserveDelta;
            }
            if (poolOne) l1 = nextL; else l0 = nextL;

            if (reinvest && (i + 1) % EPOCH == 0) {
                uint256 c0 = _sellResetCost(l0, trade);
                uint256 c1 = _sellResetCost(l1, trade);
                uint256 floor = STRESS_SELL_COVERAGE * (c0 > c1 ? c0 : c1);
                uint256 epochProfit = reserve > epochStartReserve ? reserve - epochStartReserve : 0;
                uint256 requested = epochProfit * REINVEST_BPS / BPS;
                uint256 available = reserve > floor ? reserve - floor : 0;
                uint256 amount = requested < available ? requested : available;
                uint256 per = amount / 2;
                uint256 actual = per * 2;
                if (actual != 0) {
                    reserve -= actual;
                    l0 += per;
                    l1 += per;
                    r.reinvested += actual;
                }
                epochStartReserve = reserve;
            }
        }

        r.solvent = solvent;
        r.reserveFinal = reserve;
        r.lpFinal = l0 + l1;
        r.hardFinal = reserve + l0 + l1;
        r.grossProfit = r.hardFinal > hardStart ? r.hardFinal - hardStart : 0;
        r.mevHaircut = CYCLES * trade * MEV_BPS / BPS;
        r.gasBaseOnly = _gasMicroUsd(CYCLES * RESET_GAS, block.basefee, ethUsd8);
        r.gasWithTip = _gasMicroUsd(CYCLES * RESET_GAS, block.basefee + PRIORITY_FEE_WEI, ethUsd8);
        r.netBaseOnly = int256(r.hardFinal) - int256(hardStart) - int256(r.gasBaseOnly) - int256(r.mevHaircut);
        r.netWithTip = int256(r.hardFinal) - int256(hardStart) - int256(r.gasWithTip) - int256(r.mevHaircut);
    }

    function _tradeAndReset(uint256 l, uint256 trade, bool buy)
        internal pure returns (uint256 nextL, uint256 reserveDelta, bool isSpend)
    {
        uint256 out = _amountOut(trade, l, l);
        uint256 x;
        uint256 y;
        if (buy) {
            x = l - out;
            y = l + trade;
            nextL = _sqrt(x * y);
            reserveDelta = y - nextL; // AICB sells minted base, collecting hard quote
            isSpend = false;
        } else {
            x = l + trade;
            y = l - out;
            nextL = _sqrt(x * y);
            reserveDelta = nextL - y; // AICB spends hard quote to buy/burn base
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
        // gas*wei /1e18 ETH * ethUsd8/1e8 USD *1e6 microUSD = numerator /1e20
        return gasUnits * gasPriceWei * ethUsd8 / 1e20;
    }

    function _sqrt(uint256 a) internal pure returns (uint256 z) {
        if (a == 0) return 0;
        z = a;
        uint256 x = a / 2 + 1;
        while (x < z) { z = x; x = (a / x + x) / 2; }
    }

    function _fork() internal {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", "https://ethereum-rpc.publicnode.com");
        vm.createSelectFork(rpc);
    }

    function _logs(string memory, Result memory r, uint256 ethUsd8) internal {
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
