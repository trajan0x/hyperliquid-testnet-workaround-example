// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HyperCoreFunding} from "../HyperCoreFunding.sol";
import {HyperCore} from "../lib/HyperCore.sol";

/// @notice Per-chain configuration, kept in factory STORAGE (not initcode) so the factory and every
///         deposit address have identical initcode, and therefore identical addresses, on testnet and mainnet.
struct DepositConfig {
    uint64 activationAmountWei; // USDC Core wei bounced back out during one-time activation
    address activationReturn; // where the activation bounce goes (e.g. the operator's Core account)
    address sweepTarget; // the "main contract" on Core that receives swept funds
    uint32 hypeSpotAsset; // 10000 + HYPE/USDC spot pair index on THIS chain
    address replicaApiWallet; // mainnet replica only: operator-controlled API wallet to add
}

interface IDepositFactory {
    function owner() external view returns (address);
    function config() external view returns (DepositConfig memory);
    function recordCredit(address user, uint64 amountWei) external;
}

/// @title TestnetFunding
/// @notice TESTNET-ONLY mixin with the crude workaround for testnet bridge deposits not crediting fresh addresses.
///         Everything here exists only because of testnet limitations; production code never sees it.
///
///         - Funding arrives Core-side (spotSend to this address), not through the EVM bridge.
///         - Funds are verified with the spotBalance read precompile. EVM events are never trusted.
///         - Disabled until a one-time activation round trip (in via exchange API, out via CoreWriter).
///         - Credit and transfer are separate steps: sweep() sends via CoreWriter, confirmSweep() credits only
///           after the precompile shows the funds left. User actions are blocked in between.
///         - On HyperEVM mainnet (the "replica" deployed at the same address) it only adds an operator API wallet
///           and can return the seed funds. It never trades there.
abstract contract TestnetFunding is HyperCoreFunding {
    enum Status {
        Inactive,
        Activating,
        Active
    }

    /// @dev Blocks to wait before an unconfirmed activation may be retried (e.g. Core rejected the spotSend).
    uint256 public constant ACTIVATION_RETRY_BLOCKS = 300;

    IDepositFactory public immutable factory;

    Status public status;
    uint64 public activationSnapshot;
    uint256 public activationBlock;

    uint64 public pendingSweep;
    uint64 public sweepSnapshot;
    uint256 public sweepBlock;

    event ActivationStarted(uint64 snapshot, uint64 amount);
    event Activated();
    event SweepStarted(uint64 amount, address target);
    event SweepConfirmed(uint64 amount);
    event ReplicaInitialized(address apiWallet);
    event SeedReturned(address to, uint64 amount);

    error NotActive();
    error WrongStatus();
    error SweepPending();
    error NoSweepPending();
    error InsufficientCoreBalance(uint64 have, uint64 need);
    error NotYetObservedOnCore();
    error SameBlock();
    error MainnetReplica();
    error NotMainnetReplica();
    error NotOperator();

    constructor(IDepositFactory factory_) {
        factory = factory_;
    }

    modifier notReplica() {
        if (block.chainid == HyperCore.CHAIN_ID_MAINNET) revert MainnetReplica();
        _;
    }

    modifier onlyReplica() {
        if (block.chainid != HyperCore.CHAIN_ID_MAINNET) revert NotMainnetReplica();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != address(factory) && msg.sender != factory.owner()) revert NotOperator();
        _;
    }

    // ---------------------------------------------------------------------
    // Hooks (override the production defaults)
    // ---------------------------------------------------------------------

    /// @dev Block every real Core action until activated, while a sweep is in flight, or on the mainnet replica,
    ///      and require the Core balance to actually be there (read precompile, not EVM events).
    function _beforeCoreAction(uint64 costWei) internal virtual override notReplica {
        if (status != Status.Active) revert NotActive();
        if (pendingSweep != 0) revert SweepPending();
        uint64 free = HyperCore.freeUsdc(address(this));
        if (free < costWei) revert InsufficientCoreBalance(free, costWei);
    }

    function _hypeSpotAsset() internal view virtual override returns (uint32) {
        return factory.config().hypeSpotAsset;
    }

    // ---------------------------------------------------------------------
    // One-time activation: small amount in (exchange API), back out via CoreWriter
    // ---------------------------------------------------------------------

    /// @notice Bounce `activationAmountWei` back out via CoreWriter spotSend. Anyone may call.
    ///         Requires the activation amount to already be on Core (sent in with scripts/activate.sh).
    function beginActivation() external notReplica {
        bool retry = status == Status.Activating && block.number > activationBlock + ACTIVATION_RETRY_BLOCKS;
        if (status != Status.Inactive && !retry) revert WrongStatus();
        DepositConfig memory cfg = factory.config();
        uint64 bal = HyperCore.spotBalance(address(this), HyperCore.USDC_TOKEN).total;
        if (bal < cfg.activationAmountWei) revert InsufficientCoreBalance(bal, cfg.activationAmountWei);

        activationSnapshot = bal;
        activationBlock = block.number;
        status = Status.Activating;
        HyperCore.spotSend(cfg.activationReturn, HyperCore.USDC_TOKEN, cfg.activationAmountWei);
        emit ActivationStarted(bal, cfg.activationAmountWei);
    }

    /// @notice Confirm, in a LATER block, that the bounce left this account on Core.
    /// @dev Crude: if more USDC arrives between begin and confirm, the balance may never drop below the snapshot;
    ///      wait ACTIVATION_RETRY_BLOCKS and call beginActivation() again.
    function confirmActivation() external notReplica {
        if (status != Status.Activating) revert WrongStatus();
        if (block.number <= activationBlock) revert SameBlock();
        uint64 amount = factory.config().activationAmountWei;
        uint64 bal = HyperCore.spotBalance(address(this), HyperCore.USDC_TOKEN).total;
        if (bal + amount > activationSnapshot) revert NotYetObservedOnCore();
        status = Status.Active;
        emit Activated();
    }

    // ---------------------------------------------------------------------
    // Sweep: transfer (step 1) and credit (step 2) are separate
    // ---------------------------------------------------------------------

    /// @notice Step 1: send all free Core USDC to the main contract. Blocks user actions until confirmed.
    function sweep() external notReplica {
        if (status != Status.Active) revert NotActive();
        if (pendingSweep != 0) revert SweepPending();
        uint64 total = HyperCore.spotBalance(address(this), HyperCore.USDC_TOKEN).total;
        uint64 free = HyperCore.freeUsdc(address(this));
        if (free == 0) revert InsufficientCoreBalance(0, 1);

        pendingSweep = free;
        sweepSnapshot = total;
        sweepBlock = block.number;
        address target = factory.config().sweepTarget;
        HyperCore.spotSend(target, HyperCore.USDC_TOKEN, free);
        emit SweepStarted(free, target);
    }

    /// @notice Step 2: in a later block, credit the user only once the precompile shows the funds left.
    function confirmSweep() external notReplica {
        uint64 amount = pendingSweep;
        if (amount == 0) revert NoSweepPending();
        if (block.number <= sweepBlock) revert SameBlock();
        uint64 bal = HyperCore.spotBalance(address(this), HyperCore.USDC_TOKEN).total;
        if (bal + amount > sweepSnapshot) revert NotYetObservedOnCore();
        pendingSweep = 0;
        factory.recordCredit(user, amount);
        emit SweepConfirmed(amount);
    }

    // ---------------------------------------------------------------------
    // Mainnet replica (same address on HyperEVM mainnet). UNVERIFIED hypothesis, see README.
    // ---------------------------------------------------------------------

    /// @notice Initializer for the mainnet replica: add the operator's API wallet via CoreWriter.
    ///         Called by the factory on deploy; the operator may call it again if Core dropped the action
    ///         (e.g. because the address had no Core account yet when it ran).
    function initializeReplica() external onlyReplica onlyOperator {
        address wallet = factory.config().replicaApiWallet;
        HyperCore.addApiWallet(wallet, "replica-operator");
        emit ReplicaInitialized(wallet);
    }

    /// @notice Return seed USDC from the mainnet replica's Core account (costs EVM gas, unlike API wallet actions).
    function returnSeed(address to) external onlyReplica onlyOperator {
        uint64 free = HyperCore.freeUsdc(address(this));
        HyperCore.spotSend(to, HyperCore.USDC_TOKEN, free);
        emit SeedReturned(to, free);
    }
}
