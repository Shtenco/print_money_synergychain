// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MintableToken} from "./MintableToken.sol";

/// @notice Fee-free x*y=k research AMM. Both assets use 18 decimals in this prototype.
/// @dev The pool intentionally has no LP shares: it is a deterministic economics harness.
contract Fixed5050CPMM {
    uint256 public constant WAD = 1e18;

    MintableToken public immutable base;
    MintableToken public immutable quote;
    uint256 public reserveBase;
    uint256 public reserveQuote;

    error ZeroAmount();
    error EmptyPool();
    error Slippage();

    event LiquidityAdded(address indexed provider, uint256 baseIn, uint256 quoteIn);
    event SwapQuoteForBase(address indexed caller, uint256 quoteIn, uint256 baseOut, address indexed to);
    event SwapBaseForQuote(address indexed caller, uint256 baseIn, uint256 quoteOut, address indexed to);

    constructor(MintableToken base_, MintableToken quote_) {
        base = base_;
        quote = quote_;
    }

    function addLiquidity(uint256 baseIn, uint256 quoteIn) external {
        if (baseIn == 0 || quoteIn == 0) revert ZeroAmount();
        base.transferFrom(msg.sender, address(this), baseIn);
        quote.transferFrom(msg.sender, address(this), quoteIn);
        reserveBase += baseIn;
        reserveQuote += quoteIn;
        emit LiquidityAdded(msg.sender, baseIn, quoteIn);
    }

    /// @notice BUY base with quote, no fee.
    function swapQuoteForBase(uint256 quoteIn, uint256 minBaseOut, address to) external returns (uint256 baseOut) {
        if (quoteIn == 0) revert ZeroAmount();
        uint256 x = reserveBase;
        uint256 y = reserveQuote;
        if (x == 0 || y == 0) revert EmptyPool();

        // Standard zero-fee CPMM amountOut. Rounding down makes k non-decreasing.
        baseOut = (x * quoteIn) / (y + quoteIn);
        if (baseOut < minBaseOut || baseOut == 0) revert Slippage();

        quote.transferFrom(msg.sender, address(this), quoteIn);
        base.transfer(to, baseOut);
        reserveQuote = y + quoteIn;
        reserveBase = x - baseOut;
        emit SwapQuoteForBase(msg.sender, quoteIn, baseOut, to);
    }

    /// @notice SELL base for quote, no fee.
    function swapBaseForQuote(uint256 baseIn, uint256 minQuoteOut, address to) external returns (uint256 quoteOut) {
        if (baseIn == 0) revert ZeroAmount();
        uint256 x = reserveBase;
        uint256 y = reserveQuote;
        if (x == 0 || y == 0) revert EmptyPool();

        quoteOut = (y * baseIn) / (x + baseIn);
        if (quoteOut < minQuoteOut || quoteOut == 0) revert Slippage();

        base.transferFrom(msg.sender, address(this), baseIn);
        quote.transfer(to, quoteOut);
        reserveBase = x + baseIn;
        reserveQuote = y - quoteOut;
        emit SwapBaseForQuote(msg.sender, baseIn, quoteOut, to);
    }

    function priceWad() external view returns (uint256) {
        if (reserveBase == 0) revert EmptyPool();
        return (reserveQuote * WAD) / reserveBase;
    }

    function k() external view returns (uint256) {
        return reserveBase * reserveQuote;
    }
}
