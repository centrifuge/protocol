// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IOnOffRamp} from "./interfaces/IOnOffRamp.sol";
import {IAccountingToken} from "./interfaces/IAccountingToken.sol";
import {IOnOffRampFactory} from "./interfaces/IOnOffRampFactory.sol";
import {IDepositManager, IWithdrawManager} from "./interfaces/IBalanceSheetManager.sol";

import {CastLib} from "../../misc/libraries/CastLib.sol";
import {IERC165} from "../../misc/interfaces/IERC165.sol";
import {SafeTransferLib} from "../../misc/libraries/SafeTransferLib.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {AssetId} from "../../core/types/AssetId.sol";
import {ISpoke} from "../../core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {ISpokeRegistry} from "../../core/spoke/interfaces/ISpokeRegistry.sol";
import {IManagerCallFromHub} from "../../core/utils/interfaces/IManagerCall.sol";

/// @title  OnOffRamp
/// @notice Balance sheet manager for depositing and withdrawing ERC20 assets with accounting token support.
///         - Onramping is permissionless: once an asset is allowed to be onramped and ERC20 assets have been
///           transferred to the manager, anyone can trigger the balance sheet deposit.
///         - Offramping is permissioned: only predefined relayers can trigger withdrawals to predefined
///           offramp accounts.
///         - Deposit mints a liability accounting token alongside the real asset deposit.
///         - Withdraw mints a non-liability accounting token as a receipt for the withdrawn asset.
contract OnOffRamp is IOnOffRamp {
    using CastLib for *;

    PoolId public immutable poolId;
    address public immutable envoy;
    ShareClassId public immutable scId;
    ISpoke public immutable spoke;
    IAccountingToken public immutable accountingToken;

    mapping(address asset => bool) public onramp;
    mapping(address relayer => bool) public relayer;
    mapping(address asset => mapping(address receiver => bool isEnabled)) public offramp;

    constructor(PoolId poolId_, ShareClassId scId_, address envoy_, ISpoke spoke_, IAccountingToken accountingToken_) {
        poolId = poolId_;
        scId = scId_;
        envoy = envoy_;
        spoke = spoke_;
        accountingToken = accountingToken_;
    }

    //----------------------------------------------------------------------------------------------
    // Hub actions
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IManagerCallFromHub
    /// @dev This manager is deployed per (poolId, scId); the call's poolId must match and the scId is implicit.
    function fromHub(PoolId poolId_, bytes calldata payload) external payable {
        require(poolId == poolId_, InvalidPoolId());
        require(msg.sender == envoy, NotEnvoy());
        require(msg.value == 0, UnexpectedValue());

        uint8 kindValue = abi.decode(payload, (uint8));
        require(kindValue <= uint8(type(TrustedCall).max), UnknownTrustedCall());

        TrustedCall kind = TrustedCall(kindValue);
        if (kind == TrustedCall.Onramp) {
            (, uint128 assetId, bool isEnabled) = abi.decode(payload, (uint8, uint128, bool));
            (address asset, uint256 tokenId) = spoke.spokeRegistry().idToAsset(AssetId.wrap(assetId), true);
            require(tokenId == 0, ERC6909NotSupported());

            onramp[asset] = isEnabled;

            if (isEnabled) SafeTransferLib.safeApprove(asset, address(spoke), type(uint256).max);
            else SafeTransferLib.safeApprove(asset, address(spoke), 0);

            emit UpdateOnramp(asset, isEnabled);
        } else if (kind == TrustedCall.Relayer) {
            (, bytes32 relayerAddress, bool isEnabled) = abi.decode(payload, (uint8, bytes32, bool));
            address relayer_ = relayerAddress.toAddress();

            relayer[relayer_] = isEnabled;
            emit UpdateRelayer(relayer_, isEnabled);
        } else if (kind == TrustedCall.Offramp) {
            (, uint128 assetId, bytes32 receiverAddress, bool isEnabled) =
                abi.decode(payload, (uint8, uint128, bytes32, bool));
            (address asset, uint256 tokenId) = spoke.spokeRegistry().idToAsset(AssetId.wrap(assetId), true);
            require(tokenId == 0, ERC6909NotSupported());
            address receiver = receiverAddress.toAddress();

            offramp[asset][receiver] = isEnabled;
            emit UpdateOfframp(asset, receiver, isEnabled);
        } else if (kind == TrustedCall.Withdraw) {
            (, uint128 assetId, uint128 amount, bytes32 receiverAddress) =
                abi.decode(payload, (uint8, uint128, uint128, bytes32));
            (address asset,) = spoke.spokeRegistry().idToAsset(AssetId.wrap(assetId), true);
            address receiver = receiverAddress.toAddress();

            require(offramp[asset][receiver], InvalidOfframpDestination());
            _withdraw(asset, amount, receiver);
            emit TrustedWithdraw(asset, amount, receiver);
        }
    }

    //----------------------------------------------------------------------------------------------
    // Deposit & withdraw actions
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IDepositManager
    function deposit(
        address asset,
        uint256,
        /* tokenId */
        uint128 amount,
        address /* owner */
    )
        external
    {
        require(onramp[asset], NotAllowedOnrampAsset());

        // Deposit real asset
        spoke.deposit(poolId, scId, asset, 0, amount);

        // Mint liability accounting token and deposit to the balance sheet
        uint256 liabTokenId = accountingToken.toTokenId(poolId, asset, true);
        accountingToken.mint(address(this), liabTokenId, amount, scId);
        accountingToken.approve(address(spoke), liabTokenId, amount);
        spoke.deposit(poolId, scId, address(accountingToken), liabTokenId, amount);
    }

    /// @inheritdoc IWithdrawManager
    function withdraw(
        address asset,
        uint256,
        /* tokenId */
        uint128 amount,
        address receiver
    )
        external
    {
        require(relayer[msg.sender], NotRelayer());
        _withdraw(asset, amount, receiver);
    }

    function _withdraw(address asset, uint128 amount, address receiver) internal {
        require(receiver != address(0) && offramp[asset][receiver], InvalidOfframpDestination());
        // Withdraw real asset to receiver
        spoke.withdraw(poolId, scId, asset, 0, receiver, amount);

        // Mint non-liability accounting token and deposit to the balance sheet
        uint256 accTokenId = accountingToken.toTokenId(poolId, asset, false);
        accountingToken.mint(address(this), accTokenId, amount, scId);
        accountingToken.approve(address(spoke), accTokenId, amount);
        spoke.deposit(poolId, scId, address(accountingToken), accTokenId, amount);
    }

    //----------------------------------------------------------------------------------------------
    // ERC-165
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return interfaceId == type(IDepositManager).interfaceId || interfaceId == type(IWithdrawManager).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }
}

contract OnOffRampFactory is IOnOffRampFactory {
    address public immutable envoy;
    ISpoke public immutable spoke;
    IAccountingToken public immutable accountingToken;

    constructor(address envoy_, ISpoke spoke_, IAccountingToken accountingToken_) {
        envoy = envoy_;
        spoke = spoke_;
        accountingToken = accountingToken_;
    }

    /// @inheritdoc IOnOffRampFactory
    function newManager(PoolId poolId, ShareClassId scId) external returns (IOnOffRamp) {
        require(spoke.spokeRegistry().hasShareClass(poolId, scId), ISpokeRegistry.ShareTokenDoesNotExist());

        OnOffRamp manager = new OnOffRamp{salt: _salt(poolId, scId)}(poolId, scId, envoy, spoke, accountingToken);

        emit DeployOnOffRamp(poolId, scId, address(manager));
        return IOnOffRamp(manager);
    }

    /// @inheritdoc IOnOffRampFactory
    function previewManager(PoolId poolId, ShareClassId scId) external view returns (address) {
        bytes32 hash =
            keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt(poolId, scId), _initCodeHash(poolId, scId)));
        return address(uint160(uint256(hash)));
    }

    function _initCodeHash(PoolId poolId, ShareClassId scId) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(type(OnOffRamp).creationCode, abi.encode(poolId, scId, envoy, spoke, accountingToken))
        );
    }

    /// @dev Deterministic CREATE2 salt so a (poolId, scId) maps to a fixed, previewable address.
    function _salt(PoolId poolId, ShareClassId scId) internal pure returns (bytes32) {
        return keccak256(abi.encode(poolId.raw(), scId.raw()));
    }
}
