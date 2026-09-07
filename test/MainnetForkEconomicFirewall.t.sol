// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {SafeToken, IERC20Minimal} from "../src/v2/SafeToken.sol";
import {ResearchToken6} from "../src/v2/ResearchToken6.sol";
import {Fixed5050CPMM6} from "../src/v2/Fixed5050CPMM6.sol";
import {AICBControllerV2} from "../src/v2/AICBControllerV2.sol";
import {ExternalTrader6} from "../src/v2/ExternalTrader6.sol";
import {AaveUniV3FlashProbe, IAavePoolV3} from "../src/v2/AaveUniV3FlashProbe.sol";

interface VmV2 {
    function envOr(string calldata key, string calldata defaultValue) external returns (string memory value);
    function createSelectFork(string calldata urlOrAlias, uint256 blockNumber) external returns (uint256 forkId);
    function prank(address msgSender) external;
}

interface IUniV3PoolView {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);
}

interface IChainlinkFeed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

contract MainnetForkEconomicFirewallTest {
    using SafeToken for address;

    VmV2 constant vm = VmV2(address(uint160(uint256(keccak256("hevm cheat code")))));

    address constant USDC = 0xA0b86991c6218b36c1d19d4a2e9eb0ce3606eb48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant UNI_USDC_USDT_001 = 0x3416cF6C708Da44DB2624D63ea0AAef7113527C6;
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant FUNDING_WHALE = 0x28C6c06298d514Db089934071355E5743bf21d60;
    uint256 constant FORK_BLOCK = 25_926_491;
    uint256 constant MICRO = 1e6;

    event log_named_uint(string key, uint256 val);
    event log_named_int(string key, int256 val);

    struct System {
        ResearchToken6 syna;
        ResearchToken6 synr;
        Fixed5050CPMM6 a;
        Fixed5050CPMM6 b;
        Fixed5050CPMM6 c;
        AICBControllerV2 cb;
        ExternalTrader6 trader;
    }

    function testMainnetReferencesAreReal() external {
        _fork();
        _assertTrue(USDC.code.length > 0, "USDC code");
        _assertTrue(USDT.code.length > 0, "USDT code");
        _assertTrue(AAVE_POOL.code.length > 0, "Aave code");
        _assertTrue(UNI_USDC_USDT_001.code.length > 0, "Uniswap pool code");

        IUniV3PoolView p = IUniV3PoolView(UNI_USDC_USDT_001);
        _assertEq(uint256(uint160(p.token0())), uint256(uint160(USDC)), "token0");
        _assertEq(uint256(uint160(p.token1())), uint256(uint160(USDT)), "token1");
        _assertEq(p.fee(), 100, "fee tier");
        _assertTrue(p.liquidity() > 0, "real concentrated liquidity");

        uint256 premiumBps = IAavePoolV3(AAVE_POOL).FLASHLOAN_PREMIUM_TOTAL();
        _assertTrue(premiumBps > 0, "flash premium");
        (, int256 ethUsd,, uint256 updatedAt,) = IChainlinkFeed(ETH_USD).latestRoundData();
        _assertTrue(ethUsd > 0 && updatedAt > 0, "ETH/USD oracle");
        emit log_named_uint("Aave flash premium bps", premiumBps);
        emit log_named_uint("Uniswap V3 liquidity", p.liquidity());
        emit log_named_uint("ETH/USD 8 decimals", uint256(ethUsd));
        emit log_named_uint("fork basefee wei", block.basefee);
    }

    function testRealAaveFlashAndUniswapRoundTripCost() external {
        _fork();
        AaveUniV3FlashProbe probe = new AaveUniV3FlashProbe();
        _fund(USDC, address(probe), 200 * MICRO);

        uint256 beforeBal = IERC20Minimal(USDC).balanceOf(address(probe));
        uint256 gasBefore = gasleft();
        uint256 netCost = probe.run(10_000 * MICRO);
        uint256 gasUsed = gasBefore - gasleft();
        uint256 afterBal = IERC20Minimal(USDC).balanceOf(address(probe));

        _assertTrue(probe.lastPremium() > 0, "premium paid");
        _assertTrue(probe.lastUsdtOut() > 0 && probe.lastUsdcBack() > 0, "real swaps");
        _assertTrue(netCost > 0 && beforeBal - afterBal == netCost, "real friction");
        _assertTrue(afterBal > 0, "loan repaid without debt");
        emit log_named_uint("flash roundtrip net cost USDC micro", netCost);
        emit log_named_uint("flash premium USDC micro", probe.lastPremium());
        emit log_named_uint("flash+2swap gas used", gasUsed);
    }

    function testRealUSDTExactResetAndHardAccounting() external {
        _fork();
        _fund(USDT, address(this), 20 * MICRO);
        System memory s = _deploySystem();

        uint256 hard0 = s.cb.hardUsdt();
        _assertEq(hard0, 604_160, "0.604160 hard USDT bootstrap");

        USDT.safeTransfer(address(s.trader), 50_000);
        s.trader.buy(s.a, 50_000);
        uint256 pHigh = s.a.pricePpm();
        _assertTrue(pHigh > 1_000_000, "BUY raises price");
        s.cb.resetHardPool(s.a);
        _assertNear(s.a.pricePpm(), 1_000_000, 30, "BUY reset parity");

        s.syna.mint(address(s.trader), 50_000);
        s.trader.sell(s.a, 50_000);
        uint256 pLow = s.a.pricePpm();
        _assertTrue(pLow < 1_000_000, "SELL lowers price");
        s.cb.resetHardPool(s.a);
        _assertNear(s.a.pricePpm(), 1_000_000, 30, "SELL reset parity");

        uint256 hard1 = s.cb.hardUsdt();
        _assertTrue(hard1 > hard0, "external balanced flow adds hard value");
        emit log_named_uint("hard USDT before micro", hard0);
        emit log_named_uint("hard USDT after BUY+SELL micro", hard1);
        emit log_named_uint("hard delta micro", hard1 - hard0);
    }

    function _deploySystem() internal returns (System memory s) {
        s.syna = new ResearchToken6("SYNA", "SYNA");
        s.synr = new ResearchToken6("SYNR", "SYNR");
        s.a = new Fixed5050CPMM6(address(s.syna), USDT, 30);
        s.b = new Fixed5050CPMM6(address(s.synr), USDT, 30);
        s.c = new Fixed5050CPMM6(address(s.syna), address(s.synr), 30);
        s.cb = new AICBControllerV2(USDT, s.syna, s.synr, s.a, s.b, s.c);
        s.trader = new ExternalTrader6();

        s.syna.setMinter(address(s.cb), true);
        s.synr.setMinter(address(s.cb), true);
        s.a.setStabilizer(address(s.cb));
        s.b.setStabilizer(address(s.cb));
        s.c.setStabilizer(address(s.cb));

        s.syna.mint(address(this), 100_000);
        s.synr.mint(address(this), 100_000);
        address(s.syna).forceApprove(address(s.a), 50_000);
        USDT.forceApprove(address(s.a), 50_000);
        s.a.addLiquidity(50_000, 50_000);
        address(s.synr).forceApprove(address(s.b), 50_000);
        USDT.forceApprove(address(s.b), 50_000);
        s.b.addLiquidity(50_000, 50_000);
        address(s.syna).forceApprove(address(s.c), 50_000);
        address(s.synr).forceApprove(address(s.c), 50_000);
        s.c.addLiquidity(50_000, 50_000);

        // 0.100000 initial AICB asset + 0.404160 realized external arb profit.
        // V2 keeps it in-system but reserve-first; adaptive LP reinvest starts only above solvency coverage.
        USDT.forceApprove(address(s.cb), 504_160);
        s.cb.depositExternalCapital(504_160, 0);
    }

    function _fund(address token, address to, uint256 amount) internal {
        vm.prank(FUNDING_WHALE);
        token.safeTransfer(to, amount);
    }

    function _fork() internal {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", "https://ethereum-rpc.publicnode.com");
        vm.createSelectFork(rpc, FORK_BLOCK);
    }

    function _assertTrue(bool v, string memory why) internal pure { require(v, why); }
    function _assertEq(uint256 a, uint256 b, string memory why) internal pure { require(a == b, why); }
    function _assertNear(uint256 a, uint256 b, uint256 tol, string memory why) internal pure {
        uint256 d = a >= b ? a - b : b - a;
        require(d <= tol, why);
    }
}
