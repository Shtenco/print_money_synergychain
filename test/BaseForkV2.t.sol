// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {BasePinnedPoolGradientAdapter} from "../contracts/economics/BasePinnedPoolGradientAdapter.sol";
import {
    BaseQEExternalExecutor,
    IBaseQEGradientAdapter,
    IBaseMessengerForQE
} from "../contracts/economics/BaseQEExternalExecutor.sol";

interface Vm {
    function deal(address who, uint256 newBalance) external;
    function warp(uint256 newTimestamp) external;
}

interface IWETH9 {
    function deposit() external payable;
    function transfer(address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
}

interface IERC20Fork {
    function transfer(address to, uint256 value) external returns (bool);
}

interface ISwapRouter02Fork {
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

contract ForkMockMessenger {
    address private remoteSender;
    uint256 private sourceChain;

    address public lastTarget;
    bytes public lastMessage;
    uint256 public sentCount;

    function sendMessage(address target, bytes calldata message, uint32) external payable {
        require(msg.value == 0, "NO_VALUE");
        lastTarget = target;
        lastMessage = message;
        sentCount++;
    }

    function xDomainMessageSender() external view returns (address) { return remoteSender; }
    function xDomainSourceChainId() external view returns (uint256) { return sourceChain; }

    function relay(address target, address sender, uint256 chainId, bytes calldata data) external {
        remoteSender = sender;
        sourceChain = chainId;
        (bool ok, bytes memory reason) = target.call(data);
        remoteSender = address(0);
        sourceChain = 0;
        require(ok, string(reason));
    }
}

contract BaseForkV2Test {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;

    function _seedExecutor(BaseQEExternalExecutor executor) internal {
        vm.deal(address(this), 20 ether);
        IWETH9(WETH).deposit{value: 10 ether}();
        require(IWETH9(WETH).approve(ROUTER, type(uint256).max), "WETH_APPROVE");

        uint256 usdcOut = ISwapRouter02Fork(ROUTER).exactInputSingle(
            ISwapRouter02Fork.ExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: USDC,
                fee: 3000,
                recipient: address(this),
                amountIn: 5 ether,
                amountOutMinimum: 1,
                sqrtPriceLimitX96: 0
            })
        );
        require(usdcOut > 5_000e6, "USDC_SEED_TOO_SMALL");

        require(IERC20Fork(USDC).transfer(address(executor), usdcOut / 2), "USDC_TRANSFER");
        require(IWETH9(WETH).transfer(address(executor), 2 ether), "WETH_TRANSFER");
    }

    function _deploy()
        internal
        returns (ForkMockMessenger messenger, BasePinnedPoolGradientAdapter adapter, BaseQEExternalExecutor executor)
    {
        require(block.chainid == 8453, "RUN_WITH_BASE_FORK");
        messenger = new ForkMockMessenger();
        adapter = new BasePinnedPoolGradientAdapter(address(this), 50);
        address sinergyController = address(0x51A7);
        executor = new BaseQEExternalExecutor(
            address(this),
            IBaseMessengerForQE(address(messenger)),
            sinergyController,
            IBaseQEGradientAdapter(address(adapter))
        );
        adapter.setExecutor(address(executor));
        _seedExecutor(executor);
    }

    function testBaseForkPositiveQEOpenCloseCannotManufactureCanonicalGain() external {
        (ForkMockMessenger messenger, BasePinnedPoolGradientAdapter adapter, BaseQEExternalExecutor executor) = _deploy();
        address sinergyController = address(0x51A7);

        bytes memory open = abi.encodeCall(
            BaseQEExternalExecutor.onQEIntent,
            (
                1,
                int32(1_000),
                uint16(2_500),
                uint128(5_000e6),
                uint128(0),
                adapter.venueSetHash(),
                uint64(block.timestamp + 30 minutes)
            )
        );
        messenger.relay(address(executor), sinergyController, 8_453_001, open);
        (bool open1,,,,,) = adapter.positions(1);
        require(open1, "NOT_OPEN");

        (bool closeOk,) = address(executor).call(abi.encodeCall(BaseQEExternalExecutor.closeQEIntent, (1)));
        require(!closeOk, "SAME_STATE_ROUNDTRIP_SHOULD_NOT_PASS");
        (bool stillOpen1,,,,,) = adapter.positions(1);
        require(stillOpen1, "REVERT_MUST_KEEP_OPEN");

        vm.warp(block.timestamp + 31 minutes);
        executor.forceUnwindExpired(1);
        (bool closed1,,,,,) = adapter.positions(1);
        require(!closed1, "NOT_FORCED_UNWOUND");
        require(executor.cumulativeForcedCanonicalLossUsdc6() > 0, "LOSS_NOT_RECORDED");
        require(messenger.sentCount() == 1, "SETTLEMENT_NOT_SENT");
    }

    function testBaseForkNegativeQEOpenCloseCannotManufactureCanonicalGain() external {
        (ForkMockMessenger messenger, BasePinnedPoolGradientAdapter adapter, BaseQEExternalExecutor executor) = _deploy();
        address sinergyController = address(0x51A7);

        bytes memory open = abi.encodeCall(
            BaseQEExternalExecutor.onQEIntent,
            (
                2,
                int32(-1_000),
                uint16(2_500),
                uint128(5_000e6),
                uint128(0),
                adapter.venueSetHash(),
                uint64(block.timestamp + 30 minutes)
            )
        );
        messenger.relay(address(executor), sinergyController, 8_453_001, open);
        (bool open2,,,,,) = adapter.positions(2);
        require(open2, "NOT_OPEN");

        (bool closeOk,) = address(executor).call(abi.encodeCall(BaseQEExternalExecutor.closeQEIntent, (2)));
        require(!closeOk, "SAME_STATE_ROUNDTRIP_SHOULD_NOT_PASS");
        (bool stillOpen2,,,,,) = adapter.positions(2);
        require(stillOpen2, "REVERT_MUST_KEEP_OPEN");

        vm.warp(block.timestamp + 31 minutes);
        executor.forceUnwindExpired(2);
        (bool closed2,,,,,) = adapter.positions(2);
        require(!closed2, "NOT_FORCED_UNWOUND");
        require(executor.cumulativeForcedCanonicalLossUsdc6() > 0, "LOSS_NOT_RECORDED");
    }
}
