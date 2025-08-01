// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IOnOfframpManager} from "./interfaces/IOnOfframpManager.sol";
import {IOnOfframpManagerFactory} from "./interfaces/IOnOfframpManagerFactory.sol";
import {IDepositManager, IWithdrawManager} from "./interfaces/IBalanceSheetManager.sol";

import {CastLib} from "../misc/libraries/CastLib.sol";
import {IERC165} from "../misc/interfaces/IERC165.sol";
import {SafeTransferLib} from "../misc/libraries/SafeTransferLib.sol";

import {PoolId} from "../common/types/PoolId.sol";
import {AssetId} from "../common/types/AssetId.sol";
import {ShareClassId} from "../common/types/ShareClassId.sol";

import {IBalanceSheet} from "../spoke/interfaces/IBalanceSheet.sol";
import {IUpdateContract} from "../spoke/interfaces/IUpdateContract.sol";
import {UpdateContractType, UpdateContractMessageLib} from "../spoke/libraries/UpdateContractMessageLib.sol";

/// @title  OnOfframpManager
/// @notice Balance sheet manager for depositing and withdrawing ERC20 assets.
///         - Onramping is permissionless: once an asset is allowed to be onramped and ERC20 assets have been
///           transferred to the manager, anyone can trigger the balance sheet deposit.
///         - Offramping is permissioned: only predefined relayers can trigger withdrawals to predefined
///           offramp accounts.
contract OnOfframpManager is IOnOfframpManager {
    using CastLib for *;

    PoolId public immutable poolId;
    address public immutable contractUpdater;
    ShareClassId public immutable scId;
    IBalanceSheet public immutable balanceSheet;

    mapping(address asset => bool) public onramp;
    mapping(address relayer => bool) public relayer;
    mapping(address asset => mapping(address receiver => bool isEnabled)) public offramp;

    constructor(PoolId poolId_, ShareClassId scId_, address spoke_, IBalanceSheet balanceSheet_) {
        poolId = poolId_;
        scId = scId_;
        contractUpdater = spoke_;
        balanceSheet = balanceSheet_;
    }

    //----------------------------------------------------------------------------------------------
    // Owner actions
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IUpdateContract
    function update(PoolId poolId_, ShareClassId scId_, bytes calldata payload) external {
        require(poolId == poolId_, InvalidPoolId());
        require(scId == scId_, InvalidShareClassId());
        require(msg.sender == contractUpdater, NotSpoke());

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

                offramp[asset][receiver] = m.isEnabled;
                emit UpdateOfframp(asset, receiver, m.isEnabled);
            } else {
                revert UnknownUpdateContractKind();
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
        require(receiver != address(0) && offramp[asset][receiver], InvalidOfframpDestination());

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
    address public immutable contractUpdater;
    IBalanceSheet public immutable balanceSheet;

    constructor(address contractUpdater_, IBalanceSheet balanceSheet_) {
        contractUpdater = contractUpdater_;
        balanceSheet = balanceSheet_;
    }

    /// @inheritdoc IOnOfframpManagerFactory
    function newManager(PoolId poolId, ShareClassId scId) external returns (IOnOfframpManager) {
        require(address(balanceSheet.spoke().shareToken(poolId, scId)) != address(0), InvalidIds());

        OnOfframpManager manager = new OnOfframpManager{salt: keccak256(abi.encode(poolId.raw(), scId.raw()))}(
            poolId, scId, contractUpdater, balanceSheet
        );

        emit DeployOnOfframpManager(poolId, scId, address(manager));
        return IOnOfframpManager(manager);
    }
}
