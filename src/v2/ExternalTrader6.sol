// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {SafeToken} from "./SafeToken.sol";
import {Fixed5050CPMM6} from "./Fixed5050CPMM6.sol";

/// @notice Simple external-flow actor. It receives hard USDT or endogenous base from the test/faucet and pays normal AMM fees.
contract ExternalTrader6 {
    using SafeToken for address;

    function buy(Fixed5050CPMM6 pool, uint256 quoteIn) external returns (uint256) {
        pool.quote().forceApprove(address(pool), quoteIn);
        return pool.swapQuoteForBase(quoteIn, 0, address(this));
    }

    function sell(Fixed5050CPMM6 pool, uint256 baseIn) external returns (uint256) {
        pool.base().forceApprove(address(pool), baseIn);
        return pool.swapBaseForQuote(baseIn, 0, address(this));
    }
}
