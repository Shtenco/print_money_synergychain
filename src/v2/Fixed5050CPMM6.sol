// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {SafeToken} from "./SafeToken.sol";

/// @notice x*y=k 50/50 research AMM using same-decimal assets and explicit input fee.
contract Fixed5050CPMM6 {
    using SafeToken for address;
    uint256 public constant BPS = 10_000;
    uint256 public constant PPM = 1_000_000;

    address public immutable base;
    address public immutable quote;
    uint256 public immutable feeBps;
    uint256 public reserveBase;
    uint256 public reserveQuote;

    error InvalidFee();
    error ZeroAmount();
    error EmptyPool();
    error Slippage();

    event LiquidityAdded(address indexed provider, uint256 baseIn, uint256 quoteIn);
    event SwapQuoteForBase(address indexed caller, uint256 quoteIn, uint256 baseOut, address indexed to);
    event SwapBaseForQuote(address indexed caller, uint256 baseIn, uint256 quoteOut, address indexed to);

    constructor(address base_, address quote_, uint256 feeBps_) {
        if (feeBps_ >= BPS) revert InvalidFee();
        base = base_;
        quote = quote_;
        feeBps = feeBps_;
    }

    function addLiquidity(uint256 baseIn, uint256 quoteIn) external {
        if (baseIn == 0 || quoteIn == 0) revert ZeroAmount();
        base.safeTransferFrom(msg.sender, address(this), baseIn);
        quote.safeTransferFrom(msg.sender, address(this), quoteIn);
        reserveBase += baseIn;
        reserveQuote += quoteIn;
        emit LiquidityAdded(msg.sender, baseIn, quoteIn);
    }

    function amountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) public view returns (uint256) {
        if (amountIn == 0 || reserveIn == 0 || reserveOut == 0) return 0;
        uint256 inAfterFee = amountIn * (BPS - feeBps);
        return (reserveOut * inAfterFee) / (reserveIn * BPS + inAfterFee);
    }

    function swapQuoteForBase(uint256 quoteIn, uint256 minBaseOut, address to) external returns (uint256 baseOut) {
        if (quoteIn == 0) revert ZeroAmount();
        uint256 x = reserveBase;
        uint256 y = reserveQuote;
        if (x == 0 || y == 0) revert EmptyPool();
        baseOut = amountOut(quoteIn, y, x);
        if (baseOut == 0 || baseOut < minBaseOut) revert Slippage();
        quote.safeTransferFrom(msg.sender, address(this), quoteIn);
        base.safeTransfer(to, baseOut);
        reserveQuote = y + quoteIn;
        reserveBase = x - baseOut;
        emit SwapQuoteForBase(msg.sender, quoteIn, baseOut, to);
    }

    function swapBaseForQuote(uint256 baseIn, uint256 minQuoteOut, address to) external returns (uint256 quoteOut) {
        if (baseIn == 0) revert ZeroAmount();
        uint256 x = reserveBase;
        uint256 y = reserveQuote;
        if (x == 0 || y == 0) revert EmptyPool();
        quoteOut = amountOut(baseIn, x, y);
        if (quoteOut == 0 || quoteOut < minQuoteOut) revert Slippage();
        base.safeTransferFrom(msg.sender, address(this), baseIn);
        quote.safeTransfer(to, quoteOut);
        reserveBase = x + baseIn;
        reserveQuote = y - quoteOut;
        emit SwapBaseForQuote(msg.sender, baseIn, quoteOut, to);
    }

    function pricePpm() external view returns (uint256) {
        if (reserveBase == 0) revert EmptyPool();
        return reserveQuote * PPM / reserveBase;
    }

    function k() external view returns (uint256) { return reserveBase * reserveQuote; }
}
