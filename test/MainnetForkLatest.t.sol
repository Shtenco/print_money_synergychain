// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {SafeToken, IERC20Minimal} from "../src/v2/SafeToken.sol";
import {ResearchToken6} from "../src/v2/ResearchToken6.sol";
import {Fixed5050CPMM6} from "../src/v2/Fixed5050CPMM6.sol";
import {AICBControllerV2} from "../src/v2/AICBControllerV2.sol";
import {ExternalTrader6} from "../src/v2/ExternalTrader6.sol";
import {AaveUniV3FlashProbe, IAavePoolV3} from "../src/v2/AaveUniV3FlashProbe.sol";

interface VmLatest {
    function envOr(string calldata key, string calldata defaultValue) external returns (string memory value);
    function createSelectFork(string calldata urlOrAlias) external returns (uint256 forkId);
    function prank(address msgSender) external;
}
interface IUniV3PoolLatest {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);
}
interface IChainlinkLatest {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

contract MainnetForkLatestTest {
    using SafeToken for address;
    VmLatest constant vm = VmLatest(address(uint160(uint256(keccak256("hevm cheat code")))));

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant UNI_POOL = 0x3416cF6C708Da44DB2624D63ea0AAef7113527C6;
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant FUNDING_WHALE = 0x28C6c06298d514Db089934071355E5743bf21d60;
    uint256 constant MICRO = 1e6;

    event log_named_uint(string key, uint256 val);

    struct S {
        ResearchToken6 syna;
        ResearchToken6 synr;
        Fixed5050CPMM6 a;
        Fixed5050CPMM6 b;
        Fixed5050CPMM6 c;
        AICBControllerV2 cb;
        ExternalTrader6 trader;
    }

    function testLatestMainnetReferences() external {
        _fork();
        require(USDC.code.length > 0 && USDT.code.length > 0 && AAVE_POOL.code.length > 0 && UNI_POOL.code.length > 0, "missing mainnet code");
        IUniV3PoolLatest p = IUniV3PoolLatest(UNI_POOL);
        require(p.token0() == USDC && p.token1() == USDT && p.fee() == 100 && p.liquidity() > 0, "wrong real pool");
        uint256 premiumBps = IAavePoolV3(AAVE_POOL).FLASHLOAN_PREMIUM_TOTAL();
        (, int256 ethUsd,, uint256 updatedAt,) = IChainlinkLatest(ETH_USD).latestRoundData();
        require(premiumBps > 0 && ethUsd > 0 && updatedAt > 0, "missing live economics");
        emit log_named_uint("fork block", block.number);
        emit log_named_uint("fork basefee wei", block.basefee);
        emit log_named_uint("Aave flash premium bps", premiumBps);
        emit log_named_uint("Uniswap V3 liquidity", p.liquidity());
        emit log_named_uint("ETH/USD 8 decimals", uint256(ethUsd));
    }

    function testLatestRealFlashAndV3Friction() external {
        _fork();
        AaveUniV3FlashProbe probe = new AaveUniV3FlashProbe();
        _fund(USDC, address(probe), 200 * MICRO);
        uint256 beforeBal = IERC20Minimal(USDC).balanceOf(address(probe));
        uint256 g0 = gasleft();
        uint256 netCost = probe.run(10_000 * MICRO);
        uint256 gasUsed = g0 - gasleft();
        uint256 afterBal = IERC20Minimal(USDC).balanceOf(address(probe));
        require(probe.lastPremium() > 0, "no Aave premium");
        require(probe.lastUsdtOut() > 0 && probe.lastUsdcBack() > 0, "real V3 swap failed");
        require(netCost > 0 && beforeBal - afterBal == netCost && afterBal > 0, "flash repayment/friction");
        emit log_named_uint("flash roundtrip net cost USDC micro", netCost);
        emit log_named_uint("flash premium USDC micro", probe.lastPremium());
        emit log_named_uint("flash+2swap gas used", gasUsed);
    }

    function testLatestRealUSDTExactReset() external {
        _fork();
        _fund(USDT, address(this), 20 * MICRO);
        S memory s = _deploy();
        uint256 hard0 = s.cb.hardUsdt();
        require(hard0 == 604_160, "bootstrap hard USDT");

        USDT.safeTransfer(address(s.trader), 50_000);
        uint256 g0 = gasleft();
        s.trader.buy(s.a, 50_000);
        uint256 buyGas = g0 - gasleft();
        require(s.a.pricePpm() > 1_000_000, "BUY no excursion");
        g0 = gasleft();
        s.cb.resetHardPool(s.a);
        uint256 buyResetGas = g0 - gasleft();
        _near(s.a.pricePpm(), 1_000_000, 30);

        s.syna.mint(address(s.trader), 50_000);
        g0 = gasleft();
        s.trader.sell(s.a, 50_000);
        uint256 sellGas = g0 - gasleft();
        require(s.a.pricePpm() < 1_000_000, "SELL no excursion");
        g0 = gasleft();
        s.cb.resetHardPool(s.a);
        uint256 sellResetGas = g0 - gasleft();
        _near(s.a.pricePpm(), 1_000_000, 30);

        uint256 hard1 = s.cb.hardUsdt();
        require(hard1 > hard0, "balanced external flow did not add hard value");
        emit log_named_uint("hard USDT before micro", hard0);
        emit log_named_uint("hard USDT after micro", hard1);
        emit log_named_uint("hard delta micro", hard1 - hard0);
        emit log_named_uint("external BUY gas", buyGas);
        emit log_named_uint("AICB BUY reset gas", buyResetGas);
        emit log_named_uint("external SELL gas", sellGas);
        emit log_named_uint("AICB SELL reset gas", sellResetGas);
    }

    function _deploy() internal returns (S memory s) {
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
        address(s.syna).forceApprove(address(s.a), 50_000); USDT.forceApprove(address(s.a), 50_000); s.a.addLiquidity(50_000, 50_000);
        address(s.synr).forceApprove(address(s.b), 50_000); USDT.forceApprove(address(s.b), 50_000); s.b.addLiquidity(50_000, 50_000);
        address(s.syna).forceApprove(address(s.c), 50_000); address(s.synr).forceApprove(address(s.c), 50_000); s.c.addLiquidity(50_000, 50_000);
        USDT.forceApprove(address(s.cb), 504_160); s.cb.depositExternalCapital(504_160, 0);
    }

    function _fund(address token, address to, uint256 amount) internal {
        vm.prank(FUNDING_WHALE);
        token.safeTransfer(to, amount);
    }
    function _fork() internal {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", "https://ethereum-rpc.publicnode.com");
        vm.createSelectFork(rpc);
    }
    function _near(uint256 a, uint256 b, uint256 tol) internal pure {
        uint256 d = a > b ? a-b : b-a;
        require(d <= tol, "parity tolerance");
    }
}
