// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HyperCoreTestBase} from "./Base.t.sol";
import {HyperCore} from "../src/lib/HyperCore.sol";
import {TestnetContract} from "../src/testnet/TestnetContract.sol";
import {TestnetFunding, DepositConfig} from "../src/testnet/TestnetFunding.sol";
import {TestnetDepositFactory} from "../src/testnet/TestnetDepositFactory.sol";

contract TestnetContractTest is HyperCoreTestBase {
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal operatorCore = makeAddr("operatorCore");
    address internal apiWallet = makeAddr("apiWallet");

    uint32 internal constant TESTNET_HYPE_ASSET = 10_000 + 1035; // spotMeta "@1035" on testnet
    uint64 internal constant ACTIVATION = 1e8; // 1 USDC

    TestnetDepositFactory internal factory;

    function setUp() public override {
        super.setUp();
        vm.chainId(HyperCore.CHAIN_ID_TESTNET);
        factory = new TestnetDepositFactory{salt: bytes32(0)}(owner);
        vm.prank(owner);
        factory.setConfig(
            DepositConfig({
                activationAmountWei: ACTIVATION,
                activationReturn: operatorCore,
                sweepTarget: address(factory),
                hypeSpotAsset: TESTNET_HYPE_ASSET,
                replicaApiWallet: apiWallet
            })
        );
    }

    // ---- helpers ----

    function _deployActive(uint64 funded) internal returns (TestnetContract dep) {
        address predicted = factory.predict(alice);
        _setUsdc(predicted, funded + ACTIVATION); // funding + activation amount arrived Core-side
        dep = factory.deploy(alice);
        dep.beginActivation();
        _setUsdc(address(dep), funded); // Core processed the bounce
        vm.roll(block.number + 1);
        dep.confirmActivation();
    }

    // ---- lazy CREATE2 deployment ----

    function test_predictMatchesDeploy_andFundsBeforeCode() public {
        address predicted = factory.predict(alice);
        assertEq(predicted.code.length, 0);
        _setUsdc(predicted, 50 * ONE_USDC); // Core can hold funds before any code exists
        TestnetContract dep = factory.deploy(alice);
        assertEq(address(dep), predicted);
        assertEq(dep.user(), alice);
        assertEq(HyperCore.freeUsdc(address(dep)), 50 * ONE_USDC);
    }

    function test_sameAddressesOnTestnetAndMainnet() public {
        uint256 snap = vm.snapshotState();
        vm.chainId(HyperCore.CHAIN_ID_TESTNET);
        TestnetDepositFactory f1 = new TestnetDepositFactory{salt: keccak256("x")}(owner);
        address d1 = f1.predict(alice);
        vm.revertToState(snap);
        vm.chainId(HyperCore.CHAIN_ID_MAINNET);
        TestnetDepositFactory f2 = new TestnetDepositFactory{salt: keccak256("x")}(owner);
        assertEq(address(f1), address(f2));
        assertEq(d1, f2.predict(alice));
    }

    // ---- activation ----

    function test_disabledUntilActivated() public {
        address predicted = factory.predict(alice);
        _setUsdc(predicted, 100 * ONE_USDC);
        TestnetContract dep = factory.deploy(alice);
        vm.prank(alice);
        vm.expectRevert(TestnetFunding.NotActive.selector);
        dep.buyHype(25e8, 1e8);
        vm.expectRevert(TestnetFunding.NotActive.selector);
        dep.sweep();
    }

    function test_activation_bouncesOutViaCoreWriter() public {
        address predicted = factory.predict(alice);
        _setUsdc(predicted, ACTIVATION);
        TestnetContract dep = factory.deploy(alice);

        dep.beginActivation();
        assertEq(uint8(dep.status()), uint8(TestnetFunding.Status.Activating));
        (address sender, uint8 v, uint24 id, bytes memory args) = _action(0);
        assertEq(sender, address(dep));
        assertEq(v, 1);
        assertEq(id, HyperCore.ACTION_SPOT_SEND);
        (address to, uint64 token, uint64 amount) = abi.decode(args, (address, uint64, uint64));
        assertEq(to, operatorCore);
        assertEq(token, HyperCore.USDC_TOKEN);
        assertEq(amount, ACTIVATION);

        // Same block: precompile cannot reflect the CoreWriter action yet.
        vm.expectRevert(TestnetFunding.SameBlock.selector);
        dep.confirmActivation();

        // Later block but Core has not processed the send (balance unchanged).
        vm.roll(block.number + 1);
        vm.expectRevert(TestnetFunding.NotYetObservedOnCore.selector);
        dep.confirmActivation();

        _setUsdc(address(dep), 0);
        dep.confirmActivation();
        assertEq(uint8(dep.status()), uint8(TestnetFunding.Status.Active));
    }

    function test_activation_requiresCoreBalance() public {
        TestnetContract dep = factory.deploy(alice);
        vm.expectRevert(abi.encodeWithSelector(TestnetFunding.InsufficientCoreBalance.selector, 0, ACTIVATION));
        dep.beginActivation();
    }

    function test_activation_retryAfterTimeout() public {
        _setUsdc(factory.predict(alice), ACTIVATION);
        TestnetContract dep = factory.deploy(alice);
        dep.beginActivation();
        vm.expectRevert(TestnetFunding.WrongStatus.selector);
        dep.beginActivation();
        vm.roll(block.number + dep.ACTIVATION_RETRY_BLOCKS() + 1);
        dep.beginActivation();
        assertEq(coreWriter.count(), 2);
    }

    // ---- example action: limit buy, gated on Core balance ----

    function test_buyHype_afterActivation_usesTestnetAsset() public {
        TestnetContract dep = _deployActive(30 * ONE_USDC);
        uint256 before = coreWriter.count();
        vm.prank(alice);
        dep.buyHype(25e8, 1e8); // cost 25 USDC
        (,, uint24 id, bytes memory args) = _action(before);
        assertEq(id, HyperCore.ACTION_LIMIT_ORDER);
        (uint32 asset, bool isBuy,,,,,) = abi.decode(args, (uint32, bool, uint64, uint64, bool, uint8, uint128));
        assertEq(asset, TESTNET_HYPE_ASSET);
        assertTrue(isBuy);
    }

    function test_buyHype_revertsWithoutCoreBalance() public {
        TestnetContract dep = _deployActive(10 * ONE_USDC);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(TestnetFunding.InsufficientCoreBalance.selector, 10 * ONE_USDC, 25 * ONE_USDC)
        );
        dep.buyHype(25e8, 1e8);
    }

    function test_buyHype_respectsHold() public {
        TestnetContract dep = _deployActive(0);
        precompile.set(address(dep), HyperCore.USDC_TOKEN, 30 * ONE_USDC, 10 * ONE_USDC); // 20 free
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(TestnetFunding.InsufficientCoreBalance.selector, 20 * ONE_USDC, 25 * ONE_USDC)
        );
        dep.buyHype(25e8, 1e8);
    }

    // ---- sweep: transfer and credit are separate; user blocked in between ----

    function test_sweep_creditOnlyAfterCoreConfirms() public {
        TestnetContract dep = _deployActive(40 * ONE_USDC);
        dep.sweep();
        assertEq(dep.pendingSweep(), 40 * ONE_USDC);
        assertEq(factory.credited(alice), 0);

        vm.prank(alice);
        vm.expectRevert(TestnetFunding.SweepPending.selector);
        dep.buyHype(1e8, 1e8);

        vm.roll(block.number + 1);
        vm.expectRevert(TestnetFunding.NotYetObservedOnCore.selector);
        dep.confirmSweep();

        _setUsdc(address(dep), 0);
        dep.confirmSweep();
        assertEq(factory.credited(alice), 40 * ONE_USDC);
        assertEq(dep.pendingSweep(), 0);
    }

    function test_recordCredit_onlyDepositAddress() public {
        vm.expectRevert(TestnetDepositFactory.NotDepositAddress.selector);
        factory.recordCredit(alice, 1);
    }

    // ---- mainnet replica ----

    function test_replica_addsApiWalletOnDeploy_andNeverTrades() public {
        vm.chainId(HyperCore.CHAIN_ID_MAINNET);
        _setUsdc(factory.predict(alice), 2 * ONE_USDC);
        TestnetContract dep = factory.deploy(alice);

        (address sender, uint8 v, uint24 id, bytes memory args) = _action(0);
        assertEq(sender, address(dep));
        assertEq(v, 1);
        assertEq(id, HyperCore.ACTION_ADD_API_WALLET);
        (address w, string memory name) = abi.decode(args, (address, string));
        assertEq(w, apiWallet);
        assertEq(name, "replica-operator");

        vm.expectRevert(TestnetFunding.MainnetReplica.selector);
        dep.beginActivation();
        vm.prank(alice);
        vm.expectRevert(TestnetFunding.MainnetReplica.selector);
        dep.buyHype(1e8, 1e8);
    }

    function test_replica_returnSeed_onlyOperator() public {
        vm.chainId(HyperCore.CHAIN_ID_MAINNET);
        _setUsdc(factory.predict(alice), 2 * ONE_USDC);
        TestnetContract dep = factory.deploy(alice);

        vm.expectRevert(TestnetFunding.NotOperator.selector);
        dep.returnSeed(owner);

        vm.prank(owner);
        dep.returnSeed(owner);
        (,, uint24 id, bytes memory args) = _action(1);
        assertEq(id, HyperCore.ACTION_SPOT_SEND);
        (address to,, uint64 amount) = abi.decode(args, (address, uint64, uint64));
        assertEq(to, owner);
        assertEq(amount, 2 * ONE_USDC);
    }

    function test_replicaFunctions_disabledOnTestnet() public {
        TestnetContract dep = factory.deploy(alice);
        vm.prank(owner);
        vm.expectRevert(TestnetFunding.NotMainnetReplica.selector);
        dep.initializeReplica();
    }
}
