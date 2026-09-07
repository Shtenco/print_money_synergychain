// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

interface IERC20Minimal {
    function balanceOf(address) external view returns (uint256);
    function allowance(address,address) external view returns (uint256);
}

library SafeToken {
    error TokenCallFailed();

    function safeTransfer(address token, address to, uint256 amount) internal {
        _call(token, abi.encodeWithSelector(bytes4(keccak256("transfer(address,uint256)")), to, amount));
    }

    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        _call(token, abi.encodeWithSelector(bytes4(keccak256("transferFrom(address,address,uint256)")), from, to, amount));
    }

    function safeApprove(address token, address spender, uint256 amount) internal {
        _call(token, abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)")), spender, amount));
    }

    function forceApprove(address token, address spender, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)")), spender, amount));
        if (ok && (data.length == 0 || abi.decode(data, (bool)))) return;
        _call(token, abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)")), spender, 0));
        _call(token, abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)")), spender, amount));
    }

    function _call(address token, bytes memory payload) private {
        (bool ok, bytes memory data) = token.call(payload);
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TokenCallFailed();
    }
}
