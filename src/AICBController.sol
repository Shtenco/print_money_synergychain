// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MintableToken} from "./MintableToken.sol";
import {Fixed5050CPMM} from "./Fixed5050CPMM.sol";

/// @notice Deterministic safety kernel for an off-chain AI Central Bank policy.
/// @dev The AI may decide when to call maintenance, but cannot mint hard quote (USDT).
contract AICBController {
    uint256 public constant BPS = 10_000;
    uint256 public constant WAD = 1e18;

    MintableToken public immutable usdt;
    MintableToken public immutable syna;
    MintableToken public immutable synr;
    Fixed5050CPMM public immutable synaUsdt;
    Fixed5050CPMM public immutable synrUsdt;
    Fixed5050CPMM public immutable synaSynr;

    address public owner;
    uint256 public reinvestBps = 5_132; // 51.32%
    uint256 public totalExternalArbReinvested;
    uint256 public totalMMProfit;
    uint256 public totalMMReinvested;

    bool public epochActive;
    uint256 public epochStartUsdt;

    error Unauthorized();
    error EpochAlreadyActive();
    error NoActiveEpoch();
    error EpochLoss();
    error InvalidBps();
    error WrongPool();
    error InsufficientHardReserve();

    event ExternalArbReinvested(uint256 amount, uint256 synaUsdtQuote, uint256 synrUsdtQuote);
    event HardPoolReset(address indexed pool, uint256 priceBeforeWad, uint256 priceAfterWad, int256 cbUsdtDelta);
    event InternalPoolReset(uint256 priceBeforeWad, uint256 priceAfterWad);
    event EpochStarted(uint256 controllerUsdt);
    event EpochSettled(uint256 mmProfit, uint256 reinvested, uint256 retained);
    event ReinvestBpsSet(uint256 bps);

    constructor(
        MintableToken usdt_,
        MintableToken syna_,
        MintableToken synr_,
        Fixed5050CPMM synaUsdt_,
        Fixed5050CPMM synrUsdt_,
        Fixed5050CPMM synaSynr_
    ) {
        usdt = usdt_;
        syna = syna_;
        synr = synr_;
        synaUsdt = synaUsdt_;
        synrUsdt = synrUsdt_;
        synaSynr = synaSynr_;
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    function setReinvestBps(uint256 bps) external onlyOwner {
        if (bps > BPS) revert InvalidBps();
        reinvestBps = bps;
        emit ReinvestBpsSet(bps);
    }

    /// @notice Inject already-realized external arb profit and reinvest 100% into the two hard pools.
    /// @dev This function does NOT create USDT; caller must transfer genuine quote into the controller.
    function bootstrapExternalArbProfit(uint256 amount) external onlyOwner {
        usdt.transferFrom(msg.sender, address(this), amount);
        uint256 a = amount / 2;
        uint256 b = amount - a;
        _addHardLiquidity(synaUsdt, syna, a);
        _addHardLiquidity(synrUsdt, synr, b);
        totalExternalArbReinvested += amount;
        emit ExternalArbReinvested(amount, a, b);
    }

    function beginEpoch() external onlyOwner {
        if (epochActive) revert EpochAlreadyActive();
        epochActive = true;
        epochStartUsdt = usdt.balanceOf(address(this));
        emit EpochStarted(epochStartUsdt);
    }

    /// @notice Reset either hard pool toward quote/base = 1 using actual swaps.
    /// @dev If price is high, mint base and sell it. If price is low, spend real USDT to buy base and burn it.
    function resetHardPool(Fixed5050CPMM pool) public onlyOwner {
        MintableToken baseToken;
        if (address(pool) == address(synaUsdt)) baseToken = syna;
        else if (address(pool) == address(synrUsdt)) baseToken = synr;
        else revert WrongPool();

        uint256 beforePrice = pool.priceWad();
        uint256 cbBefore = usdt.balanceOf(address(this));
        uint256 x = pool.reserveBase();
        uint256 y = pool.reserveQuote();
        uint256 target = _sqrt(x * y);

        if (y > x) {
            // Price > 1: mint base, sell high, collect hard quote.
            uint256 baseIn = target > x ? target - x : 0;
            if (baseIn > 0) {
                baseToken.mint(address(this), baseIn);
                baseToken.approve(address(pool), baseIn);
                pool.swapBaseForQuote(baseIn, 0, address(this));
            }
        } else if (x > y) {
            // Price < 1: buy base with genuine hard quote and burn acquired inventory.
            uint256 quoteIn = target > y ? target - y : 0;
            if (quoteIn > 0) {
                if (usdt.balanceOf(address(this)) < quoteIn) revert InsufficientHardReserve();
                usdt.approve(address(pool), quoteIn);
                uint256 baseOut = pool.swapQuoteForBase(quoteIn, 0, address(this));
                baseToken.burn(baseOut);
            }
        }

        uint256 afterPrice = pool.priceWad();
        uint256 cbAfter = usdt.balanceOf(address(this));
        int256 delta = cbAfter >= cbBefore
            ? int256(cbAfter - cbBefore)
            : -int256(cbBefore - cbAfter);
        emit HardPoolReset(address(pool), beforePrice, afterPrice, delta);
    }

    /// @notice Reset the internal SYNA/SYNR leg. No value from this leg is counted as hard USDT.
    /// @dev Both tokens are endogenous, so SYNR needed for a downward reset may be minted.
    function resetInternalPool() external onlyOwner {
        uint256 beforePrice = synaSynr.priceWad();
        uint256 x = synaSynr.reserveBase();
        uint256 y = synaSynr.reserveQuote();
        uint256 target = _sqrt(x * y);

        if (y > x) {
            uint256 baseIn = target > x ? target - x : 0;
            if (baseIn > 0) {
                syna.mint(address(this), baseIn);
                syna.approve(address(synaSynr), baseIn);
                synaSynr.swapBaseForQuote(baseIn, 0, address(this));
            }
        } else if (x > y) {
            uint256 quoteIn = target > y ? target - y : 0;
            if (quoteIn > 0) {
                synr.mint(address(this), quoteIn);
                synr.approve(address(synaSynr), quoteIn);
                uint256 baseOut = synaSynr.swapQuoteForBase(quoteIn, 0, address(this));
                syna.burn(baseOut);
            }
        }
        emit InternalPoolReset(beforePrice, synaSynr.priceWad());
    }

    /// @notice Split positive hard-USDT MM PnL: reinvest 51.32%, retain 48.68% by default.
    function settleEpoch() external onlyOwner returns (uint256 profit, uint256 reinvested, uint256 retained) {
        if (!epochActive) revert NoActiveEpoch();
        uint256 bal = usdt.balanceOf(address(this));
        if (bal < epochStartUsdt) revert EpochLoss();

        profit = bal - epochStartUsdt;
        uint256 requestedReinvest = (profit * reinvestBps) / BPS;

        // Add exactly the same hard quote to both pools. Odd-wei dust stays in AICB.
        uint256 perPool = requestedReinvest / 2;
        reinvested = 2 * perPool;
        _addHardLiquidity(synaUsdt, syna, perPool);
        _addHardLiquidity(synrUsdt, synr, perPool);

        retained = profit - reinvested;
        totalMMProfit += profit;
        totalMMReinvested += reinvested;
        epochActive = false;
        emit EpochSettled(profit, reinvested, retained);
    }

    function hardUsdt() external view returns (uint256) {
        return usdt.balanceOf(address(this)) + synaUsdt.reserveQuote() + synrUsdt.reserveQuote();
    }

    function hardLpUsdt() external view returns (uint256) {
        return synaUsdt.reserveQuote() + synrUsdt.reserveQuote();
    }

    function aicbReserveUsdt() external view returns (uint256) {
        return usdt.balanceOf(address(this));
    }

    function _addHardLiquidity(Fixed5050CPMM pool, MintableToken baseToken, uint256 quoteAmount) internal {
        if (quoteAmount == 0) return;
        // Pools are maintained at parity, therefore equal nominal base keeps 50/50 value weights at P=1.
        baseToken.mint(address(this), quoteAmount);
        baseToken.approve(address(pool), quoteAmount);
        usdt.approve(address(pool), quoteAmount);
        pool.addLiquidity(quoteAmount, quoteAmount);
    }

    /// @dev Babylonian integer sqrt, floor(sqrt(a)).
    function _sqrt(uint256 a) internal pure returns (uint256) {
        if (a == 0) return 0;
        uint256 x = 1 << (_log2(a) >> 1);
        unchecked {
            // Seven Newton steps are sufficient for a 256-bit integer from this power-of-two seed.
            for (uint256 i = 0; i < 7; ++i) x = (x + a / x) >> 1;
            uint256 y = a / x;
            return x < y ? x : y;
        }
    }

    function _log2(uint256 x) internal pure returns (uint256 r) {
        unchecked {
            if (x >> 128 > 0) { x >>= 128; r += 128; }
            if (x >> 64 > 0) { x >>= 64; r += 64; }
            if (x >> 32 > 0) { x >>= 32; r += 32; }
            if (x >> 16 > 0) { x >>= 16; r += 16; }
            if (x >> 8 > 0) { x >>= 8; r += 8; }
            if (x >> 4 > 0) { x >>= 4; r += 4; }
            if (x >> 2 > 0) { x >>= 2; r += 2; }
            if (x >> 1 > 0) r += 1;
        }
    }
}
