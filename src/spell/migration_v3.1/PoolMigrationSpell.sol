// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "../../misc/types/D18.sol";
import {IERC20} from "../../misc/interfaces/IERC20.sol";
import {CastLib} from "../../misc/libraries/CastLib.sol";
import {IERC7575Share, IERC165} from "../../misc/interfaces/IERC7575.sol";
import {ETH_ADDRESS, IRecoverable} from "../../misc/interfaces/IRecoverable.sol";

import {Spoke} from "../../core/spoke/Spoke.sol";
import {PoolId} from "../../core/types/PoolId.sol";
import {AssetId} from "../../core/types/AssetId.sol";
import {HubRegistry} from "../../core/hub/HubRegistry.sol";
import {BalanceSheet} from "../../core/spoke/BalanceSheet.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {ContractUpdater} from "../../core/utils/ContractUpdater.sol";
import {ShareClassManager} from "../../core/hub/ShareClassManager.sol";
import {IShareToken} from "../../core/spoke/interfaces/IShareToken.sol";
import {PoolEscrow, IPoolEscrow} from "../../core/spoke/PoolEscrow.sol";
import {IVault, VaultKind} from "../../core/spoke/interfaces/IVault.sol";
import {VaultRegistry, VaultDetails} from "../../core/spoke/VaultRegistry.sol";
import {PoolEscrowFactory} from "../../core/spoke/factories/PoolEscrowFactory.sol";
import {IVaultFactory} from "../../core/spoke/factories/interfaces/IVaultFactory.sol";

import {Root} from "../../admin/Root.sol";

import {FreezeOnly} from "../../hooks/FreezeOnly.sol";
import {FullRestrictions} from "../../hooks/FullRestrictions.sol";
import {FreelyTransferable} from "../../hooks/FreelyTransferable.sol";
import {RedemptionRestrictions} from "../../hooks/RedemptionRestrictions.sol";

import {OnOfframpManagerFactory, OnOfframpManager, IOnOfframpManager} from "../../managers/spoke/OnOfframpManager.sol";

import {SyncManager} from "../../vaults/SyncManager.sol";
import {AsyncRequestManager} from "../../vaults/AsyncRequestManager.sol";
import {BatchRequestManager, EpochId} from "../../vaults/BatchRequestManager.sol";

interface GatewayV3Like {
    function subsidy(PoolId) external view returns (uint96 value, IRecoverable refund);
    function recoverTokens(address token, address receiver, uint256 amount) external;
}

interface ShareClassManagerV3Like {
    function metadata(ShareClassId scId) external view returns (string memory name, string memory symbol, bytes32 salt);
    function metrics(ShareClassId scId) external view returns (uint128 totalIssuance, D18 navPerShare);
    function issuance(ShareClassId scId, uint16 centrifugeId) external view returns (uint128);
    function epochId(ShareClassId scId, AssetId assetId)
        external
        view
        returns (uint32 deposit, uint32 redeem, uint32 issue, uint32 revoke);
}

struct OldContracts {
    address gateway;
    address poolEscrowFactory;
    address spoke;
    address balanceSheet;
    address hubRegistry;
    address shareClassManager;
    address asyncVaultFactory;
    address asyncRequestManager;
    address syncDepositVaultFactory;
    address syncManager;
    address freezeOnly;
    address fullRestrictions;
    address freelyTransferable;
    address redemptionRestrictions;
}

struct PoolParamsInput {
    OldContracts v3;

    Root root;
    Spoke spoke;
    BalanceSheet balanceSheet;
    VaultRegistry vaultRegistry;
    HubRegistry hubRegistry;
    ShareClassManager shareClassManager;
    AsyncRequestManager asyncRequestManager;
    SyncManager syncManager;
    FreezeOnly freezeOnly;
    FullRestrictions fullRestrictions;
    FreelyTransferable freelyTransferable;
    RedemptionRestrictions redemptionRestrictions;
    OnOfframpManagerFactory onOfframpManagerFactory;
    BatchRequestManager batchRequestManager;
    ContractUpdater contractUpdater;

    AssetId[] spokeAssetIds;
    AssetId[] hubAssetIds;
    address[] vaults;
    address[] bsManagers;
    address[] assets;
    OnOfframpManager onOfframpManagerV3;
    address[] onOfframpReceivers;
    address[] onOfframpRelayers;

    address[] hubManagers;
    uint16[] chainsWherePoolIsNotified;
}

contract PoolMigrationSpell {
    using CastLib for *;

    address public owner;
    string public constant description = "Pool migration from v3.0.1 to v3.1";

    constructor(address owner_) {
        owner = owner_;
    }

    function castPool(PoolId poolId, PoolParamsInput memory input) external {
        require(owner == msg.sender, "not authorized");

        address[] memory contracts = _authorizedContracts(input);
        for (uint256 i; i < contracts.length; i++) {
            input.root.relyContract(address(contracts[i]), address(this));
        }

        _migratePool(poolId, input);

        for (uint256 i; i < contracts.length; i++) {
            input.root.denyContract(address(contracts[i]), address(this));
        }
    }

    /// @notice after migrate all pools, we need to lock the spell
    function lock() external {
        require(owner == msg.sender, "not authorized");
        owner = address(0);
    }

    function _authorizedContracts(PoolParamsInput memory input) internal pure returns (address[] memory) {
        address[] memory contracts = new address[](9);
        contracts[0] = address(input.spoke);
        contracts[1] = address(input.balanceSheet);
        contracts[2] = address(input.vaultRegistry);
        contracts[3] = address(input.hubRegistry);
        contracts[4] = address(input.shareClassManager);
        contracts[5] = address(input.syncManager);
        contracts[6] = address(input.batchRequestManager);
        contracts[7] = address(input.contractUpdater);
        contracts[8] = address(input.v3.gateway);
        return contracts;
    }

    function _migratePool(PoolId poolId, PoolParamsInput memory input) internal {
        ShareClassId scId = input.shareClassManager.previewNextShareClassId(poolId);
        bool inHub = HubRegistry(input.v3.hubRegistry).exists(poolId);
        bool inSpoke = Spoke(input.v3.spoke).isPoolActive(poolId);

        if (inHub) {
            _migratePoolInHub(poolId, scId, input);
        }

        if (inSpoke) {
            _migratePoolInSpoke(poolId, scId, input);
        }

        if (inHub || inSpoke) {
            // ----- REFUND -----
            address refund = input.hubManagers.length > 0
                ? input.hubManagers[0]
                : input.bsManagers.length > 0 ? input.bsManagers[0] : msg.sender;

            (uint96 subsidizedFunds,) = GatewayV3Like(input.v3.gateway).subsidy(poolId);
            if (subsidizedFunds > 0) {
                GatewayV3Like(input.v3.gateway).recoverTokens(ETH_ADDRESS, address(refund), subsidizedFunds);
            }

            IPoolEscrow poolEscrowV3 = PoolEscrowFactory(input.v3.poolEscrowFactory).escrow(poolId);
            if (address(poolEscrowV3).balance > 0) {
                input.root.relyContract(address(poolEscrowV3), address(this));
                poolEscrowV3.recoverTokens(ETH_ADDRESS, address(refund), address(poolEscrowV3).balance);
                input.root.denyContract(address(poolEscrowV3), address(this));
            }
        }
    }

    function _migratePoolInHub(PoolId poolId, ShareClassId scId, PoolParamsInput memory input) internal {
        // ---- HUB_REGISTRY -----
        AssetId currency = HubRegistry(input.v3.hubRegistry).currency(poolId);
        if (input.hubManagers.length > 0) {
            input.hubRegistry.registerPool(poolId, input.hubManagers[0], currency);
        } else {
            // For removed pools (pools without any manager)
            input.hubRegistry.registerPool(poolId, address(0), currency);
            input.hubRegistry.updateManager(poolId, address(0), false);
        }

        for (uint256 i = 1; i < input.hubManagers.length; i++) {
            input.hubRegistry.updateManager(poolId, input.hubManagers[i], true);
        }

        bytes memory metadata = HubRegistry(input.v3.hubRegistry).metadata(poolId);
        input.hubRegistry.setMetadata(poolId, metadata);

        for (uint256 i; i < input.chainsWherePoolIsNotified.length; i++) {
            input.hubRegistry
                .setHubRequestManager(poolId, input.chainsWherePoolIsNotified[i], input.batchRequestManager);
        }

        // ---- SHARE_CLASS_MANAGER -----
        {
            (string memory scName, string memory scSymbol, bytes32 scSalt) =
                ShareClassManagerV3Like(input.v3.shareClassManager).metadata(scId);
            if (bytes(scName).length > 0) {
                input.shareClassManager.addShareClass(poolId, scName, scSymbol, scSalt);

                (, D18 navPerShare) = ShareClassManagerV3Like(input.v3.shareClassManager).metrics(scId);
                input.shareClassManager.updateSharePrice(poolId, scId, navPerShare, uint64(block.timestamp));

                for (uint256 i; i < input.chainsWherePoolIsNotified.length; i++) {
                    uint16 centrifugeId = input.chainsWherePoolIsNotified[i];
                    (uint128 issuance) =
                        ShareClassManagerV3Like(input.v3.shareClassManager).issuance(scId, centrifugeId);
                    input.shareClassManager.updateShares(centrifugeId, poolId, scId, issuance, true);
                }
            }
        }

        // ----- BATCH_REQUEST_MANAGER -----
        for (uint256 i; i < input.hubAssetIds.length; i++) {
            AssetId assetId = input.hubAssetIds[i];
            (uint32 deposit, uint32 redeem, uint32 issue, uint32 revoke) =
                ShareClassManagerV3Like(input.v3.shareClassManager).epochId(scId, assetId);

            if (deposit != 0 || redeem != 0 || issue != 0 || revoke != 0) {
                EpochId memory newEpochIds = EpochId({deposit: deposit, redeem: redeem, issue: issue, revoke: revoke});
                input.batchRequestManager.setEpochIds(poolId, scId, assetId, newEpochIds);
            }
        }
    }

    function _migratePoolInSpoke(PoolId poolId, ShareClassId scId, PoolParamsInput memory input) internal {
        IShareToken shareToken;

        // ----- SPOKE -----
        input.spoke.addPool(poolId);
        input.spoke.setRequestManager(poolId, input.asyncRequestManager);

        try Spoke(input.v3.spoke).shareToken(poolId, scId) returns (IShareToken shareToken_) {
            shareToken = shareToken_;

            input.spoke.linkToken(poolId, scId, shareToken);

            (uint64 computedAt, uint64 maxAge,) = Spoke(input.v3.spoke).markersPricePoolPerShare(poolId, scId);
            (D18 price) = Spoke(input.v3.spoke).pricePoolPerShare(poolId, scId, false);
            input.spoke.updatePricePoolPerShare(poolId, scId, price, computedAt);
            input.spoke.setMaxSharePriceAge(poolId, scId, maxAge);

            for (uint256 i; i < input.spokeAssetIds.length; i++) {
                AssetId assetId = input.spokeAssetIds[i];
                (computedAt, maxAge,) = Spoke(input.v3.spoke).markersPricePoolPerAsset(poolId, scId, assetId);
                if (computedAt != 0) {
                    (price) = Spoke(input.v3.spoke).pricePoolPerAsset(poolId, scId, assetId, false);
                    input.spoke.updatePricePoolPerAsset(poolId, scId, assetId, price, computedAt);
                    input.spoke.setMaxAssetPriceAge(poolId, scId, assetId, maxAge);
                }
            }
        } catch {}

        // ----- BALANCE_SHEET -----
        for (uint256 i; i < input.bsManagers.length; i++) {
            address manager = input.bsManagers[i];
            if (manager == input.v3.asyncRequestManager) {
                manager = address(input.asyncRequestManager);
            } else if (manager == input.v3.syncManager) {
                manager = address(input.syncManager);
            }

            input.balanceSheet.updateManager(poolId, manager, true);
        }

        // ----- POOL_ESCROW (state) -----
        {
            IPoolEscrow poolEscrowV3 = BalanceSheet(input.v3.balanceSheet).escrow(poolId);
            IPoolEscrow poolEscrow = input.balanceSheet.escrow(poolId);
            input.root.relyContract(address(poolEscrowV3), address(this));
            input.root.relyContract(address(poolEscrow), address(this));

            for (uint256 i; i < input.assets.length; i++) {
                address asset = input.assets[i];

                uint256 balance = IERC20(asset).balanceOf(address(poolEscrowV3));
                if (balance > 0) {
                    bool isShare = false;
                    try IERC165(asset).supportsInterface(type(IERC7575Share).interfaceId) returns (bool isShare_) {
                        // NOTE: investment assets can be shares from other pools, special case for them:
                        if (isShare_) {
                            isShare = isShare_;

                            address shareHook = IShareToken(asset).hook();
                            input.root.relyContract(address(asset), address(this));
                            IShareToken(asset).file("hook", address(0)); // we don't want any restrictions

                            poolEscrowV3.authTransferTo(asset, 0, address(poolEscrow), balance);

                            IShareToken(asset).file("hook", shareHook);
                            input.root.denyContract(address(asset), address(this));
                        }
                    } catch {}

                    if (!isShare) {
                        poolEscrowV3.authTransferTo(asset, 0, address(poolEscrow), balance);
                    }
                }

                (uint128 total, uint128 reserved) = PoolEscrow(address(poolEscrowV3)).holding(scId, asset, 0);
                if (total > 0 || reserved > 0) {
                    poolEscrow.deposit(scId, asset, 0, total);
                    poolEscrow.reserve(scId, asset, 0, reserved);
                }
            }

            input.root.denyContract(address(poolEscrow), address(this));
            input.root.denyContract(address(poolEscrowV3), address(this));
        }

        // ----- SHARE_TOKEN -----
        if (address(shareToken) != address(0)) {
            input.root.relyContract(address(shareToken), address(input.spoke));
            input.root.relyContract(address(shareToken), address(input.balanceSheet));
            input.root.denyContract(address(shareToken), address(input.v3.spoke));
            input.root.denyContract(address(shareToken), address(input.v3.balanceSheet));

            address hookV3 = shareToken.hook();
            if (hookV3 != address(0)) {
                input.root.relyContract(address(shareToken), address(this));
                if (hookV3 == input.v3.freezeOnly) {
                    shareToken.file("hook", address(input.freezeOnly));
                } else if (hookV3 == input.v3.fullRestrictions) {
                    shareToken.file("hook", address(input.fullRestrictions));
                } else if (hookV3 == input.v3.freelyTransferable) {
                    shareToken.file("hook", address(input.freelyTransferable));
                } else if (hookV3 == input.v3.redemptionRestrictions) {
                    shareToken.file("hook", address(input.redemptionRestrictions));
                }
                input.root.denyContract(address(shareToken), address(this));
            }
        }

        // ----- VAULT_REGISTRY -----
        for (uint256 i; i < input.vaults.length; i++) {
            IVault vault = IVault(input.vaults[i]);
            if (vault.poolId() == poolId && vault.scId() == scId) {
                address factory = (vault.vaultKind() == VaultKind.Async)
                    ? input.v3.asyncVaultFactory
                    : input.v3.syncDepositVaultFactory;

                VaultDetails memory details = VaultRegistry(input.v3.spoke).vaultDetails(vault);
                input.vaultRegistry
                    .registerVault(
                        poolId, scId, details.assetId, details.asset, details.tokenId, IVaultFactory(factory), vault
                    );

                if (details.isLinked) {
                    input.vaultRegistry.linkVault(poolId, scId, details.assetId, vault);
                }
            }
        }

        // ----- SYNC_MANAGER -----
        {
            address valuation = address(SyncManager(input.v3.syncManager).valuation(poolId, scId));
            if (valuation != address(0)) {
                input.syncManager.setValuation(poolId, scId, valuation);
            }

            for (uint256 i; i < input.assets.length; i++) {
                address asset = input.assets[i];
                uint128 maxReserve = SyncManager(input.v3.syncManager).maxReserve(poolId, scId, asset, 0);
                if (maxReserve > 0) {
                    input.syncManager.setMaxReserve(poolId, scId, asset, 0, maxReserve);
                }
            }
        }

        // ----- ON_OFFRAMP_MANAGER -----
        if (address(input.onOfframpManagerV3) != address(0)) {
            address onOfframpManager = address(input.onOfframpManagerFactory.newManager(poolId, scId));

            for (uint256 i; i < input.assets.length; i++) {
                address asset = input.assets[i];
                AssetId assetId = Spoke(input.v3.spoke).assetToId(asset, 0);
                if (input.onOfframpManagerV3.onramp(asset)) {
                    bytes memory message = abi.encode(IOnOfframpManager.TrustedCall.Onramp, assetId, true);
                    input.contractUpdater.trustedCall(poolId, scId, onOfframpManager, message);
                }

                for (uint256 j; j < input.onOfframpReceivers.length; j++) {
                    address receiver = input.onOfframpReceivers[j];
                    if (input.onOfframpManagerV3.offramp(asset, receiver)) {
                        bytes memory message =
                            abi.encode(IOnOfframpManager.TrustedCall.Offramp, assetId, receiver.toBytes32(), true);
                        input.contractUpdater.trustedCall(poolId, scId, onOfframpManager, message);
                    }
                }
            }

            for (uint256 i; i < input.onOfframpRelayers.length; i++) {
                address relayer = input.onOfframpRelayers[i];
                if (input.onOfframpManagerV3.relayer(relayer)) {
                    bytes memory message = abi.encode(IOnOfframpManager.TrustedCall.Relayer, relayer.toBytes32(), true);
                    input.contractUpdater.trustedCall(poolId, scId, onOfframpManager, message);
                }
            }
        }
    }
}
