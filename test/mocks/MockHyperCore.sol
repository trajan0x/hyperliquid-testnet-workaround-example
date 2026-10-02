// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Stand-in for the spotBalance read precompile (0x...0801). Etched at that address in tests.
contract MockSpotBalancePrecompile {
    mapping(address user => mapping(uint64 token => uint64[3])) internal balances;

    function set(address user, uint64 token, uint64 total, uint64 hold) external {
        balances[user][token] = [total, hold, uint64(0)];
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        (address user, uint64 token) = abi.decode(data, (address, uint64));
        uint64[3] memory b = balances[user][token];
        return abi.encode(b[0], b[1], b[2]);
    }
}

/// @notice Stand-in for CoreWriter (0x3333...3333). Records raw actions instead of forwarding to HyperCore.
contract MockCoreWriter {
    bytes[] internal _actions;
    address[] internal _senders;

    function sendRawAction(bytes calldata data) external {
        _actions.push(data);
        _senders.push(msg.sender);
    }

    function count() external view returns (uint256) {
        return _actions.length;
    }

    function actionAt(uint256 i) external view returns (address sender, bytes memory data) {
        return (_senders[i], _actions[i]);
    }
}
