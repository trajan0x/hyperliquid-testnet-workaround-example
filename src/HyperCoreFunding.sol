// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HyperCore} from "./lib/HyperCore.sol";

/// @title HyperCoreFunding
/// @notice Abstract base for a per-user contract that holds funds on HyperCore and acts on them via CoreWriter.
///         Network-specific behavior is injected through two virtual hooks. Production code (MainnetContract)
///         leaves the hooks trivial; the testnet workaround (TestnetFunding) overrides them.
abstract contract HyperCoreFunding {
    address public immutable user;

    event HypeBuyPlaced(uint32 asset, uint64 limitPx, uint64 sz);

    error NotUser();

    constructor(address user_) {
        user = user_;
    }

    modifier onlyUser() {
        if (msg.sender != user) revert NotUser();
        _;
    }

    /// @notice FOR EXAMPLE PURPOSES ONLY: place a GTC limit buy of HYPE spot on HyperCore.
    /// @param limitPx price in USDC, scaled by 1e8. Must respect HyperCore tick rules
    ///        (<= 5 significant figures, <= 8 - szDecimals decimals; HYPE szDecimals = 2).
    /// @param sz size in HYPE, scaled by 1e8. Must be a multiple of 10^(8 - szDecimals) = 1e6.
    /// @dev   CoreWriter actions are asynchronous: this emits a log that HyperCore processes after the
    ///        EVM block (orders are additionally delayed a few seconds). A Core-side rejection does NOT
    ///        revert this transaction.
    function buyHype(uint64 limitPx, uint64 sz) external onlyUser {
        uint64 cost = uint64((uint256(limitPx) * sz) / 1e8); // USDC Core wei (1e8 = 1 USDC)
        _beforeCoreAction(cost);
        uint32 asset = _hypeSpotAsset();
        HyperCore.limitOrder(asset, true, limitPx, sz, false, HyperCore.TIF_GTC, 0);
        emit HypeBuyPlaced(asset, limitPx, sz);
    }

    /// @dev Hook run before any CoreWriter action that spends `costWei` USDC. Default: no checks.
    function _beforeCoreAction(uint64 costWei) internal virtual {}

    /// @dev Core asset id of the HYPE/USDC spot pair (10000 + spot pair index).
    function _hypeSpotAsset() internal view virtual returns (uint32);
}
