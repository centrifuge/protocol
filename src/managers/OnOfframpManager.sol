// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IERC165} from "src/misc/interfaces/IERC165.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";

import {AssetId} from "src/common/types/AssetId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {IBalanceSheet} from "src/spoke/interfaces/IBalanceSheet.sol";
import {IUpdateContract} from "src/spoke/interfaces/IUpdateContract.sol";
import {UpdateContractType, UpdateContractMessageLib} from "src/spoke/libraries/UpdateContractMessageLib.sol";

import {IDepositManager, IWithdrawManager} from "src/managers/interfaces/IBalanceSheetManager.sol";
import {IOnOfframpManagerFactory} from "src/managers/interfaces/IOnOfframpManagerFactory.sol";
import {IOnOfframpManager} from "src/managers/interfaces/IOnOfframpManager.sol";

/// @title  OnOfframpManager
/// @notice Balance sheet manager for depositing and withdrawing ERC20 assets.
///         - Onramping is permissionless: once an asset is allowed to be onramped and ERC20 assets have been
///           transferred to the manager, anyone can trigger the balance sheet deposit.
///         - Offramping is permissioned: only predefined relayers can trigger withdrawals to predefined
///           offramp accounts.
contract OnOfframpManager is IOnOfframpManager {
    using CastLib for *;

    PoolId public immutable poolId;
    address public immutable spoke;
    ShareClassId public immutable scId;
    IBalanceSheet public immutable balanceSheet;

    mapping(address asset => bool) public onramp;
    mapping(address relayer => bool) public relayer;
    mapping(address asset => address receiver) public offramp;

    constructor(PoolId poolId_, ShareClassId scId_, address spoke_, IBalanceSheet balanceSheet_) {
        poolId = poolId_;
        scId = scId_;
        spoke = spoke_;
        balanceSheet = balanceSheet_;
    }

    //----------------------------------------------------------------------------------------------
    // Owner actions
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IUpdateContract
    function update(PoolId poolId_, ShareClassId, /* scId */ bytes calldata payload) external {
        require(poolId == poolId_, InvalidPoolId());
        require(msg.sender == spoke, NotSpoke());

        uint8 kind = uint8(UpdateContractMessageLib.updateContractType(payload));

        if (kind == uint8(UpdateContractType.UpdateAddress)) {
            UpdateContractMessageLib.UpdateContractUpdateAddress memory m =
                UpdateContractMessageLib.deserializeUpdateContractUpdateAddress(payload);

            if (m.kind == "onramp") {
                (address asset, uint256 tokenId) = balanceSheet.spoke().idToAsset(AssetId.wrap(m.assetId));
                require(tokenId == 0, ERC6909NotSupported());

                onramp[asset] = m.isEnabled;

                if (m.isEnabled) SafeTransferLib.safeApprove(asset, address(balanceSheet), type(uint256).max);
                else SafeTransferLib.safeApprove(asset, address(balanceSheet), 0);

                emit UpdateOnramp(asset, m.isEnabled);
            } else if (m.kind == "relayer") {
                address relayer_ = m.what.toAddress();

                relayer[relayer_] = m.isEnabled;
                emit UpdateRelayer(relayer_, m.isEnabled);
            } else if (m.kind == "offramp") {
                (address asset, uint256 tokenId) = balanceSheet.spoke().idToAsset(AssetId.wrap(m.assetId));
                require(tokenId == 0, ERC6909NotSupported());
                address receiver = m.what.toAddress();

                offramp[asset] = receiver;
                emit UpdateOfframp(asset, receiver);
            }
        } else {
            revert UnknownUpdateContractType();
        }
    }

    //----------------------------------------------------------------------------------------------
    // Deposit & withdraw actions
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IDepositManager
    function deposit(address asset, uint256, /* tokenId */ uint128 amount, address /* owner */ ) external {
        require(onramp[asset], NotAllowedOnrampAsset());

        balanceSheet.deposit(poolId, scId, asset, 0, amount);
    }

    /// @inheritdoc IWithdrawManager
    function withdraw(address asset, uint256, /* tokenId */ uint128 amount, address receiver) external {
        require(relayer[msg.sender], NotRelayer());
        require(receiver != address(0) && receiver == offramp[asset], InvalidOfframpDestination());

        balanceSheet.withdraw(poolId, scId, asset, 0, receiver, amount);
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

contract OnOfframpManagerFactory is IOnOfframpManagerFactory {
    address public immutable spoke;
    IBalanceSheet public immutable balanceSheet;

    constructor(address spoke_, IBalanceSheet balanceSheet_) {
        spoke = spoke_;
        balanceSheet = balanceSheet_;
    }

    /// @inheritdoc IOnOfframpManagerFactory
    function newManager(PoolId poolId, ShareClassId scId) external returns (IOnOfframpManager) {
        OnOfframpManager manager = new OnOfframpManager{salt: keccak256(abi.encode(poolId.raw(), scId.raw()))}(
            poolId, scId, spoke, balanceSheet
        );

        emit DeployOnOfframpManager(poolId, scId, address(manager));
        return IOnOfframpManager(manager);
    }
}
