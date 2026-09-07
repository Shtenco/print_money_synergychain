// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MintableToken} from "./MintableToken.sol";
import {Fixed5050CPMM} from "./Fixed5050CPMM.sol";

/// @notice Simple external actor used by the EVM integration test.
contract Trader {
    function approveMax(MintableToken token, address spender) external {
        token.approve(spender, type(uint256).max);
    }

    function buy(Fixed5050CPMM pool, uint256 quoteIn) external returns (uint256) {
        return pool.swapQuoteForBase(quoteIn, 0, address(this));
    }

    function sell(Fixed5050CPMM pool, uint256 baseIn) external returns (uint256) {
        return pool.swapBaseForQuote(baseIn, 0, address(this));
    }
}
