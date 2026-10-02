// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {HyperCore} from "../src/lib/HyperCore.sol";
import {MockSpotBalancePrecompile, MockCoreWriter} from "./mocks/MockHyperCore.sol";

abstract contract HyperCoreTestBase is Test {
    MockSpotBalancePrecompile internal precompile = MockSpotBalancePrecompile(HyperCore.SPOT_BALANCE_PRECOMPILE);
    MockCoreWriter internal coreWriter = MockCoreWriter(HyperCore.CORE_WRITER);

    uint64 internal constant ONE_USDC = 1e8;

    function setUp() public virtual {
        vm.etch(HyperCore.SPOT_BALANCE_PRECOMPILE, type(MockSpotBalancePrecompile).runtimeCode);
        vm.etch(HyperCore.CORE_WRITER, type(MockCoreWriter).runtimeCode);
    }

    function _setUsdc(address who, uint64 total) internal {
        precompile.set(who, HyperCore.USDC_TOKEN, total, 0);
    }

    /// @dev Split a recorded action into (sender, version, actionId, abi args).
    function _action(uint256 i) internal view returns (address sender, uint8 version, uint24 id, bytes memory args) {
        bytes memory data;
        (sender, data) = coreWriter.actionAt(i);
        version = uint8(data[0]);
        id = (uint24(uint8(data[1])) << 16) | (uint24(uint8(data[2])) << 8) | uint24(uint8(data[3]));
        args = new bytes(data.length - 4);
        for (uint256 j = 0; j < args.length; j++) {
            args[j] = data[j + 4];
        }
    }
}
