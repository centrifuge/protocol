// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "../../misc/types/D18.sol";
import {IERC20} from "../../misc/interfaces/IERC20.sol";
import {CastLib} from "../../misc/libraries/CastLib.sol";
import {IERC6909} from "../../misc/interfaces/IERC6909.sol";
import {IERC7575Share, IERC165} from "../../misc/interfaces/IERC7575.sol";
import {ETH_ADDRESS, IRecoverable} from "../../misc/interfaces/IRecoverable.sol";

import {Spoke} from "../../core/spoke/Spoke.sol";
import {PoolId} from "../../core/types/PoolId.sol";
import {AssetId} from "../../core/types/AssetId.sol";
import {HubRegistry} from "../../core/hub/HubRegistry.sol";
import {BalanceSheet} from "../../core/spoke/BalanceSheet.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {VaultKind} from "../../core/spoke/interfaces/IVault.sol";
import {MultiAdapter} from "../../core/messaging/MultiAdapter.sol";
import {ContractUpdater} from "../../core/utils/ContractUpdater.sol";
import {IAdapter} from "../../core/messaging/interfaces/IAdapter.sol";
import {ShareClassManager} from "../../core/hub/ShareClassManager.sol";
import {IShareToken} from "../../core/spoke/interfaces/IShareToken.sol";
import {PoolEscrow, IPoolEscrow} from "../../core/spoke/PoolEscrow.sol";
import {IVault, VaultKind} from "../../core/spoke/interfaces/IVault.sol";
import {MessageProcessor} from "../../core/messaging/MessageProcessor.sol";
import {MessageDispatcher} from "../../core/messaging/MessageDispatcher.sol";
import {VaultRegistry, VaultDetails} from "../../core/spoke/VaultRegistry.sol";
import {PoolEscrowFactory} from "../../core/spoke/factories/PoolEscrowFactory.sol";
import {IVaultFactory} from "../../core/spoke/factories/interfaces/IVaultFactory.sol";

import {Root} from "../../admin/Root.sol";
import {TokenRecoverer} from "../../admin/TokenRecoverer.sol";
import {ProtocolGuardian} from "../../admin/ProtocolGuardian.sol";

import {FreezeOnly} from "../../hooks/FreezeOnly.sol";
import {FullRestrictions} from "../../hooks/FullRestrictions.sol";
import {FreelyTransferable} from "../../hooks/FreelyTransferable.sol";
import {RedemptionRestrictions} from "../../hooks/RedemptionRestrictions.sol";

import {OnOfframpManagerFactory, OnOfframpManager, IOnOfframpManager} from "../../managers/spoke/OnOfframpManager.sol";

import {BaseVault} from "../../vaults/BaseVaults.sol";
import {SyncManager} from "../../vaults/SyncManager.sol";
import {VaultRouter} from "../../vaults/VaultRouter.sol";
import {AsyncRequestManager} from "../../vaults/AsyncRequestManager.sol";
import {REASON_REDEEM} from "../../vaults/interfaces/IVaultManagers.sol";
import {BatchRequestManager, EpochId} from "../../vaults/BatchRequestManager.sol";

import {RefundEscrowFactory} from "../../utils/RefundEscrowFactory.sol";

PoolId constant GLOBAL_POOL = PoolId.wrap(0);

contract MessageDispatcherInfallibleMock {
    uint16 _localCentrifugeId;

    constructor(uint16 localCentrifugeId_) {
        _localCentrifugeId = localCentrifugeId_;
    }

    function localCentrifugeId() external view returns (uint16) {
        return _localCentrifugeId;
    }
    function sendRegisterAsset(uint16 centrifugeId, AssetId assetId, uint8 decimals, address refund) external payable {}
}

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

struct AssetInfo {
    address addr;
    uint256 tokenId;
}

struct V3Contracts {
    Root root;
    address guardian;
    address tokenRecoverer;
    address messageDispatcher;
    address messageProcessor;
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

struct GlobalParamsInput {
    V3Contracts v3;
    Spoke spoke;
    BalanceSheet balanceSheet;
    HubRegistry hubRegistry;
    MultiAdapter multiAdapter;
    MessageDispatcher messageDispatcher;
    MessageProcessor messageProcessor;
    AsyncRequestManager asyncRequestManager;
    SyncManager syncManager;
    ProtocolGuardian protocolGuardian;
    TokenRecoverer tokenRecoverer;
    VaultRouter vaultRouter;

    AssetId[] spokeAssetIds;
    AssetId[] hubAssetIds;
    address[] vaults;
}

struct PoolParamsInput {
    V3Contracts v3;

    MultiAdapter multiAdapter;
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
    RefundEscrowFactory refundEscrowFactory;

    AssetId[] spokeAssetIds;
    AssetId[] hubAssetIds;
    address[] vaults;
    address[] bsManagers;
    AssetInfo[] assets;
    OnOfframpManager onOfframpManagerV3;
    address[] onOfframpReceivers;
    address[] onOfframpRelayers;

    address[] hubManagers;
    uint16[] chainsWherePoolIsNotified;
}

contract MigrationSpell {
    using CastLib for *;

    address public owner;
    string public constant description = "Migration from v3.0.1 to v3.1";

    constructor(address owner_) {
        owner = owner_;
    }

    function castGlobal(GlobalParamsInput memory input) external {
        require(owner == msg.sender, "not authorized");

        address[] memory contracts = _authorizedContracts(input);
        for (uint256 i; i < contracts.length; i++) {
            input.v3.root.relyContract(address(contracts[i]), address(this));
        }

        MessageDispatcherInfallibleMock messageDispatcherMock =
            new MessageDispatcherInfallibleMock(input.multiAdapter.localCentrifugeId());
        input.spoke.file("sender", address(messageDispatcherMock));

        _missingRootWards(input);
        _migrateGlobal(input);

        input.spoke.file("sender", address(input.messageDispatcher));

        for (uint256 i; i < contracts.length; i++) {
            input.v3.root.denyContract(address(contracts[i]), address(this));
        }
    }

    function castPool(PoolId poolId, PoolParamsInput memory input) external {
        require(owner == msg.sender, "not authorized");

        address[] memory contracts = _authorizedContracts(input);
        for (uint256 i; i < contracts.length; i++) {
            input.v3.root.relyContract(address(contracts[i]), address(this));
        }

        _migratePool(poolId, input);

        for (uint256 i; i < contracts.length; i++) {
            input.v3.root.denyContract(address(contracts[i]), address(this));
        }
    }

    /// @notice after migrate all pools, we need to lock the spell
    function lock(Root rootV3) external {
        require(owner == msg.sender, "not authorized");
        owner = address(0);

        rootV3.deny(address(this));
    }

    function _authorizedContracts(GlobalParamsInput memory input) internal pure returns (address[] memory) {
        address[] memory contracts = new address[](3);
        contracts[0] = address(input.spoke);
        contracts[1] = address(input.hubRegistry);
        contracts[2] = address(input.v3.gateway);
        return contracts;
    }

    function _authorizedContracts(PoolParamsInput memory input) internal pure returns (address[] memory) {
        address[] memory contracts = new address[](10);
        contracts[0] = address(input.spoke);
        contracts[1] = address(input.balanceSheet);
        contracts[2] = address(input.vaultRegistry);
        contracts[3] = address(input.hubRegistry);
        contracts[4] = address(input.shareClassManager);
        contracts[5] = address(input.syncManager);
        contracts[6] = address(input.batchRequestManager);
        contracts[7] = address(input.contractUpdater);
        contracts[8] = address(input.multiAdapter);
        contracts[9] = address(input.v3.gateway);
        return contracts;
    }

    /// @dev after deploying with an existing root, the following wards are missing and need to be fixed
    function _missingRootWards(GlobalParamsInput memory input) internal {
        input.v3.root.rely(address(input.protocolGuardian));
        input.v3.root.rely(address(input.tokenRecoverer));
        input.v3.root.rely(address(input.messageDispatcher));
        input.v3.root.rely(address(input.messageProcessor));
        input.v3.root.endorse(address(input.balanceSheet));
        input.v3.root.endorse(address(input.asyncRequestManager));
        input.v3.root.endorse(address(input.vaultRouter));

        // Remove access to root from v3 contracts
        input.v3.root.deny(address(input.v3.guardian));
        input.v3.root.deny(address(input.v3.tokenRecoverer));
        input.v3.root.deny(address(input.v3.messageDispatcher));
        input.v3.root.deny(address(input.v3.messageProcessor));
    }

    function _migrateGlobal(GlobalParamsInput memory input) internal {
        // ----- ASSETS -----
        for (uint256 i; i < input.spokeAssetIds.length; i++) {
            AssetId assetId = input.spokeAssetIds[i];
            (address addr, uint256 tokenId) = Spoke(input.v3.spoke).idToAsset(assetId);
            input.spoke.registerAsset(assetId.centrifugeId(), addr, tokenId, address(0));
        }

        for (uint256 i; i < input.hubAssetIds.length; i++) {
            AssetId assetId = input.hubAssetIds[i];
            if (assetId.centrifugeId() != 0) {
                uint8 decimals = HubRegistry(input.v3.hubRegistry).decimals(assetId);
                input.hubRegistry.registerAsset(assetId, decimals);
            }
        }

        // ----- GATEWAY -----
        // Transfer global pool funds from the gateway to msg.sender
        (uint96 subsidizedFunds,) = GatewayV3Like(input.v3.gateway).subsidy(GLOBAL_POOL);
        GatewayV3Like(input.v3.gateway).recoverTokens(ETH_ADDRESS, msg.sender, subsidizedFunds);

        // ----- VAULTS -----
        for (uint256 i; i < input.vaults.length; i++) {
            BaseVault vault = BaseVault(input.vaults[i]);
            input.v3.root.relyContract(address(vault), address(this));

            input.v3.root.relyContract(address(vault), address(input.asyncRequestManager));
            input.v3.root.relyContract(address(input.asyncRequestManager), address(vault));

            input.v3.root.denyContract(address(vault), address(input.v3.asyncRequestManager));
            input.v3.root.denyContract(address(input.v3.asyncRequestManager), address(vault));

            vault.file("manager", address(input.asyncRequestManager));
            vault.file("asyncRedeemManager", address(input.asyncRequestManager));

            if (vault.vaultKind() == VaultKind.SyncDepositAsyncRedeem) {
                input.v3.root.relyContract(address(vault), address(input.syncManager));
                input.v3.root.relyContract(address(input.syncManager), address(vault));

                input.v3.root.denyContract(address(vault), input.v3.syncManager);
                input.v3.root.denyContract(address(input.v3.syncManager), address(vault));

                vault.file("syncDepositManager", address(input.syncManager));
            }

            input.v3.root.denyContract(address(vault), address(this));
        }
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
            address refund =
                input.hubManagers.length > 0 ? input.hubManagers[0] : address(input.refundEscrowFactory.get(poolId));

            // ----- REFUND -----
            (uint96 subsidizedFunds,) = GatewayV3Like(input.v3.gateway).subsidy(poolId);
            if (subsidizedFunds > 0) {
                GatewayV3Like(input.v3.gateway).recoverTokens(ETH_ADDRESS, address(refund), subsidizedFunds);
            }

            IPoolEscrow poolEscrowV3 = PoolEscrowFactory(input.v3.poolEscrowFactory).escrow(poolId);
            if (address(poolEscrowV3).balance > 0) {
                input.v3.root.relyContract(address(poolEscrowV3), address(this));
                poolEscrowV3.recoverTokens(ETH_ADDRESS, address(refund), address(poolEscrowV3).balance);
                input.v3.root.denyContract(address(poolEscrowV3), address(this));
            }
        }
    }

    function _migratePoolInHub(PoolId poolId, ShareClassId scId, PoolParamsInput memory input) internal {
        // ----- MULTIADAPTER -----
        for (uint256 i; i < input.chainsWherePoolIsNotified.length; i++) {
            uint16 centrifugeId = input.chainsWherePoolIsNotified[i];
            if (poolId.centrifugeId() != centrifugeId) {
                IAdapter[] memory adapters = _getAdapters(input.multiAdapter, centrifugeId, poolId);
                input.multiAdapter
                    .setAdapters(centrifugeId, poolId, adapters, uint8(adapters.length), uint8(adapters.length));
            }
        }

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
                input.shareClassManager
                    .addShareClass(
                        poolId, scName, scSymbol, bytes32(abi.encodePacked(bytes8(poolId.raw()), bytes24(scSalt)))
                    );

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

        // ----- MULTIADAPTER -----
        if (input.multiAdapter.localCentrifugeId() != poolId.centrifugeId()) {
            IAdapter[] memory adapters = _getAdapters(input.multiAdapter, poolId.centrifugeId(), poolId);
            input.multiAdapter
                .setAdapters(poolId.centrifugeId(), poolId, adapters, uint8(adapters.length), uint8(adapters.length));
        }

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
            input.v3.root.relyContract(address(poolEscrowV3), address(this));
            input.v3.root.relyContract(address(poolEscrow), address(this));

            for (uint256 i; i < input.assets.length; i++) {
                AssetInfo memory assetInfo = input.assets[i];

                uint256 balance;
                try IERC20(assetInfo.addr).balanceOf(address(poolEscrowV3)) returns (uint256 balance_) {
                    balance = balance_;
                } catch {
                    IERC6909(assetInfo.addr).balanceOf(address(poolEscrowV3), assetInfo.tokenId);
                }

                if (balance > 0) {
                    bool isShare = false;
                    try IERC165(assetInfo.addr)
                        .supportsInterface(type(IERC7575Share).interfaceId) returns (bool result) {
                        isShare = result;
                    } catch {}

                    if (isShare) {
                        // NOTE: investment assets can be shares from other pools, special case for them:
                        address shareHook = IShareToken(assetInfo.addr).hook();
                        input.v3.root.relyContract(address(assetInfo.addr), address(this));
                        IShareToken(assetInfo.addr).file("hook", address(0)); // we don't want any restrictions

                        poolEscrowV3.authTransferTo(assetInfo.addr, assetInfo.tokenId, address(poolEscrow), balance);

                        IShareToken(assetInfo.addr).file("hook", shareHook);
                        input.v3.root.denyContract(address(assetInfo.addr), address(this));
                    } else {
                        poolEscrowV3.authTransferTo(assetInfo.addr, assetInfo.tokenId, address(poolEscrow), balance);
                    }
                }

                (uint128 total, uint128 reserved) =
                    PoolEscrow(address(poolEscrowV3)).holding(scId, assetInfo.addr, assetInfo.tokenId);

                if (total > 0 || reserved > 0) {
                    poolEscrow.deposit(scId, assetInfo.addr, assetInfo.tokenId, total);
                    // Migrate old reserved to new REDEEM bucket (all v3.0.1 reservations are from ARM revokedShares)
                    poolEscrow.reserve(
                        scId,
                        assetInfo.addr,
                        assetInfo.tokenId,
                        reserved,
                        address(input.asyncRequestManager),
                        REASON_REDEEM
                    );
                }
            }

            input.v3.root.denyContract(address(poolEscrow), address(this));
            input.v3.root.denyContract(address(poolEscrowV3), address(this));
        }

        // ----- SHARE_TOKEN -----
        if (address(shareToken) != address(0)) {
            input.v3.root.relyContract(address(shareToken), address(input.spoke));
            input.v3.root.relyContract(address(shareToken), address(input.balanceSheet));
            input.v3.root.denyContract(address(shareToken), address(input.v3.spoke));
            input.v3.root.denyContract(address(shareToken), address(input.v3.balanceSheet));

            address hookV3 = shareToken.hook();
            if (hookV3 != address(0)) {
                input.v3.root.relyContract(address(shareToken), address(this));
                if (hookV3 == input.v3.freezeOnly) {
                    shareToken.file("hook", address(input.freezeOnly));
                } else if (hookV3 == input.v3.fullRestrictions) {
                    shareToken.file("hook", address(input.fullRestrictions));
                } else if (hookV3 == input.v3.freelyTransferable) {
                    shareToken.file("hook", address(input.freelyTransferable));
                } else if (hookV3 == input.v3.redemptionRestrictions) {
                    shareToken.file("hook", address(input.redemptionRestrictions));
                }
                input.v3.root.denyContract(address(shareToken), address(this));
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
                AssetInfo memory assetInfo = input.assets[i];
                uint128 maxReserve =
                    SyncManager(input.v3.syncManager).maxReserve(poolId, scId, assetInfo.addr, assetInfo.tokenId);
                if (maxReserve > 0) {
                    input.syncManager.setMaxReserve(poolId, scId, assetInfo.addr, assetInfo.tokenId, maxReserve);
                }
            }
        }

        // ----- ON_OFFRAMP_MANAGER -----
        if (address(input.onOfframpManagerV3) != address(0)) {
            address onOfframpManager = address(input.onOfframpManagerFactory.newManager(poolId, scId));

            for (uint256 i; i < input.assets.length; i++) {
                AssetInfo memory assetInfo = input.assets[i];
                AssetId assetId = Spoke(input.v3.spoke).assetToId(assetInfo.addr, assetInfo.tokenId);
                if (input.onOfframpManagerV3.onramp(assetInfo.addr)) {
                    bytes memory message = abi.encode(IOnOfframpManager.TrustedCall.Onramp, assetId, true);
                    input.contractUpdater.trustedCall(poolId, scId, onOfframpManager, message);
                }

                for (uint256 j; j < input.onOfframpReceivers.length; j++) {
                    address receiver = input.onOfframpReceivers[j];
                    if (input.onOfframpManagerV3.offramp(assetInfo.addr, receiver)) {
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

    function _getAdapters(MultiAdapter multiAdapter, uint16 centrifugeId, PoolId poolId)
        private
        view
        returns (IAdapter[] memory adapters)
    {
        uint8 adapterCount = multiAdapter.quorum(centrifugeId, poolId);
        adapters = new IAdapter[](adapterCount);
        for (uint8 j; j < adapterCount; j++) {
            adapters[j] = multiAdapter.adapters(centrifugeId, poolId, j);
        }
    }
}
