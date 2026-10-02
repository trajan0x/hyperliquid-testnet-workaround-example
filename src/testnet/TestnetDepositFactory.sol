// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TestnetContract} from "./TestnetContract.sol";
import {DepositConfig} from "./TestnetFunding.sol";
import {HyperCore} from "../lib/HyperCore.sol";

/// @title TestnetDepositFactory
/// @notice TESTNET-ONLY. CREATE2 factory for per-user deposit addresses (salt = user), and the "main contract"
///         that swept funds are credited to.
///
///         Deploy it through the deterministic CREATE2 deployer (0x4e59b44847b379578588920ca78fbf26c0b4956c,
///         present on HyperEVM testnet and mainnet) with the same salt and owner on both chains: the factory,
///         and therefore every deposit address, then has the same address on both. Per-chain values live in
///         storage via setConfig(), never in initcode.
contract TestnetDepositFactory {
    address public immutable owner;
    DepositConfig internal _config;

    /// @notice USDC Core wei credited per user. Only written after a confirmed sweep (see TestnetFunding).
    mapping(address user => uint64) public credited;

    event ConfigSet(DepositConfig config);
    event Deployed(address indexed user, address depositAddress);
    event Credited(address indexed user, uint64 amountWei);

    error NotOwner();
    error NotDepositAddress();

    constructor(address owner_) {
        owner = owner_;
    }

    function config() external view returns (DepositConfig memory) {
        return _config;
    }

    function setConfig(DepositConfig calldata cfg) external {
        if (msg.sender != owner) revert NotOwner();
        _config = cfg;
        emit ConfigSet(cfg);
    }

    function salt(address user) public pure returns (bytes32) {
        return bytes32(uint256(uint160(user)));
    }

    /// @notice Counterfactual deposit address for `user`. Core can receive funds here before deploy().
    function predict(address user) public view returns (address) {
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(TestnetContract).creationCode, abi.encode(user)));
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt(user), initCodeHash))))
            );
    }

    /// @notice Lazily deploy the deposit address for `user`. Permissionless.
    function deploy(address user) external returns (TestnetContract dep) {
        dep = new TestnetContract{salt: salt(user)}(user);
        emit Deployed(user, address(dep));
        if (block.chainid == HyperCore.CHAIN_ID_MAINNET) {
            dep.initializeReplica();
        }
    }

    /// @notice Called by a deposit address after a sweep is confirmed on Core.
    function recordCredit(address user, uint64 amountWei) external {
        if (msg.sender != predict(user) || msg.sender.code.length == 0) revert NotDepositAddress();
        credited[user] += amountWei;
        emit Credited(user, amountWei);
    }
}
