// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HyperCoreFunding} from "./HyperCoreFunding.sol";
import {HyperCore} from "./lib/HyperCore.sol";

/// @title MainnetContract
/// @notice The plain production contract. No testnet workaround machinery.
///         On mainnet it is funded the normal way: anyone bridges USDC to it with
///         CoreDepositWallet.depositFor(address(this), amount, ...), and the user trades with buyHype().
contract MainnetContract is HyperCoreFunding {
    /// @dev HYPE/USDC spot pair on mainnet is "@107" (spotMeta.universe index 107) -> asset 10107.
    ///      Look it up with: scripts/lookup_spot_asset.py --network mainnet
    uint32 public constant MAINNET_HYPE_SPOT_ASSET = HyperCore.SPOT_ASSET_OFFSET + 107;

    constructor(address user_) HyperCoreFunding(user_) {}

    function _hypeSpotAsset() internal view virtual override returns (uint32) {
        return MAINNET_HYPE_SPOT_ASSET;
    }
}
