// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HyperCoreTestBase} from "./Base.t.sol";
import {HyperCore} from "../src/lib/HyperCore.sol";
import {HyperCoreFunding} from "../src/HyperCoreFunding.sol";
import {MainnetContract} from "../src/MainnetContract.sol";

contract MainnetContractTest is HyperCoreTestBase {
    address internal alice = makeAddr("alice");
    MainnetContract internal c;

    function setUp() public override {
        super.setUp();
        c = new MainnetContract(alice);
    }

    function test_buyHype_encodesLimitOrder() public {
        uint64 px = 25e8; // $25.00
        uint64 sz = 1e8; // 1 HYPE
        vm.prank(alice);
        c.buyHype(px, sz);

        assertEq(coreWriter.count(), 1);
        (address sender, uint8 version, uint24 id, bytes memory args) = _action(0);
        assertEq(sender, address(c));
        assertEq(version, 1);
        assertEq(id, HyperCore.ACTION_LIMIT_ORDER);
        (uint32 asset, bool isBuy, uint64 p, uint64 s, bool ro, uint8 tif, uint128 cloid) =
            abi.decode(args, (uint32, bool, uint64, uint64, bool, uint8, uint128));
        assertEq(asset, 10_107);
        assertTrue(isBuy);
        assertEq(p, px);
        assertEq(s, sz);
        assertFalse(ro);
        assertEq(tif, HyperCore.TIF_GTC);
        assertEq(cloid, 0);
    }

    /// Production path has no workaround machinery: no activation, no precompile balance gate.
    function test_buyHype_noActivationOrBalanceGate() public {
        vm.prank(alice);
        c.buyHype(25e8, 1e8);
        assertEq(coreWriter.count(), 1);
    }

    function test_buyHype_onlyUser() public {
        vm.expectRevert(HyperCoreFunding.NotUser.selector);
        c.buyHype(25e8, 1e8);
    }
}
