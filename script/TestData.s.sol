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
import {ISyncManager} from "../src/vaults/interfaces/IVaultManagers.sol";
import {AsyncRequestManager} from "../src/vaults/AsyncRequestManager.sol";
import {BatchRequestManager} from "../src/vaults/BatchRequestManager.sol";
import {AsyncVaultFactory} from "../src/vaults/factories/AsyncVaultFactory.sol";
import {SyncDepositVaultFactory} from "../src/vaults/factories/SyncDepositVaultFactory.sol";

import "forge-std/Script.sol";

// Script to deploy Hub and Vaults with a Localhost Adapter.
contract TestData is LaunchDeployer {
    using CastLib for *;
    using UpdateRestrictionMessageLib for *;

    uint128 constant DEFAULT_EXTRA_GAS = uint128(2_000_000);

    address public admin;

    function run() public override {
        string memory network = vm.envString("NETWORK");
        string memory configFile = string.concat("env/", network, ".json");
        string memory config = vm.readFile(configFile);

        uint16 centrifugeId = uint16(vm.parseJsonUint(config, "$.network.centrifugeId"));

        admin = vm.envAddress("PROTOCOL_ADMIN");
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

        vm.startBroadcast();
        _configureTestData(centrifugeId);
        vm.stopBroadcast();
    }

    function _configureTestData(uint16 centrifugeId) internal {
        // Deploy and register test USDC
        ERC20 token = new ERC20(6);
        token.file("name", "USD Coin");
        token.file("symbol", "USDC");
        token.mint(msg.sender, 10_000_000e6);
        spoke.registerAsset(centrifugeId, address(token), 0, msg.sender);
        AssetId assetId = newAssetId(centrifugeId, 1);

        _deployAsyncVault(centrifugeId, token, assetId);
        _deploySyncDepositVault(centrifugeId, token, assetId);
    }

    struct VaultState {
        PoolId poolId;
        ShareClassId scId;
        IAsyncVault vault;
        uint32 nowDepositEpoch;
        uint32 nowIssueEpoch;
        uint32 nowRedeemEpoch;
        uint32 nowRevokeEpoch;
    }

    function _deployAsyncVault(uint16 centrifugeId, ERC20 token, AssetId assetId) internal {
        VaultState memory state;
        state.poolId = hubRegistry.poolId(centrifugeId, 1);
        asyncRequestManager.depositSubsidy{value: 0.5 ether}(state.poolId);

        opsGuardian.createPool(state.poolId, msg.sender, USD_ID);
        hub.updateHubManager(state.poolId, admin, true);
        state.scId = shareClassManager.previewNextShareClassId(state.poolId);

        D18 pricePoolPerShare = d18(1, 1);

        hub.setPoolMetadata(state.poolId, bytes("Testing pool"));
        hub.addShareClass(state.poolId, "Tokenized MMF", "MMF", bytes32(bytes("1")));
        hub.notifyPool(state.poolId, centrifugeId, msg.sender);
        hub.notifyShareClass(
            state.poolId, state.scId, centrifugeId, address(redemptionRestrictionsHook).toBytes32(), msg.sender
        );

        hub.setRequestManager(
            state.poolId,
            centrifugeId,
            IHubRequestManager(batchRequestManager),
            address(asyncRequestManager).toBytes32(),
            msg.sender
        );
        hub.updateBalanceSheetManager(
            state.poolId, centrifugeId, address(asyncRequestManager).toBytes32(), true, msg.sender
        );
        // Add ADMIN as balance sheet manager to call submitQueuedAssets without going through the asyncRequestManager
        hub.updateBalanceSheetManager(state.poolId, centrifugeId, address(admin).toBytes32(), true, msg.sender);

        hub.createAccount(state.poolId, AccountId.wrap(0x01), true);
        hub.createAccount(state.poolId, AccountId.wrap(0x02), false);
        hub.createAccount(state.poolId, AccountId.wrap(0x03), false);
        hub.createAccount(state.poolId, AccountId.wrap(0x04), true);
        hub.initializeHolding(
            state.poolId,
            state.scId,
            assetId,
            identityValuation,
            AccountId.wrap(0x01),
            AccountId.wrap(0x02),
            AccountId.wrap(0x03),
            AccountId.wrap(0x04)
        );

        hub.updateVault(
            state.poolId,
            state.scId,
            assetId,
            address(asyncVaultFactory).toBytes32(),
            VaultUpdateKind.DeployAndLink,
            0,
            msg.sender
        );

        hub.updateSharePrice(state.poolId, state.scId, pricePoolPerShare, uint64(block.timestamp));
        hub.notifySharePrice(state.poolId, state.scId, centrifugeId, msg.sender);
        hub.notifyAssetPrice(state.poolId, state.scId, assetId, msg.sender);

        // Submit deposit request
        IShareToken shareToken = IShareToken(spoke.shareToken(state.poolId, state.scId));
        state.vault = IAsyncVault(shareToken.vault(address(token)));

        token.approve(address(state.vault), 1_000_000e6);
        state.vault.requestDeposit(1_000_000e6, msg.sender, msg.sender);

        // Fulfill deposit request
        state.nowDepositEpoch = batchRequestManager.nowDepositEpoch(state.poolId, state.scId, assetId);
        batchRequestManager.approveDeposits(
            state.poolId, state.scId, assetId, state.nowDepositEpoch, 1_000_000e6, d18(1, 1), msg.sender
        );
        balanceSheet.submitQueuedAssets(state.poolId, state.scId, assetId, DEFAULT_EXTRA_GAS, msg.sender);

        // Withdraw principal
        balanceSheet.withdraw(state.poolId, state.scId, address(token), 0, msg.sender, 1_000_000e6);
        balanceSheet.submitQueuedAssets(state.poolId, state.scId, assetId, DEFAULT_EXTRA_GAS, msg.sender);

        // Issue and claim
        state.nowIssueEpoch = batchRequestManager.nowIssueEpoch(state.poolId, state.scId, assetId);
        batchRequestManager.issueShares(
            state.poolId, state.scId, assetId, state.nowIssueEpoch, d18(1, 1), 0, msg.sender
        );
        balanceSheet.submitQueuedShares(state.poolId, state.scId, DEFAULT_EXTRA_GAS, msg.sender);
        uint32 maxClaims =
            batchRequestManager.maxDepositClaims(state.poolId, state.scId, msg.sender.toBytes32(), assetId);
        batchRequestManager.notifyDeposit(
            state.poolId, state.scId, assetId, msg.sender.toBytes32(), maxClaims, msg.sender
        );
        state.vault.mint(1_000_000e18, msg.sender);

        // Update price, deposit principal + yield
        hub.updateSharePrice(state.poolId, state.scId, d18(11, 10), uint64(block.timestamp));
        hub.notifySharePrice(state.poolId, state.scId, centrifugeId, msg.sender);
        hub.notifyAssetPrice(state.poolId, state.scId, assetId, msg.sender);

        // Make sender a member to submit redeem request
        hub.updateRestriction(
            state.poolId,
            state.scId,
            centrifugeId,
            UpdateRestrictionMessageLib.UpdateRestrictionMember({
                    user: bytes32(bytes20(msg.sender)), validUntil: type(uint64).max
                }).serialize(),
            0,
            msg.sender
        );

        // Submit redeem request
        state.vault.requestRedeem(1_000_000e18, msg.sender, msg.sender);

        // Fulfill redeem request
        state.nowRedeemEpoch = batchRequestManager.nowRedeemEpoch(state.poolId, state.scId, assetId);
        state.nowRevokeEpoch = batchRequestManager.nowRevokeEpoch(state.poolId, state.scId, assetId);

        batchRequestManager.approveRedeems(
            state.poolId, state.scId, assetId, state.nowRedeemEpoch, 1_000_000e18, d18(1, 1)
        );
        batchRequestManager.revokeShares(
            state.poolId, state.scId, assetId, state.nowRevokeEpoch, d18(11, 10), 0, msg.sender
        );
        balanceSheet.submitQueuedShares(state.poolId, state.scId, DEFAULT_EXTRA_GAS, msg.sender);
        batchRequestManager.notifyRedeem(state.poolId, state.scId, assetId, bytes32(bytes20(msg.sender)), 1, msg.sender);

        // Deposit for withdraw
        token.approve(address(balanceSheet), 1_100_000e18);
        balanceSheet.deposit(state.poolId, state.scId, address(token), 0, 1_100_000e6);

        // Claim redeem request
        state.vault.withdraw(1_100_000e6, msg.sender, msg.sender);
        balanceSheet.submitQueuedAssets(state.poolId, state.scId, assetId, DEFAULT_EXTRA_GAS, msg.sender);

        // Deposit asset and init later
        ERC20 wBtc = new ERC20(18);
        wBtc.file("name", "Wrapped Bitcoin");
        wBtc.file("symbol", "wBTC");
        wBtc.mint(msg.sender, 10_000_000e18);
        spoke.registerAsset(centrifugeId, address(wBtc), 0, msg.sender);
        AssetId wBtcId = newAssetId(centrifugeId, 2);

        wBtc.approve(address(balanceSheet), 10e18);

        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeWithSelector(
            balanceSheet.overridePricePoolPerAsset.selector, state.poolId, state.scId, wBtcId, d18(100_000, 1)
        );
        calls[1] =
            abi.encodeWithSelector(balanceSheet.deposit.selector, state.poolId, state.scId, address(wBtc), 0, 10e18);
        calls[2] = abi.encodeWithSelector(
            balanceSheet.submitQueuedAssets.selector, state.poolId, state.scId, wBtcId, DEFAULT_EXTRA_GAS, msg.sender
        );
        balanceSheet.multicall(calls);

        hub.createAccount(state.poolId, AccountId.wrap(0x05), true);
        hub.initializeHolding(
            state.poolId,
            state.scId,
            wBtcId,
            identityValuation,
            AccountId.wrap(0x05),
            AccountId.wrap(0x02),
            AccountId.wrap(0x03),
            AccountId.wrap(0x04)
        );
        hub.updateHoldingValue(state.poolId, state.scId, wBtcId);
    }

    function _deploySyncDepositVault(uint16 centrifugeId, ERC20 token, AssetId assetId) internal {
        PoolId poolId = hubRegistry.poolId(centrifugeId, 2);
        asyncRequestManager.depositSubsidy(poolId);

        opsGuardian.createPool(poolId, msg.sender, USD_ID);
        hub.updateHubManager(poolId, admin, true);
        ShareClassId scId = shareClassManager.previewNextShareClassId(poolId);

        D18 pricePoolPerShare = d18(1, 1);

        hub.setPoolMetadata(poolId, bytes("Testing pool"));
        hub.addShareClass(poolId, "RWA Portfolio", "RWA", bytes32(bytes("2")));
        hub.notifyPool(poolId, centrifugeId, msg.sender);
        hub.notifyShareClass(poolId, scId, centrifugeId, address(redemptionRestrictionsHook).toBytes32(), msg.sender);

        hub.setRequestManager(
            poolId,
            centrifugeId,
            IHubRequestManager(batchRequestManager),
            address(asyncRequestManager).toBytes32(),
            msg.sender
        );
        hub.updateBalanceSheetManager(poolId, centrifugeId, address(asyncRequestManager).toBytes32(), true, msg.sender);
        hub.updateBalanceSheetManager(poolId, centrifugeId, address(syncManager).toBytes32(), true, msg.sender);

        hub.createAccount(poolId, AccountId.wrap(0x01), true);
        hub.createAccount(poolId, AccountId.wrap(0x02), false);
        hub.createAccount(poolId, AccountId.wrap(0x03), false);
        hub.createAccount(poolId, AccountId.wrap(0x04), true);
        hub.initializeHolding(
            poolId,
            scId,
            assetId,
            identityValuation,
            AccountId.wrap(0x01),
            AccountId.wrap(0x02),
            AccountId.wrap(0x03),
            AccountId.wrap(0x04)
        );

        hub.updateVault(
            poolId,
            scId,
            assetId,
            address(syncDepositVaultFactory).toBytes32(),
            VaultUpdateKind.DeployAndLink,
            0,
            msg.sender
        );

        hub.updateSharePrice(poolId, scId, pricePoolPerShare, uint64(block.timestamp));
        hub.notifySharePrice(poolId, scId, centrifugeId, msg.sender);
        hub.notifyAssetPrice(poolId, scId, assetId, msg.sender);

        hub.updateContract(
            poolId,
            scId,
            centrifugeId,
            address(syncManager).toBytes32(),
            abi.encode(uint8(ISyncManager.TrustedCall.MaxReserve), assetId.raw(), type(uint128).max),
            0,
            msg.sender
        );

        // Deposit
        IShareToken shareToken = IShareToken(spoke.shareToken(poolId, scId));
        SyncDepositVault vault = SyncDepositVault(shareToken.vault(address(token)));

        uint128 investAmount = 1_000_000e6;
        token.approve(address(vault), investAmount);
        vault.deposit(investAmount, msg.sender);
    }
}
