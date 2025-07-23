// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "../../../src/misc/types/D18.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {IAdapter} from "../../../src/common/interfaces/IAdapter.sol";
import {MessageProofLib} from "../../../src/common/libraries/MessageProofLib.sol";
import {MessageLib, VaultUpdateKind} from "../../../src/common/libraries/MessageLib.sol";
import {RequestCallbackMessageLib} from "../../../src/common/libraries/RequestCallbackMessageLib.sol";

import {Spoke} from "../../../src/spoke/Spoke.sol";
import {VaultDetails} from "../../../src/spoke/interfaces/ISpoke.sol";
import {UpdateContractMessageLib} from "../../../src/spoke/libraries/UpdateContractMessageLib.sol";

import {SyncManager} from "../../../src/vaults/SyncManager.sol";
import {IBaseVault} from "../../../src/vaults/interfaces/IBaseVault.sol";

import {UpdateRestrictionMessageLib} from "../../../src/hooks/libraries/UpdateRestrictionMessageLib.sol";

import "forge-std/Test.sol";

interface AdapterLike {
    function execute(bytes memory _message) external;
}

contract MockCentrifugeChain is Test {
    using CastLib for *;
    using MessageLib for *;
    using UpdateRestrictionMessageLib for *;
    using UpdateContractMessageLib for *;
    using RequestCallbackMessageLib for *;

    IAdapter[] public adapters;
    Spoke public spoke;
    SyncManager public syncManager;

    constructor(IAdapter[] memory adapters_, Spoke spoke_, SyncManager syncManager_) {
        for (uint256 i = 0; i < adapters_.length; i++) {
            adapters.push(adapters_[i]);
        }
        spoke = spoke_;
        syncManager = syncManager_;
    }

    function addPool(uint64 poolId) public {
        execute(MessageLib.NotifyPool({poolId: poolId}).serialize());
    }

    function unlinkVault(uint64 poolId, bytes16 scId, address vault) public {
        VaultDetails memory vaultDetails = spoke.vaultDetails(IBaseVault(vault));

        execute(
            MessageLib.UpdateVault({
                poolId: poolId,
                scId: scId,
                assetId: vaultDetails.assetId.raw(),
                vaultOrFactory: bytes32(bytes20(vault)),
                kind: uint8(VaultUpdateKind.Unlink)
            }).serialize()
        );
    }

    function linkVault(uint64 poolId, bytes16 scId, address vault) public {
        VaultDetails memory vaultDetails = spoke.vaultDetails(IBaseVault(vault));

        execute(
            MessageLib.UpdateVault({
                poolId: poolId,
                scId: scId,
                vaultOrFactory: bytes32(bytes20(vault)),
                assetId: vaultDetails.assetId.raw(),
                kind: uint8(VaultUpdateKind.Link)
            }).serialize()
        );
    }

    function updateMaxReserve(uint64 poolId, bytes16 scId, address vault, uint128 maxReserve) public {
        VaultDetails memory vaultDetails = spoke.vaultDetails(IBaseVault(vault));

        execute(
            MessageLib.UpdateContract({
                poolId: poolId,
                scId: scId,
                target: bytes32(bytes20(address(syncManager))),
                payload: UpdateContractMessageLib.UpdateContractSyncDepositMaxReserve({
                    assetId: vaultDetails.assetId.raw(),
                    maxReserve: maxReserve
                }).serialize()
            }).serialize()
        );
    }

    /// @dev Simulates incoming NotifyShareClass message with prepended UpdateRestrictionMember message for pool escrow
    function addShareClass(
        uint64 poolId,
        bytes16 scId,
        string memory tokenName,
        string memory tokenSymbol,
        uint8 decimals,
        bytes32 salt,
        address hook
    ) public {
        execute(
            MessageLib.NotifyShareClass({
                poolId: poolId,
                scId: scId,
                name: tokenName,
                symbol: tokenSymbol.toBytes32(),
                decimals: decimals,
                salt: salt,
                hook: bytes32(bytes20(hook))
            }).serialize()
        );

        updateMemberPoolEscrow(poolId, scId);
    }

    /// @dev Updates escrow as member to enable minting, burning and transfers on deposit and redeem
    ///
    /// @dev Implicitly called by addShareClass
    function updateMemberPoolEscrow(uint64 poolId, bytes16 scId) public {
        address escrow = address(spoke.poolEscrowFactory().escrow(PoolId.wrap(poolId)));
        updateMember(poolId, scId, escrow, type(uint64).max);
    }

    /// @dev Simulates incoming NotifyShareClass message with prepended UpdateRestrictionMember message for pool escrow
    function addShareClass(
        uint64 poolId,
        bytes16 scId,
        string memory tokenName,
        string memory tokenSymbol,
        uint8 decimals,
        address hook
    ) public {
        execute(
            MessageLib.NotifyShareClass({
                poolId: poolId,
                scId: scId,
                name: tokenName,
                symbol: tokenSymbol.toBytes32(),
                decimals: decimals,
                salt: keccak256(abi.encodePacked(poolId, scId)),
                hook: bytes32(bytes20(hook))
            }).serialize()
        );

        updateMemberPoolEscrow(poolId, scId);
    }

    function updateMember(uint64 poolId, bytes16 scId, address user, uint64 validUntil) public {
        execute(
            MessageLib.UpdateRestriction({
                poolId: poolId,
                scId: scId,
                payload: UpdateRestrictionMessageLib.UpdateRestrictionMember(user.toBytes32(), validUntil).serialize()
            }).serialize()
        );
    }

    function updateShareMetadata(uint64 poolId, bytes16 scId, string memory tokenName, string memory tokenSymbol)
        public
    {
        execute(
            MessageLib.NotifyShareMetadata({
                poolId: poolId,
                scId: scId,
                name: tokenName,
                symbol: tokenSymbol.toBytes32()
            }).serialize()
        );
    }

    function updateShareHook(uint64 poolId, bytes16 scId, address hook) public {
        execute(MessageLib.UpdateShareHook({poolId: poolId, scId: scId, hook: bytes32(bytes20(hook))}).serialize());
    }

    function updatePricePoolPerShare(uint64 poolId, bytes16 scId, uint128 price, uint64 computedAt) public {
        execute(
            MessageLib.NotifyPricePoolPerShare({poolId: poolId, scId: scId, price: price, timestamp: computedAt})
                .serialize()
        );
    }

    function updatePricePoolPerAsset(uint64 poolId, bytes16 scId, uint128 assetId, uint128 price, uint64 computedAt)
        public
    {
        execute(
            MessageLib.NotifyPricePoolPerAsset({
                poolId: poolId,
                scId: scId,
                assetId: assetId,
                price: price,
                timestamp: computedAt
            }).serialize()
        );
    }

    function incomingScheduleUpgrade(address target) public {
        execute(MessageLib.ScheduleUpgrade({target: bytes32(bytes20(target))}).serialize());
    }

    function incomingCancelUpgrade(address target) public {
        execute(MessageLib.CancelUpgrade({target: bytes32(bytes20(target))}).serialize());
    }

    function freeze(uint64 poolId, bytes16 scId, address user) public {
        execute(
            MessageLib.UpdateRestriction({
                poolId: poolId,
                scId: scId,
                payload: UpdateRestrictionMessageLib.UpdateRestrictionFreeze(user.toBytes32()).serialize()
            }).serialize()
        );
    }

    function unfreeze(uint64 poolId, bytes16 scId, address user) public {
        execute(
            MessageLib.UpdateRestriction({
                poolId: poolId,
                scId: scId,
                payload: UpdateRestrictionMessageLib.UpdateRestrictionUnfreeze(user.toBytes32()).serialize()
            }).serialize()
        );
    }

    function recoverTokens(address target, address token, uint256 tokenId, address to, uint256 amount) public {
        execute(
            MessageLib.RecoverTokens({
                target: bytes32(bytes20(target)),
                token: bytes32(bytes20(token)),
                tokenId: tokenId,
                to: bytes32(bytes20(to)),
                amount: amount
            }).serialize()
        );
    }

    /// @dev Simulates incoming FulfilledDepositRequest with prepended ApprovedDeposits message
    function isFulfilledDepositRequest(
        uint64 poolId,
        bytes16 scId,
        bytes32 investor,
        uint128 assetId,
        uint128 fulfilledAssetAmount,
        uint128 fulfilledShareAmount,
        uint128 cancelledAssetAmount
    ) public {
        // NOTE: Currently, hardcoding pricePoolPerAsset to 1
        isApprovedDeposits(poolId, scId, assetId, fulfilledAssetAmount, d18(1, 1));
        isIssuedShares(poolId, scId, assetId, fulfilledShareAmount, d18(1, 1));

        execute(
            MessageLib.RequestCallback(
                poolId,
                scId,
                assetId,
                RequestCallbackMessageLib.FulfilledDepositRequest({
                    investor: investor,
                    fulfilledAssetAmount: fulfilledAssetAmount,
                    fulfilledShareAmount: fulfilledShareAmount,
                    cancelledAssetAmount: cancelledAssetAmount
                }).serialize()
            ).serialize()
        );
    }

    /// @dev Simulates incoming FulfilledRedeemRequest with prepended RevokedShares message
    function isFulfilledRedeemRequest(
        uint64 poolId,
        bytes16 scId,
        bytes32 investor,
        uint128 assetId,
        uint128 fulfilledAssetAmount,
        uint128 fulfilledShareAmount,
        uint128 cancelledShareAmount
    ) public {
        // NOTE: Currently hard coding pricePoolPerShare to 1
        isRevokedShares(poolId, scId, assetId, fulfilledAssetAmount, fulfilledShareAmount, d18(1, 1));
        execute(
            MessageLib.RequestCallback(
                poolId,
                scId,
                assetId,
                RequestCallbackMessageLib.FulfilledRedeemRequest({
                    investor: investor,
                    fulfilledAssetAmount: fulfilledAssetAmount,
                    fulfilledShareAmount: fulfilledShareAmount,
                    cancelledShareAmount: cancelledShareAmount
                }).serialize()
            ).serialize()
        );
    }

    /// @dev Implicitly called by isFulfilledDepositRequest
    function isApprovedDeposits(uint64 poolId, bytes16 scId, uint128 assetId, uint128 assets, D18 pricePoolPerAsset)
        public
    {
        execute(
            MessageLib.RequestCallback(
                poolId,
                scId,
                assetId,
                RequestCallbackMessageLib.ApprovedDeposits({
                    assetAmount: assets,
                    pricePoolPerAsset: pricePoolPerAsset.raw()
                }).serialize()
            ).serialize()
        );
    }

    /// @dev Implicitly called by isFulfilledDepositRequest
    function isIssuedShares(uint64 poolId, bytes16 scId, uint128 assetId, uint128 shares, D18 pricePoolPerShare)
        public
    {
        execute(
            MessageLib.RequestCallback(
                poolId,
                scId,
                assetId,
                RequestCallbackMessageLib.IssuedShares({shareAmount: shares, pricePoolPerShare: pricePoolPerShare.raw()})
                    .serialize()
            ).serialize()
        );
    }

    /// @dev Implicitly called by isFulfilledRedeemRequest
    function isRevokedShares(
        uint64 poolId,
        bytes16 scId,
        uint128 assetId,
        uint128 assets,
        uint128 shareAmount,
        D18 pricePoolPerShare
    ) public {
        execute(
            MessageLib.RequestCallback(
                poolId,
                scId,
                assetId,
                RequestCallbackMessageLib.RevokedShares({
                    assetAmount: assets,
                    shareAmount: shareAmount,
                    pricePoolPerShare: pricePoolPerShare.raw()
                }).serialize()
            ).serialize()
        );
    }

    function execute(bytes memory message) public {
        bytes memory proof = MessageProofLib.serializeMessageProof(keccak256(message));
        for (uint256 i = 0; i < adapters.length; i++) {
            AdapterLike(address(adapters[i])).execute(i == 0 ? message : proof);
        }
    }
}
