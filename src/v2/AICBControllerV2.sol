// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {SafeToken, IERC20Minimal} from "./SafeToken.sol";
import {ResearchToken6} from "./ResearchToken6.sol";
import {Fixed5050CPMM6} from "./Fixed5050CPMM6.sol";

/// @notice V2 exact-reset AICB using real six-decimal USDT as the only hard asset.
/// @dev The controller can mint/burn SYNA/SYNR, never USDT. Hard accounting is therefore externally auditable.
contract AICBControllerV2 {
    using SafeToken for address;
    uint256 public constant BPS = 10_000;

    address public immutable usdt;
    ResearchToken6 public immutable syna;
    ResearchToken6 public immutable synr;
    Fixed5050CPMM6 public immutable synaUsdt;
    Fixed5050CPMM6 public immutable synrUsdt;
    Fixed5050CPMM6 public immutable synaSynr;
    address public owner;
    uint256 public totalExternalCapital;
    uint256 public totalHardReinvested;

    error Unauthorized();
    error WrongPool();
    error InvalidBps();
    error InsufficientHardReserve();

    event ExternalCapitalDeposited(uint256 amount, uint256 lpPart, uint256 reservePart);
    event HardReset(address indexed pool, uint256 priceBeforePpm, uint256 priceAfterPpm, int256 reserveDelta);
    event InternalReset(uint256 priceBeforePpm, uint256 priceAfterPpm);
    event HardReinvested(uint256 amount);

    constructor(
        address usdt_, ResearchToken6 syna_, ResearchToken6 synr_,
        Fixed5050CPMM6 synaUsdt_, Fixed5050CPMM6 synrUsdt_, Fixed5050CPMM6 synaSynr_
    ) {
        usdt = usdt_;
        syna = syna_;
        synr = synr_;
        synaUsdt = synaUsdt_;
        synrUsdt = synrUsdt_;
        synaSynr = synaSynr_;
        owner = msg.sender;
    }

    modifier onlyOwner() { if (msg.sender != owner) revert Unauthorized(); _; }

    function depositExternalCapital(uint256 amount, uint256 lpBps) external onlyOwner {
        if (lpBps > BPS) revert InvalidBps();
        usdt.safeTransferFrom(msg.sender, address(this), amount);
        uint256 lpPart = amount * lpBps / BPS;
        uint256 perPool = lpPart / 2;
        uint256 actuallyInvested = perPool * 2;
        _addHardLiquidity(synaUsdt, syna, perPool);
        _addHardLiquidity(synrUsdt, synr, perPool);
        totalExternalCapital += amount;
        totalHardReinvested += actuallyInvested;
        emit ExternalCapitalDeposited(amount, actuallyInvested, amount - actuallyInvested);
    }

    function reinvestHard(uint256 amount) external onlyOwner {
        if (IERC20Minimal(usdt).balanceOf(address(this)) < amount) revert InsufficientHardReserve();
        uint256 perPool = amount / 2;
        uint256 actual = perPool * 2;
        _addHardLiquidity(synaUsdt, syna, perPool);
        _addHardLiquidity(synrUsdt, synr, perPool);
        totalHardReinvested += actual;
        emit HardReinvested(actual);
    }

    function resetHardPool(Fixed5050CPMM6 pool) external onlyOwner {
        ResearchToken6 baseToken;
        if (address(pool) == address(synaUsdt)) baseToken = syna;
        else if (address(pool) == address(synrUsdt)) baseToken = synr;
        else revert WrongPool();

        uint256 beforeP = pool.pricePpm();
        uint256 cbBefore = IERC20Minimal(usdt).balanceOf(address(this));
        uint256 x = pool.reserveBase();
        uint256 y = pool.reserveQuote();

        if (y > x) {
            uint256 baseIn = _bestInput(pool, x, y);
            if (baseIn != 0) {
                baseToken.mint(address(this), baseIn);
                address(baseToken).forceApprove(address(pool), baseIn);
                pool.swapBaseForQuote(baseIn, 0, address(this));
            }
        } else if (x > y) {
            uint256 quoteIn = _bestInput(pool, y, x);
            if (IERC20Minimal(usdt).balanceOf(address(this)) < quoteIn) revert InsufficientHardReserve();
            if (quoteIn != 0) {
                usdt.forceApprove(address(pool), quoteIn);
                uint256 baseOut = pool.swapQuoteForBase(quoteIn, 0, address(this));
                baseToken.burn(baseOut);
            }
        }

        uint256 cbAfter = IERC20Minimal(usdt).balanceOf(address(this));
        int256 d = cbAfter >= cbBefore ? int256(cbAfter - cbBefore) : -int256(cbBefore - cbAfter);
        emit HardReset(address(pool), beforeP, pool.pricePpm(), d);
    }

    function resetInternalPool() external onlyOwner {
        uint256 beforeP = synaSynr.pricePpm();
        uint256 x = synaSynr.reserveBase();
        uint256 y = synaSynr.reserveQuote();
        if (y > x) {
            uint256 inBase = _bestInput(synaSynr, x, y);
            syna.mint(address(this), inBase);
            address(syna).forceApprove(address(synaSynr), inBase);
            synaSynr.swapBaseForQuote(inBase, 0, address(this));
        } else if (x > y) {
            uint256 inQuote = _bestInput(synaSynr, y, x);
            synr.mint(address(this), inQuote);
            address(synr).forceApprove(address(synaSynr), inQuote);
            uint256 outBase = synaSynr.swapQuoteForBase(inQuote, 0, address(this));
            syna.burn(outBase);
        }
        emit InternalReset(beforeP, synaSynr.pricePpm());
    }

    function hardUsdt() external view returns (uint256) {
        return IERC20Minimal(usdt).balanceOf(address(this)) + synaUsdt.reserveQuote() + synrUsdt.reserveQuote();
    }

    function aicbReserveUsdt() external view returns (uint256) {
        return IERC20Minimal(usdt).balanceOf(address(this));
    }

    function hardLpUsdt() external view returns (uint256) {
        return synaUsdt.reserveQuote() + synrUsdt.reserveQuote();
    }

    function resetQuoteCost(Fixed5050CPMM6 pool, uint256 baseSell) external view returns (uint256) {
        uint256 x = pool.reserveBase();
        uint256 y = pool.reserveQuote();
        uint256 quoteOut = pool.amountOut(baseSell, x, y); // external seller pays normal fee
        uint256 x1 = x + baseSell;
        uint256 y1 = y - quoteOut;
        return _bestInput(pool, y1, x1); // AICB reset is fee-exempt
    }

    function _addHardLiquidity(Fixed5050CPMM6 pool, ResearchToken6 baseToken, uint256 q) internal {
        if (q == 0) return;
        baseToken.mint(address(this), q);
        address(baseToken).forceApprove(address(pool), q);
        usdt.forceApprove(address(pool), q);
        pool.addLiquidity(q, q);
    }

    function _bestInput(Fixed5050CPMM6 pool, uint256 rin, uint256 rout) internal view returns (uint256) {
        if (rout <= rin) return 0;
        uint256 m = BPS;
        uint256 c = BPS - pool.effectiveFeeBps(address(this));
        uint256 b = (m + c) * rin;
        uint256 disc = b * b + 4 * c * m * rin * (rout - rin);
        uint256 root = _sqrt(disc);
        uint256 a = root > b ? (root - b) / (2 * c) : 0;
        if (a == 0) a = 1;
        uint256 d0 = _parityError(pool, rin, rout, a);
        uint256 d1 = _parityError(pool, rin, rout, a + 1);
        return d1 < d0 ? a + 1 : a;
    }

    function _parityError(Fixed5050CPMM6 pool, uint256 rin, uint256 rout, uint256 a) internal view returns (uint256) {
        uint256 out = pool.amountOutFor(address(this), a, rin, rout);
        uint256 lhs = rin + a;
        uint256 rhs = rout - out;
        return lhs >= rhs ? lhs - rhs : rhs - lhs;
    }

    function _sqrt(uint256 a) internal pure returns (uint256 z) {
        if (a == 0) return 0;
        z = a;
        uint256 x = a / 2 + 1;
        while (x < z) { z = x; x = (a / x + x) / 2; }
    }
}
