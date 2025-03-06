// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";

import "test/vaults/mocks/Mock.sol";

contract MockGateway is Mock, IMessageHandler {
    mapping(bytes => uint256) public handled;

    constructor() {}

    // --- Incoming ---
    function handle(uint32, /*chainId*/ bytes calldata message) public {
        handled[message] += 1;
    }

    // --- Outgoing ---
    function transferTranchesToCentrifuge(
        uint64 poolId,
        bytes16 trancheId,
        address sender,
        bytes32 destinationAddress,
        uint128 amount
    ) public {
        values_uint64["poolId"] = poolId;
        values_bytes16["trancheId"] = trancheId;
        values_address["sender"] = sender;
        values_bytes32["destinationAddress"] = destinationAddress; // why bytes here?
        values_uint128["amount"] = amount;
    }

    function transferTranchesToEVM(
        uint64 poolId,
        bytes16 trancheId,
        address sender,
        uint64 destinationChainId,
        address destinationAddress,
        uint128 amount
    ) public {
        values_uint64["poolId"] = poolId;
        values_bytes16["trancheId"] = trancheId;
        values_address["sender"] = sender;
        values_uint64["destinationChainId"] = destinationChainId;
        values_address["destinationAddress"] = destinationAddress;
        values_uint128["amount"] = amount;
    }

    function transfer(uint128 token, address sender, bytes32 receiver, uint128 amount) public {
        values_uint128["token"] = token;
        values_address["sender"] = sender;
        values_bytes32["receiver"] = receiver;
        values_uint128["amount"] = amount;
    }

    function increaseInvestOrder(uint64 poolId, bytes16 trancheId, address investor, uint128 assetId, uint128 amount)
        public
    {
        values_uint64["poolId"] = poolId;
        values_bytes16["trancheId"] = trancheId;
        values_address["investor"] = investor;
        values_uint128["assetId"] = assetId;
        values_uint128["amount"] = amount;
    }

    function increaseRedeemOrder(uint64 poolId, bytes16 trancheId, address investor, uint128 assetId, uint128 amount)
        public
    {
        values_uint64["poolId"] = poolId;
        values_bytes16["trancheId"] = trancheId;
        values_address["investor"] = investor;
        values_uint128["assetId"] = assetId;
        values_uint128["amount"] = amount;
    }

    function collectInvest(uint64 poolId, bytes16 trancheId, address investor, uint128 assetId) public {
        values_uint64["poolId"] = poolId;
        values_bytes16["trancheId"] = trancheId;
        values_address["investor"] = investor;
        values_uint128["assetId"] = assetId;
    }

    function collectRedeem(uint64 poolId, bytes16 trancheId, address investor, uint128 assetId) public {
        values_uint64["poolId"] = poolId;
        values_bytes16["trancheId"] = trancheId;
        values_address["investor"] = investor;
        values_uint128["assetId"] = assetId;
    }

    function cancelInvestOrder(uint64 poolId, bytes16 trancheId, address investor, uint128 assetId) public {
        values_uint64["poolId"] = poolId;
        values_bytes16["trancheId"] = trancheId;
        values_address["investor"] = investor;
        values_uint128["assetId"] = assetId;
    }

    function cancelRedeemOrder(uint64 poolId, bytes16 trancheId, address investor, uint128 assetId) public {
        values_uint64["poolId"] = poolId;
        values_bytes16["trancheId"] = trancheId;
        values_address["investor"] = investor;
        values_uint128["assetId"] = assetId;
    }
}
