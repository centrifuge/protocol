// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice The actual MessageProcessor just forwards messages to the gateway so mock it by just not doing anything
/// because we don't care about messages once they reach the gateway
contract MockMessageProcessor {
    function sendTransferShares(uint32 chainId, uint64 poolId, bytes16 scId, bytes32 recipient, uint128 amount)
        external
    {}

    function sendDepositRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId, uint128 amount)
        external
    {}

    function sendRedeemRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId, uint128 amount)
        external
    {}

    function sendCancelDepositRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId) external {}

    function sendCancelRedeemRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId) external {}

    function handle(uint32, /* chainId */ bytes memory message) external {}
}
