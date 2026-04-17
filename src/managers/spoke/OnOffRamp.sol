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
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {ITrustedContractUpdate} from "../../core/utils/interfaces/IContractUpdate.sol";
import {IBalanceSheet, WithdrawMode} from "../../core/spoke/interfaces/IBalanceSheet.sol";

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
    address public immutable contractUpdater;
    ShareClassId public immutable scId;
    IBalanceSheet public immutable balanceSheet;
    IAccountingToken public immutable accountingToken;

    mapping(address asset => bool) public onramp;
    mapping(address relayer => bool) public relayer;
    mapping(address asset => mapping(address receiver => bool isEnabled)) public offramp;

    constructor(
        PoolId poolId_,
        ShareClassId scId_,
        address contractUpdater_,
        IBalanceSheet balanceSheet_,
        IAccountingToken accountingToken_
    ) {
        poolId = poolId_;
        scId = scId_;
        contractUpdater = contractUpdater_;
        balanceSheet = balanceSheet_;
        accountingToken = accountingToken_;
    }

    //----------------------------------------------------------------------------------------------
    // Owner actions
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ITrustedContractUpdate
    function trustedCall(PoolId poolId_, ShareClassId scId_, bytes memory payload) external {
        require(poolId == poolId_, InvalidPoolId());
        require(scId == scId_, InvalidShareClassId());
        require(msg.sender == contractUpdater, NotContractUpdater());

        uint8 kindValue = abi.decode(payload, (uint8));
        require(kindValue <= uint8(type(TrustedCall).max), UnknownTrustedCall());

        TrustedCall kind = TrustedCall(kindValue);
        if (kind == TrustedCall.Onramp) {
            (, uint128 assetId, bool isEnabled) = abi.decode(payload, (uint8, uint128, bool));
            (address asset, uint256 tokenId) = balanceSheet.spoke().idToAsset(AssetId.wrap(assetId));
            require(tokenId == 0, ERC6909NotSupported());

            onramp[asset] = isEnabled;

            if (isEnabled) SafeTransferLib.safeApprove(asset, address(balanceSheet), type(uint256).max);
            else SafeTransferLib.safeApprove(asset, address(balanceSheet), 0);

            emit UpdateOnramp(asset, isEnabled);
        } else if (kind == TrustedCall.Relayer) {
            (, bytes32 relayerAddress, bool isEnabled) = abi.decode(payload, (uint8, bytes32, bool));
            address relayer_ = relayerAddress.toAddress();

            relayer[relayer_] = isEnabled;
            emit UpdateRelayer(relayer_, isEnabled);
        } else if (kind == TrustedCall.Offramp) {
            (, uint128 assetId, bytes32 receiverAddress, bool isEnabled) =
                abi.decode(payload, (uint8, uint128, bytes32, bool));
            (address asset, uint256 tokenId) = balanceSheet.spoke().idToAsset(AssetId.wrap(assetId));
            require(tokenId == 0, ERC6909NotSupported());
            address receiver = receiverAddress.toAddress();

            offramp[asset][receiver] = isEnabled;
            emit UpdateOfframp(asset, receiver, isEnabled);
        } else if (kind == TrustedCall.Withdraw) {
            (, uint128 assetId, uint128 amount, bytes32 receiverAddress) =
                abi.decode(payload, (uint8, uint128, uint128, bytes32));
            (address asset,) = balanceSheet.spoke().idToAsset(AssetId.wrap(assetId));
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
        balanceSheet.deposit(poolId, scId, asset, 0, amount);

        // Mint liability accounting token and deposit to BalanceSheet
        uint256 liabTokenId = accountingToken.toTokenId(poolId, asset, true);
        accountingToken.mint(address(this), liabTokenId, amount, scId);
        accountingToken.approve(address(balanceSheet), liabTokenId, amount);
        balanceSheet.deposit(poolId, scId, address(accountingToken), liabTokenId, amount);
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
        require(receiver != address(0) && offramp[asset][receiver], InvalidOfframpDestination());
        _withdraw(asset, amount, receiver);
    }

    function _withdraw(address asset, uint128 amount, address receiver) internal {
        // Withdraw real asset to receiver
        balanceSheet.withdraw(poolId, scId, asset, 0, receiver, amount, WithdrawMode.Full);

        // Mint non-liability accounting token and deposit to BalanceSheet
        uint256 accTokenId = accountingToken.toTokenId(poolId, asset, false);
        accountingToken.mint(address(this), accTokenId, amount, scId);
        accountingToken.approve(address(balanceSheet), accTokenId, amount);
        balanceSheet.deposit(poolId, scId, address(accountingToken), accTokenId, amount);
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
    address public immutable contractUpdater;
    IBalanceSheet public immutable balanceSheet;
    IAccountingToken public immutable accountingToken;

    constructor(address contractUpdater_, IBalanceSheet balanceSheet_, IAccountingToken accountingToken_) {
        contractUpdater = contractUpdater_;
        balanceSheet = balanceSheet_;
        accountingToken = accountingToken_;
    }

    /// @inheritdoc IOnOffRampFactory
    function newManager(PoolId poolId, ShareClassId scId) external returns (IOnOffRamp) {
        balanceSheet.spoke().shareToken(poolId, scId); // Check for existence

        OnOffRamp manager = new OnOffRamp{salt: keccak256(abi.encode(poolId.raw(), scId.raw()))}(
            poolId, scId, contractUpdater, balanceSheet, accountingToken
        );

        emit DeployOnOffRamp(poolId, scId, address(manager));
        return IOnOffRamp(manager);
    }
}
