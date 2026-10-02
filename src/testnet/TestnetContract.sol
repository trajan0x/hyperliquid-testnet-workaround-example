// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HyperCoreFunding} from "../HyperCoreFunding.sol";
import {MainnetContract} from "../MainnetContract.sol";
import {TestnetFunding, IDepositFactory} from "./TestnetFunding.sol";

/// @title TestnetContract
/// @notice The production MainnetContract plus the TESTNET-ONLY TestnetFunding mixin.
///         Deployed lazily by TestnetDepositFactory with CREATE2 (salt = user), so HyperCore can
///         receive funds at the counterfactual address before any code exists.
///         Constructor args are chain-independent on purpose: the same initcode yields the same
///         address on HyperEVM testnet and mainnet (see README, "mainnet replica").
contract TestnetContract is MainnetContract, TestnetFunding {
    constructor(address user_) MainnetContract(user_) TestnetFunding(IDepositFactory(msg.sender)) {}

    function _beforeCoreAction(uint64 costWei) internal override(HyperCoreFunding, TestnetFunding) {
        TestnetFunding._beforeCoreAction(costWei);
    }

    function _hypeSpotAsset() internal view override(MainnetContract, TestnetFunding) returns (uint32) {
        return TestnetFunding._hypeSpotAsset();
    }
}
