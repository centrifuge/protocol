// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IInstantPolicy} from "../../../../src/vaults/policies/interfaces/IVaultPlugins.sol";

/// @dev An instant policy that pays a rebate on every trade, from a fee source that has approved the vault: the
///      shipped reserve policy never rebates, so this is what puts the rebate leg of the vault's instant paths under
///      test. Capacity is as large as the types allow, so the escrow's own balance is what bounds a trade.
contract RebatingInstantPolicy is IInstantPolicy {
    uint16 public immutable rebateBps;
    address public immutable source;

    constructor(address source_, uint16 rebateBps_) {
        source = source_;
        rebateBps = rebateBps_;
    }

    function maxInstantDeposit(address, address) external pure returns (uint128) {
        return type(uint128).max;
    }

    function maxInstantRedeem(address, address) external pure returns (uint128) {
        return type(uint128).max;
    }

    function quoteInstantDeposit(address, address, address, uint128 assets, bool)
        external
        view
        returns (int128 feeAssets, address feeRecipient)
    {
        return (_rebate(assets), source);
    }

    function quoteInstantRedeem(address, address, address, uint128 assets, bool)
        external
        view
        returns (int128 feeAssets, address feeRecipient)
    {
        return (_rebate(assets), source);
    }

    function onInstantDeposit(address, address, address, uint128, bool) external pure {}

    function onInstantRedeem(address, address, address, uint128, bool) external pure {}

    function canCredit(address, address, address) external pure returns (bool) {
        return false;
    }

    function _rebate(uint128 assets) internal view returns (int128) {
        return -int128(uint128(uint256(assets) * rebateBps / 10_000));
    }
}
