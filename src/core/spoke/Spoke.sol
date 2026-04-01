// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISpoke} from "./interfaces/ISpoke.sol";
import {IShareToken} from "./interfaces/IShareToken.sol";
import {ISpokeRegistry} from "./interfaces/ISpokeRegistry.sol";

import {Auth} from "../../misc/Auth.sol";
import {Recoverable} from "../../misc/Recoverable.sol";
import {CastLib} from "../../misc/libraries/CastLib.sol";
import {MathLib} from "../../misc/libraries/MathLib.sol";
import {BytesLib} from "../../misc/libraries/BytesLib.sol";
import {IERC20Metadata} from "../../misc/interfaces/IERC20.sol";
import {IERC6909MetadataExt} from "../../misc/interfaces/IERC6909.sol";
import {ReentrancyProtection} from "../../misc/ReentrancyProtection.sol";

import {MessageLib} from "../messaging/libraries/MessageLib.sol";
import {ISpokeMessageSender} from "../messaging/interfaces/IGatewaySenders.sol";

import {PoolId} from "../types/PoolId.sol";
import {AssetId} from "../types/AssetId.sol";
import {ShareClassId} from "../types/ShareClassId.sol";
import {IRequestManager} from "../interfaces/IRequestManager.sol";

/// @title  Spoke
/// @notice This contract handles user-facing operations: cross-chain share transfers,
///         asset registration, contract updates, and request forwarding.
contract Spoke is Auth, Recoverable, ReentrancyProtection, ISpoke {
    using CastLib for *;
    using MessageLib for *;
    using BytesLib for bytes;
    using MathLib for uint256;

    uint8 internal constant MIN_DECIMALS = 2;
    uint8 internal constant MAX_DECIMALS = 18;

    ISpokeRegistry public spokeRegistry;
    ISpokeMessageSender public sender;

    constructor(address deployer) Auth(deployer) {}

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpoke
    function file(bytes32 what, address data) external auth {
        if (what == "spokeRegistry") spokeRegistry = ISpokeRegistry(data);
        else if (what == "sender") sender = ISpokeMessageSender(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    //----------------------------------------------------------------------------------------------
    // Outgoing methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpoke
    function crosschainTransferShares(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 receiver,
        uint128 amount,
        uint128 extraGasLimit,
        uint128 remoteExtraGasLimit,
        address refund
    ) public payable protected {
        IShareToken share = IShareToken(spokeRegistry.shareToken(poolId, scId));
        require(centrifugeId != sender.localCentrifugeId(), LocalTransferNotAllowed());
        require(
            share.checkTransferRestriction(msg.sender, address(uint160(centrifugeId)), amount),
            CrossChainTransferNotAllowed()
        );

        share.authTransferFrom(msg.sender, msg.sender, address(this), amount);
        share.burn(address(this), amount);

        emit InitiateTransferShares(centrifugeId, poolId, scId, msg.sender, receiver, amount);

        sender.sendInitiateTransferShares{value: msg.value}(
            centrifugeId, poolId, scId, receiver, amount, extraGasLimit, remoteExtraGasLimit, refund
        );
    }

    /// @inheritdoc ISpoke
    function crosschainTransferShares(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 receiver,
        uint128 amount,
        uint128 remoteExtraGasLimit
    ) external payable protected {
        crosschainTransferShares(centrifugeId, poolId, scId, receiver, amount, 0, remoteExtraGasLimit, msg.sender);
    }

    /// @inheritdoc ISpoke
    function registerAsset(uint16 centrifugeId, address asset, uint256 tokenId, address refund)
        external
        payable
        protected
        returns (AssetId assetId)
    {
        string memory name;
        string memory symbol;
        uint8 decimals;

        decimals = _safeGetAssetDecimals(asset, tokenId);
        require(decimals >= MIN_DECIMALS, TooFewDecimals());
        require(decimals <= MAX_DECIMALS, TooManyDecimals());

        if (tokenId == 0) {
            IERC20Metadata meta = IERC20Metadata(asset);
            name = meta.name();
            symbol = meta.symbol();
        } else {
            IERC6909MetadataExt meta = IERC6909MetadataExt(asset);
            name = meta.name(tokenId);
            symbol = meta.symbol(tokenId);
        }

        bool isInitialization;
        try spokeRegistry.assetToId(asset, tokenId) returns (AssetId existingId) {
            assetId = existingId;
        } catch {
            isInitialization = true;
            assetId = spokeRegistry.createAssetId(sender.localCentrifugeId(), asset, tokenId);
        }

        emit RegisterAsset(centrifugeId, assetId, asset, tokenId, name, symbol, decimals, isInitialization);
        sender.sendRegisterAsset{value: msg.value}(centrifugeId, assetId, decimals, refund);
    }

    /// @inheritdoc ISpoke
    function updateContract(
        PoolId poolId,
        ShareClassId scId,
        bytes32 target,
        bytes calldata payload,
        uint128 extraGasLimit,
        address refund
    ) external payable {
        emit UntrustedContractUpdate(poolId.centrifugeId(), poolId, scId, target, payload, msg.sender);

        sender.sendUntrustedContractUpdate{value: msg.value}(
            poolId, scId, target, payload, msg.sender.toBytes32(), extraGasLimit, refund
        );
    }

    //----------------------------------------------------------------------------------------------
    // Request management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpoke
    function request(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes memory payload,
        uint128 extraGasLimit,
        bool unpaid,
        address refund
    ) external payable {
        IRequestManager manager = spokeRegistry.requestManager(poolId);
        require(address(manager) != address(0), InvalidRequestManager());
        require(msg.sender == address(manager), NotAuthorized());

        sender.sendRequest{value: msg.value}(poolId, scId, assetId, payload, extraGasLimit, unpaid, refund);
    }

    //----------------------------------------------------------------------------------------------
    // Internal methods
    //----------------------------------------------------------------------------------------------

    function _safeGetAssetDecimals(address asset, uint256 tokenId) private view returns (uint8) {
        bytes memory callData;

        if (tokenId == 0) {
            callData = abi.encodeCall(IERC20Metadata.decimals, ());
        } else {
            callData = abi.encodeCall(IERC6909MetadataExt.decimals, tokenId);
        }

        (bool success, bytes memory data) = asset.staticcall(callData);
        require(success && data.length >= 32, AssetMissingDecimals());

        return abi.decode(data, (uint8));
    }
}
