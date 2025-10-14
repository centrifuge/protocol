// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LaunchDeployer} from "./LaunchDeployer.s.sol";

import {ERC20} from "../src/misc/ERC20.sol";
import {D18, d18} from "../src/misc/types/D18.sol";
import {CastLib} from "../src/misc/libraries/CastLib.sol";

import {Hub} from "../src/core/hub/Hub.sol";
import {Spoke} from "../src/core/spoke/Spoke.sol";
import {PoolId} from "../src/core/types/PoolId.sol";
import {AccountId} from "../src/core/types/AccountId.sol";
import {HubRegistry} from "../src/core/hub/HubRegistry.sol";
import {BalanceSheet} from "../src/core/spoke/BalanceSheet.sol";
import {ShareClassId} from "../src/core/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../src/core/types/AssetId.sol";
import {ShareClassManager} from "../src/core/hub/ShareClassManager.sol";
import {IShareToken} from "../src/core/spoke/interfaces/IShareToken.sol";
import {VaultUpdateKind} from "../src/core/messaging/libraries/MessageLib.sol";
import {IHubRequestManager} from "../src/core/hub/interfaces/IHubRequestManager.sol";

import {OpsGuardian} from "../src/admin/OpsGuardian.sol";
import {ProtocolGuardian} from "../src/admin/ProtocolGuardian.sol";

import {RedemptionRestrictions} from "../src/hooks/RedemptionRestrictions.sol";
import {UpdateRestrictionMessageLib} from "../src/hooks/libraries/UpdateRestrictionMessageLib.sol";

import {IdentityValuation} from "../src/valuations/IdentityValuation.sol";

import {SyncManager} from "../src/vaults/SyncManager.sol";
import {SyncDepositVault} from "../src/vaults/SyncDepositVault.sol";
import {IAsyncVault} from "../src/vaults/interfaces/IAsyncVault.sol";
import {AsyncRequestManager} from "../src/vaults/AsyncRequestManager.sol";
import {BatchRequestManager} from "../src/vaults/BatchRequestManager.sol";
import {AsyncVaultFactory} from "../src/vaults/factories/AsyncVaultFactory.sol";
import {SyncDepositVaultFactory} from "../src/vaults/factories/SyncDepositVaultFactory.sol";

import "forge-std/Script.sol";

import {UpdateContractMessageLib} from "../src/libraries/UpdateContractMessageLib.sol";

/**
 * @title BaseTestData
 * @notice Base contract with reusable pool and vault setup functions
 * @dev This contract contains common logic for setting up test pools and vaults,
 *      extracted from TestData.s.sol. The logic is identical to the original,
 *      just parameterized for reuse.
 */
abstract contract BaseTestData is LaunchDeployer {
    using CastLib for *;
    using UpdateRestrictionMessageLib for *;
    using UpdateContractMessageLib for *;

    uint128 constant DEFAULT_EXTRA_GAS = uint128(2_000_000);

    /**
     * @notice Load contract addresses from config JSON
     * @dev Used by all test scripts to initialize contract references
     */
    function loadContractsFromConfig(string memory config) internal {
        spoke = Spoke(vm.parseJsonAddress(config, "$.contracts.spoke"));
        hub = Hub(vm.parseJsonAddress(config, "$.contracts.hub"));
        shareClassManager = ShareClassManager(vm.parseJsonAddress(config, "$.contracts.shareClassManager"));
        redemptionRestrictionsHook =
            RedemptionRestrictions(vm.parseJsonAddress(config, "$.contracts.redemptionRestrictionsHook"));
        identityValuation = IdentityValuation(vm.parseJsonAddress(config, "$.contracts.identityValuation"));
        asyncVaultFactory = AsyncVaultFactory(vm.parseJsonAddress(config, "$.contracts.asyncVaultFactory"));
        syncDepositVaultFactory =
            SyncDepositVaultFactory(vm.parseJsonAddress(config, "$.contracts.syncDepositVaultFactory"));
        balanceSheet = BalanceSheet(vm.parseJsonAddress(config, "$.contracts.balanceSheet"));
        hubRegistry = HubRegistry(vm.parseJsonAddress(config, "$.contracts.hubRegistry"));
        asyncRequestManager =
            AsyncRequestManager(payable(vm.parseJsonAddress(config, "$.contracts.asyncRequestManager")));
        batchRequestManager = BatchRequestManager(vm.parseJsonAddress(config, "$.contracts.batchRequestManager"));
        syncManager = SyncManager(vm.parseJsonAddress(config, "$.contracts.syncManager"));
        protocolGuardian = ProtocolGuardian(vm.parseJsonAddress(config, "$.contracts.protocolGuardian"));
        opsGuardian = OpsGuardian(vm.parseJsonAddress(config, "$.contracts.opsGuardian"));
    }

    struct AsyncVaultParams {
        uint16 targetCentrifugeId; // centrifugeId where the vault will be deployed
        uint48 poolIndex; // pool index for this centrifugeId
        ERC20 token; // token for the vault
        AssetId assetId; // asset ID
        address admin; // admin address
        string poolMetadata; // pool metadata
        string shareClassName; // share class name
        string shareClassSymbol; // share class symbol
        bytes32 shareClassMeta; // share class metadata
    }

    struct SyncVaultParams {
        uint16 targetCentrifugeId; // centrifugeId where the vault will be deployed
        uint48 poolIndex; // pool index for this centrifugeId
        ERC20 token; // token for the vault
        AssetId assetId; // asset ID
        address admin; // admin address
        string poolMetadata; // pool metadata
        string shareClassName; // share class name
        string shareClassSymbol; // share class symbol
        bytes32 shareClassMeta; // share class metadata
    }

    /**
     * @notice Deploy an async vault with the given parameters
     * @dev This sends cross-chain messages if targetCentrifugeId differs from the hub's centrifugeId
     * @return poolId The pool ID
     * @return scId The share class ID
     */
    function deployAsyncVault(AsyncVaultParams memory params) internal returns (PoolId poolId, ShareClassId scId) {
        poolId = hubRegistry.poolId(params.targetCentrifugeId, params.poolIndex);
        asyncRequestManager.depositSubsidy{value: 0.5 ether}(poolId);

        // Create pool on hub
        opsGuardian.createPool(poolId, msg.sender, USD_ID);
        hub.updateHubManager(poolId, params.admin, true);
        scId = shareClassManager.previewNextShareClassId(poolId);

        D18 pricePoolPerShare = d18(1, 1);

        // Set metadata
        hub.setPoolMetadata(poolId, bytes(params.poolMetadata));
        hub.addShareClass(poolId, params.shareClassName, params.shareClassSymbol, params.shareClassMeta);
        
        // Notify target chain (sends cross-chain message if targetCentrifugeId is remote)
        hub.notifyPool(poolId, params.targetCentrifugeId, msg.sender);
        hub.notifyShareClass(
            poolId, scId, params.targetCentrifugeId, address(redemptionRestrictionsHook).toBytes32(), msg.sender
        );

        // Set request manager for target chain
        hub.setRequestManager(
            poolId,
            params.targetCentrifugeId,
            IHubRequestManager(batchRequestManager),
            address(asyncRequestManager).toBytes32(),
            msg.sender
        );
        
        // Update balance sheet manager for target chain
        hub.updateBalanceSheetManager(
            poolId, params.targetCentrifugeId, address(asyncRequestManager).toBytes32(), true, msg.sender
        );
        // Add admin as balance sheet manager
        hub.updateBalanceSheetManager(
            poolId, params.targetCentrifugeId, address(params.admin).toBytes32(), true, msg.sender
        );

        // Create accounts
        hub.createAccount(poolId, AccountId.wrap(0x01), true);
        hub.createAccount(poolId, AccountId.wrap(0x02), false);
        hub.createAccount(poolId, AccountId.wrap(0x03), false);
        hub.createAccount(poolId, AccountId.wrap(0x04), true);
        
        // Initialize holding
        hub.initializeHolding(
            poolId,
            scId,
            params.assetId,
            identityValuation,
            AccountId.wrap(0x01),
            AccountId.wrap(0x02),
            AccountId.wrap(0x03),
            AccountId.wrap(0x04)
        );

        // Deploy vault on target chain (sends cross-chain message if remote)
        hub.updateVault(
            poolId,
            scId,
            params.assetId,
            address(asyncVaultFactory).toBytes32(),
            VaultUpdateKind.DeployAndLink,
            0,
            msg.sender
        );

        // Update and notify prices
        hub.updateSharePrice(poolId, scId, pricePoolPerShare, uint64(block.timestamp));
        hub.notifySharePrice(poolId, scId, params.targetCentrifugeId, msg.sender);
        hub.notifyAssetPrice(poolId, scId, params.assetId, msg.sender);
    }

    /**
     * @notice Deploy a sync deposit vault with the given parameters
     * @dev This sends cross-chain messages if targetCentrifugeId differs from the hub's centrifugeId
     * @return poolId The pool ID
     * @return scId The share class ID
     */
    function deploySyncDepositVault(SyncVaultParams memory params)
        internal
        returns (PoolId poolId, ShareClassId scId)
    {
        poolId = hubRegistry.poolId(params.targetCentrifugeId, params.poolIndex);
        asyncRequestManager.depositSubsidy(poolId);

        // Create pool on hub
        opsGuardian.createPool(poolId, msg.sender, USD_ID);
        hub.updateHubManager(poolId, params.admin, true);
        scId = shareClassManager.previewNextShareClassId(poolId);

        D18 pricePoolPerShare = d18(1, 1);

        // Set metadata
        hub.setPoolMetadata(poolId, bytes(params.poolMetadata));
        hub.addShareClass(poolId, params.shareClassName, params.shareClassSymbol, params.shareClassMeta);
        
        // Notify target chain
        hub.notifyPool(poolId, params.targetCentrifugeId, msg.sender);
        hub.notifyShareClass(
            poolId, scId, params.targetCentrifugeId, address(redemptionRestrictionsHook).toBytes32(), msg.sender
        );

        // Set request manager
        hub.setRequestManager(
            poolId,
            params.targetCentrifugeId,
            IHubRequestManager(batchRequestManager),
            address(asyncRequestManager).toBytes32(),
            msg.sender
        );
        
        // Configure balance sheet managers
        hub.updateBalanceSheetManager(
            poolId, params.targetCentrifugeId, address(asyncRequestManager).toBytes32(), true, msg.sender
        );
        hub.updateBalanceSheetManager(
            poolId, params.targetCentrifugeId, address(syncManager).toBytes32(), true, msg.sender
        );

        // Create accounts
        hub.createAccount(poolId, AccountId.wrap(0x01), true);
        hub.createAccount(poolId, AccountId.wrap(0x02), false);
        hub.createAccount(poolId, AccountId.wrap(0x03), false);
        hub.createAccount(poolId, AccountId.wrap(0x04), true);
        
        // Initialize holding
        hub.initializeHolding(
            poolId,
            scId,
            params.assetId,
            identityValuation,
            AccountId.wrap(0x01),
            AccountId.wrap(0x02),
            AccountId.wrap(0x03),
            AccountId.wrap(0x04)
        );

        // Deploy vault on target chain
        hub.updateVault(
            poolId,
            scId,
            params.assetId,
            address(syncDepositVaultFactory).toBytes32(),
            VaultUpdateKind.DeployAndLink,
            0,
            msg.sender
        );

        // Update and notify prices
        hub.updateSharePrice(poolId, scId, pricePoolPerShare, uint64(block.timestamp));
        hub.notifySharePrice(poolId, scId, params.targetCentrifugeId, msg.sender);
        hub.notifyAssetPrice(poolId, scId, params.assetId, msg.sender);

        // Configure sync manager
        hub.updateContract(
            poolId,
            scId,
            params.targetCentrifugeId,
            address(syncManager).toBytes32(),
            UpdateContractMessageLib.UpdateContractSyncDepositMaxReserve({
                assetId: params.assetId.raw(),
                maxReserve: type(uint128).max
            }).serialize(),
            0,
            msg.sender
        );
    }

    /**
     * @notice Perform full async vault test flow (deposit, withdraw, issue, redeem, etc.)
     * @dev This is the full test flow from TestData.s.sol, extracted for reuse
     */
    function testAsyncVaultFlow(PoolId poolId, ShareClassId scId, AssetId assetId, ERC20 token, uint16 targetCentrifugeId)
        internal
    {
        // Get vault
        IShareToken shareToken = IShareToken(spoke.shareToken(poolId, scId));
        IAsyncVault vault = IAsyncVault(shareToken.vault(address(token)));

        // Submit deposit request
        token.approve(address(vault), 1_000_000e6);
        vault.requestDeposit(1_000_000e6, msg.sender, msg.sender);

        // Fulfill deposit request
        uint32 nowDepositEpoch = batchRequestManager.nowDepositEpoch(poolId, scId, assetId);
        batchRequestManager.approveDeposits(poolId, scId, assetId, nowDepositEpoch, 1_000_000e6, d18(1, 1), msg.sender);
        balanceSheet.submitQueuedAssets(poolId, scId, assetId, DEFAULT_EXTRA_GAS, msg.sender);

        // Withdraw principal
        balanceSheet.withdraw(poolId, scId, address(token), 0, msg.sender, 1_000_000e6);
        balanceSheet.submitQueuedAssets(poolId, scId, assetId, DEFAULT_EXTRA_GAS, msg.sender);

        // Issue and claim
        uint32 nowIssueEpoch = batchRequestManager.nowIssueEpoch(poolId, scId, assetId);
        batchRequestManager.issueShares(poolId, scId, assetId, nowIssueEpoch, d18(1, 1), 0, msg.sender);
        balanceSheet.submitQueuedShares(poolId, scId, DEFAULT_EXTRA_GAS, msg.sender);
        uint32 maxClaims =
            batchRequestManager.maxDepositClaims(poolId, scId, msg.sender.toBytes32(), assetId);
        batchRequestManager.notifyDeposit(poolId, scId, assetId, msg.sender.toBytes32(), maxClaims, msg.sender);
        vault.mint(1_000_000e18, msg.sender);

        // Update price, deposit principal + yield
        hub.updateSharePrice(poolId, scId, d18(11, 10), uint64(block.timestamp));
        hub.notifySharePrice(poolId, scId, targetCentrifugeId, msg.sender);
        hub.notifyAssetPrice(poolId, scId, assetId, msg.sender);

        // Make sender a member to submit redeem request
        hub.updateRestriction(
            poolId,
            scId,
            targetCentrifugeId,
            UpdateRestrictionMessageLib.UpdateRestrictionMember({
                user: bytes32(bytes20(msg.sender)),
                validUntil: type(uint64).max
            }).serialize(),
            0,
            msg.sender
        );

        // Submit redeem request
        vault.requestRedeem(1_000_000e18, msg.sender, msg.sender);

        // Fulfill redeem request
        uint32 nowRedeemEpoch = batchRequestManager.nowRedeemEpoch(poolId, scId, assetId);
        uint32 nowRevokeEpoch = batchRequestManager.nowRevokeEpoch(poolId, scId, assetId);

        batchRequestManager.approveRedeems(poolId, scId, assetId, nowRedeemEpoch, 1_000_000e18, d18(1, 1));
        batchRequestManager.revokeShares(poolId, scId, assetId, nowRevokeEpoch, d18(11, 10), 0, msg.sender);
        balanceSheet.submitQueuedShares(poolId, scId, DEFAULT_EXTRA_GAS, msg.sender);
        batchRequestManager.notifyRedeem(poolId, scId, assetId, bytes32(bytes20(msg.sender)), 1, msg.sender);

        // Deposit for withdraw
        token.approve(address(balanceSheet), 1_100_000e18);
        balanceSheet.deposit(poolId, scId, address(token), 0, 1_100_000e6);

        // Claim redeem request
        vault.withdraw(1_100_000e6, msg.sender, msg.sender);
        balanceSheet.submitQueuedAssets(poolId, scId, assetId, DEFAULT_EXTRA_GAS, msg.sender);

        // Test cancellation flow
        token.approve(address(vault), 500_000e6);
        vault.requestDeposit(500_000e6, msg.sender, msg.sender);
        vault.cancelDepositRequest(0, msg.sender);
        batchRequestManager.forceCancelDepositRequest(poolId, scId, msg.sender.toBytes32(), assetId, msg.sender);
        vault.claimCancelDepositRequest(0, msg.sender, msg.sender);
    }

    /**
     * @notice Perform sync vault test flow (simple deposit)
     * @dev This is the sync vault test flow from TestData.s.sol
     */
    function testSyncVaultFlow(PoolId poolId, ShareClassId scId, ERC20 token, uint128 investAmount) internal {
        IShareToken shareToken = IShareToken(spoke.shareToken(poolId, scId));
        SyncDepositVault vault = SyncDepositVault(shareToken.vault(address(token)));

        token.approve(address(vault), investAmount);
        vault.deposit(investAmount, msg.sender);
    }
}


