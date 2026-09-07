// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {SafeToken, IERC20Minimal} from "./SafeToken.sol";

interface IAavePoolV3 {
    function flashLoanSimple(address receiverAddress, address asset, uint256 amount, bytes calldata params, uint16 referralCode) external;
    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint128);
}

interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @notice Mainnet-fork probe: real Aave V3 USDC flash loan and real Uniswap V3 USDC/USDT 0.01% round trip.
/// @dev It intentionally does NOT claim alpha. Its purpose is to measure real flash+DEX friction that the firewall must subtract.
contract AaveUniV3FlashProbe {
    using SafeToken for address;

    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address public constant SWAP_ROUTER_02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    uint24 public constant STABLE_FEE = 100;

    address public owner;
    uint256 public lastPremium;
    uint256 public lastUsdtOut;
    uint256 public lastUsdcBack;
    uint256 public lastNetCostUsdc;

    error Unauthorized();
    error BadCallback();

    constructor() { owner = msg.sender; }

    function run(uint256 amountUsdc) external returns (uint256 netCostUsdc) {
        if (msg.sender != owner) revert Unauthorized();
        uint256 beforeBal = IERC20Minimal(USDC).balanceOf(address(this));
        IAavePoolV3(AAVE_POOL).flashLoanSimple(address(this), USDC, amountUsdc, bytes(""), 0);
        uint256 afterBal = IERC20Minimal(USDC).balanceOf(address(this));
        netCostUsdc = beforeBal > afterBal ? beforeBal - afterBal : 0;
        lastNetCostUsdc = netCostUsdc;
    }

    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata)
        external returns (bool)
    {
        if (msg.sender != AAVE_POOL || initiator != address(this) || asset != USDC) revert BadCallback();
        lastPremium = premium;
        USDC.forceApprove(SWAP_ROUTER_02, amount);
        uint256 usdtOut = ISwapRouter02(SWAP_ROUTER_02).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({tokenIn: USDC, tokenOut: USDT, fee: STABLE_FEE, recipient: address(this), amountIn: amount, amountOutMinimum: 0, sqrtPriceLimitX96: 0})
        );
        lastUsdtOut = usdtOut;
        USDT.forceApprove(SWAP_ROUTER_02, usdtOut);
        uint256 usdcBack = ISwapRouter02(SWAP_ROUTER_02).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({tokenIn: USDT, tokenOut: USDC, fee: STABLE_FEE, recipient: address(this), amountIn: usdtOut, amountOutMinimum: 0, sqrtPriceLimitX96: 0})
        );
        lastUsdcBack = usdcBack;
        USDC.forceApprove(AAVE_POOL, amount + premium);
        return true;
    }
}
