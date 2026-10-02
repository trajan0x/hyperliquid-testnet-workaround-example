// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice CoreWriter system contract interface.
/// Docs: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/interacting-with-hypercore
interface ICoreWriter {
    function sendRawAction(bytes calldata data) external;
}

/// @title HyperCore
/// @notice Minimal helpers for the HyperEVM <-> HyperCore system addresses used by this example.
///
/// Sources:
///  - Precompile addresses, CoreWriter address, action encoding and action ids:
///    https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/interacting-with-hypercore
///    (read precompiles start at 0x...0800; spotBalance is 0x...0801, see the L1Read.sol attached to that page)
///  - Cross-checked against hyper-evm-lib (HLConstants.sol / PrecompileLib.sol):
///    https://github.com/hyperliquid-dev/hyper-evm-lib
library HyperCore {
    address internal constant CORE_WRITER = 0x3333333333333333333333333333333333333333;

    /// @dev spotBalance(address user, uint64 token) -> SpotBalance{total, hold, entryNtl}
    address internal constant SPOT_BALANCE_PRECOMPILE = 0x0000000000000000000000000000000000000801;

    /// @dev Core token index of USDC (spotMeta.tokens[].index). 8 wei decimals on Core.
    uint64 internal constant USDC_TOKEN = 0;

    /// @dev Spot assets are addressed as 10000 + spot pair index (spotMeta.universe[].index).
    uint32 internal constant SPOT_ASSET_OFFSET = 10_000;

    // CoreWriter action ids (encoding version 1).
    uint8 internal constant ENCODING_VERSION = 1;
    uint24 internal constant ACTION_LIMIT_ORDER = 1;
    uint24 internal constant ACTION_SPOT_SEND = 6;
    uint24 internal constant ACTION_ADD_API_WALLET = 9;

    // Limit order time-in-force.
    uint8 internal constant TIF_ALO = 1;
    uint8 internal constant TIF_GTC = 2;
    uint8 internal constant TIF_IOC = 3;

    // HyperEVM chain ids.
    uint256 internal constant CHAIN_ID_MAINNET = 999;
    uint256 internal constant CHAIN_ID_TESTNET = 998;

    struct SpotBalance {
        uint64 total;
        uint64 hold;
        uint64 entryNtl;
    }

    error SpotBalancePrecompileFailed();

    /// @notice Core spot balance of `user` for `token`, as of the start of the current EVM block.
    function spotBalance(address user, uint64 token) internal view returns (SpotBalance memory) {
        (bool ok, bytes memory out) = SPOT_BALANCE_PRECOMPILE.staticcall(abi.encode(user, token));
        if (!ok || out.length < 96) revert SpotBalancePrecompileFailed();
        return abi.decode(out, (SpotBalance));
    }

    /// @notice Spendable (total - hold) Core spot USDC of `user`, in Core wei (1e8 = 1 USDC).
    function freeUsdc(address user) internal view returns (uint64) {
        SpotBalance memory b = spotBalance(user, USDC_TOKEN);
        return b.total > b.hold ? b.total - b.hold : 0;
    }

    /// @dev Action wire format: [version:1 byte][action id:3 bytes big-endian][abi.encode(args)].
    function _send(uint24 actionId, bytes memory args) private {
        ICoreWriter(CORE_WRITER).sendRawAction(abi.encodePacked(ENCODING_VERSION, actionId, args));
    }

    /// @notice Action 1: limit order. limitPx and sz are 1e8 * human value.
    function limitOrder(uint32 asset, bool isBuy, uint64 limitPx, uint64 sz, bool reduceOnly, uint8 tif, uint128 cloid)
        internal
    {
        _send(ACTION_LIMIT_ORDER, abi.encode(asset, isBuy, limitPx, sz, reduceOnly, tif, cloid));
    }

    /// @notice Action 6: spot send. amountWei is in the token's Core wei (USDC: 1e8 = 1 USDC).
    function spotSend(address destination, uint64 token, uint64 amountWei) internal {
        _send(ACTION_SPOT_SEND, abi.encode(destination, token, amountWei));
    }

    /// @notice Action 9: add API wallet. An empty name sets the main API wallet.
    function addApiWallet(address wallet, string memory name) internal {
        _send(ACTION_ADD_API_WALLET, abi.encode(wallet, name));
    }
}
