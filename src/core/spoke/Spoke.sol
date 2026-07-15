// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISpoke} from "./interfaces/ISpoke.sol";
import {IRegistrar} from "./interfaces/IRegistrar.sol";
import {ISpokeRegistry} from "./interfaces/ISpokeRegistry.sol";

import {Auth} from "../../misc/Auth.sol";
import {Recoverable} from "../../misc/Recoverable.sol";
import {CastLib} from "../../misc/libraries/CastLib.sol";
import {MathLib} from "../../misc/libraries/MathLib.sol";
import {BytesLib} from "../../misc/libraries/BytesLib.sol";
import {IERC6909MetadataExt} from "../../misc/interfaces/IERC6909.sol";
import {IERC20, IERC20Metadata} from "../../misc/interfaces/IERC20.sol";
import {ReentrancyProtection} from "../../misc/ReentrancyProtection.sol";
import {SafeTransferLib} from "../../misc/libraries/SafeTransferLib.sol";

import {MessageLib} from "../messaging/libraries/MessageLib.sol";
import {ISpokeMessageSender} from "../messaging/interfaces/IGatewaySenders.sol";

import {PoolId} from "../types/PoolId.sol";
import {AssetId} from "../types/AssetId.sol";
import {ShareClassId} from "../types/ShareClassId.sol";
import {IRequestManager} from "../interfaces/IRequestManager.sol";

/// @title  Spoke
/// @notice This contract handles user-facing operations: cross-chain share transfers,
///         asset registration, manager calls, and request forwarding.
contract Spoke is Auth, Recoverable, ReentrancyProtection, ISpoke {
    using CastLib for *;
    using MessageLib for *;
    using BytesLib for bytes;
    using MathLib for uint256;

    uint8 internal constant MAX_DECIMALS = 18;

    ISpokeMessageSender public sender;
    ISpokeRegistry public spokeRegistry;

    constructor(address deployer) Auth(deployer) {}

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpoke
    function file(bytes32 what, address data) external auth {
        if (what == "sender") sender = ISpokeMessageSender(data);
        else if (what == "spokeRegistry") spokeRegistry = ISpokeRegistry(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    //----------------------------------------------------------------------------------------------
    // Assets
    //----------------------------------------------------------------------------------------------

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

        assetId = spokeRegistry.assetToIdOrNull(asset, tokenId);
        bool isInitialization = assetId.isNull();
        if (isInitialization) {
            assetId = spokeRegistry.createAssetId(sender.localCentrifugeId(), asset, tokenId);
        }

        emit RegisterAsset(centrifugeId, assetId, asset, tokenId, name, symbol, decimals, isInitialization);
        sender.sendRegisterAsset{value: msg.value}(centrifugeId, assetId, decimals, refund);
    }

    //----------------------------------------------------------------------------------------------
    // Bridging
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpoke
    function crosschainTransferShares(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 receiver,
        address sender_,
        address owner,
        uint128 amount,
        uint128 extraGasLimit,
        uint128 remoteExtraGasLimit,
        address refund
    ) public payable protected {
        require(msg.sender == owner || wards[msg.sender] == 1, NotAuthorized());
        require(spokeRegistry.bridger(poolId, owner), NotBridger());

        (IERC20 share, IRegistrar registrar) = spokeRegistry.shareTokenAndRegistrar(poolId, scId);
        require(centrifugeId != sender.localCentrifugeId(), LocalTransferNotAllowed());
        require(
            registrar.canTransferCrosschain(address(share), owner, centrifugeId, amount), CrossChainTransferNotAllowed()
        );

        SafeTransferLib.safeTransferFrom(address(share), owner, address(this), amount);
        SafeTransferLib.safeApprove(address(share), address(registrar), amount);
        registrar.burn(address(share), address(this), amount);

        emit InitiateTransferShares(centrifugeId, poolId, scId, sender_, owner, receiver, amount);

        sender.sendInitiateTransferShares{value: msg.value}(
            centrifugeId,
            poolId,
            scId,
            sender_.toBytes32(),
            receiver,
            amount,
            extraGasLimit,
            remoteExtraGasLimit,
            refund
        );
    }

    //----------------------------------------------------------------------------------------------
    // Requests
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
    // Manager calls
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpoke
    function managerCall(PoolId poolId, bytes32 target, bytes calldata payload, uint128 extraGasLimit, address refund)
        external
        payable
    {
        emit ManagerCall(poolId.centrifugeId(), poolId, target, payload, msg.sender);

        sender.sendManagerSpokeCall{value: msg.value}(
            poolId, target, payload, msg.sender.toBytes32(), extraGasLimit, refund
        );
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
