// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {FullDeployer} from "./FullDeployer.s.sol";

import {ERC20} from "../src/misc/ERC20.sol";
import {D18, d18} from "../src/misc/types/D18.sol";
import {CastLib} from "../src/misc/libraries/CastLib.sol";

import {Guardian} from "../src/common/Guardian.sol";
import {PoolId} from "../src/common/types/PoolId.sol";
import {AccountId} from "../src/common/types/AccountId.sol";
import {ShareClassId} from "../src/common/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../src/common/types/AssetId.sol";
import {VaultUpdateKind} from "../src/common/libraries/MessageLib.sol";

import {Hub} from "../src/hub/Hub.sol";
import {HubRegistry} from "../src/hub/HubRegistry.sol";
import {ShareClassManager} from "../src/hub/ShareClassManager.sol";

import {Spoke} from "../src/spoke/Spoke.sol";
import {BalanceSheet} from "../src/spoke/BalanceSheet.sol";
import {IShareToken} from "../src/spoke/interfaces/IShareToken.sol";
import {UpdateContractMessageLib} from "../src/spoke/libraries/UpdateContractMessageLib.sol";

import {SyncManager} from "../src/vaults/SyncManager.sol";
import {SyncDepositVault} from "../src/vaults/SyncDepositVault.sol";
import {IAsyncVault} from "../src/vaults/interfaces/IAsyncVault.sol";
import {AsyncRequestManager} from "../src/vaults/AsyncRequestManager.sol";
import {AsyncVaultFactory} from "../src/vaults/factories/AsyncVaultFactory.sol";
import {SyncDepositVaultFactory} from "../src/vaults/factories/SyncDepositVaultFactory.sol";

import {RedemptionRestrictions} from "../src/hooks/RedemptionRestrictions.sol";
import {UpdateRestrictionMessageLib} from "../src/hooks/libraries/UpdateRestrictionMessageLib.sol";

import {IdentityValuation} from "../src/valuations/IdentityValuation.sol";

import "forge-std/Script.sol";

// Script to deploy Hub and Vaults with a Localhost Adapter.
contract TestData is FullDeployer {
    using CastLib for *;
    using UpdateRestrictionMessageLib for *;
    using UpdateContractMessageLib for *;

    uint128 constant DEFAULT_EXTRA_GAS = uint128(0);

    address public admin;

    function run() public override {
        string memory network = vm.envString("NETWORK");
        string memory configFile = string.concat("env/", network, ".json");
        string memory config = vm.readFile(configFile);

        uint16 centrifugeId = uint16(vm.parseJsonUint(config, "$.network.centrifugeId"));

        admin = vm.envAddress("ADMIN");
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
        asyncRequestManager = AsyncRequestManager(vm.parseJsonAddress(config, "$.contracts.asyncRequestManager"));
        syncManager = SyncManager(vm.parseJsonAddress(config, "$.contracts.syncManager"));
        guardian = Guardian(vm.parseJsonAddress(config, "$.contracts.guardian"));

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
        spoke.registerAsset(centrifugeId, address(token), 0);
        AssetId assetId = newAssetId(centrifugeId, 1);

        _deployAsyncVault(centrifugeId, token, assetId);
        _deploySyncDepositVault(centrifugeId, token, assetId);
    }

    function _deployAsyncVault(uint16 centrifugeId, ERC20 token, AssetId assetId) internal {
        PoolId poolId = hubRegistry.poolId(centrifugeId, 1);
        guardian.createPool(poolId, msg.sender, USD_ID);
        hub.updateHubManager(poolId, admin, true);
        ShareClassId scId = shareClassManager.previewNextShareClassId(poolId);

        D18 navPerShare = d18(1, 1);

        hub.setPoolMetadata(poolId, bytes("Testing pool"));
        hub.addShareClass(poolId, "Tokenized MMF", "MMF", bytes32(bytes("1")));
        hub.notifyPool(poolId, centrifugeId);
        hub.notifyShareClass(poolId, scId, centrifugeId, address(redemptionRestrictionsHook).toBytes32());

        hub.setRequestManager(poolId, scId, assetId, address(asyncRequestManager).toBytes32());
        hub.updateBalanceSheetManager(centrifugeId, poolId, address(asyncRequestManager).toBytes32(), true);
        // Add ADMIN as balance sheet manager to call submitQueuedAssets without going through the asyncRequestManager
        hub.updateBalanceSheetManager(centrifugeId, poolId, address(admin).toBytes32(), true);

        hub.createAccount(poolId, AccountId.wrap(0x01), true);
        hub.createAccount(poolId, AccountId.wrap(0x02), false);
        hub.createAccount(poolId, AccountId.wrap(0x03), false);
        hub.createAccount(poolId, AccountId.wrap(0x04), false);
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

        hub.updateVault(poolId, scId, assetId, address(asyncVaultFactory).toBytes32(), VaultUpdateKind.DeployAndLink, 0);

        hub.updateSharePrice(poolId, scId, navPerShare);
        hub.notifySharePrice(poolId, scId, centrifugeId);
        hub.notifyAssetPrice(poolId, scId, assetId);

        // Submit deposit request
        IShareToken shareToken = IShareToken(spoke.shareToken(poolId, scId));
        IAsyncVault vault = IAsyncVault(shareToken.vault(address(token)));

        token.approve(address(vault), 1_000_000e6);
        vault.requestDeposit(1_000_000e6, msg.sender, msg.sender);

        // Fulfill deposit request
        hub.approveDeposits(poolId, scId, assetId, shareClassManager.nowDepositEpoch(scId, assetId), 1_000_000e6);
        balanceSheet.submitQueuedAssets(poolId, scId, assetId, DEFAULT_EXTRA_GAS);

        // Withdraw principal
        balanceSheet.withdraw(poolId, scId, address(token), 0, msg.sender, 1_000_000e6);
        balanceSheet.submitQueuedAssets(poolId, scId, assetId, DEFAULT_EXTRA_GAS);

        // Issue and claim
        hub.issueShares(poolId, scId, assetId, shareClassManager.nowIssueEpoch(scId, assetId), d18(1, 1), 0);
        balanceSheet.submitQueuedShares(poolId, scId, DEFAULT_EXTRA_GAS);
        uint32 maxClaims = shareClassManager.maxDepositClaims(scId, msg.sender.toBytes32(), assetId);
        hub.notifyDeposit(poolId, scId, assetId, msg.sender.toBytes32(), maxClaims);
        vault.mint(1_000_000e18, msg.sender);

        // Update price, deposit principal + yield
        hub.updateSharePrice(poolId, scId, d18(11, 10));
        hub.notifySharePrice(poolId, scId, centrifugeId);
        hub.notifyAssetPrice(poolId, scId, assetId);

        // Make sender a member to submit redeem request
        hub.updateRestriction(
            poolId,
            scId,
            centrifugeId,
            UpdateRestrictionMessageLib.UpdateRestrictionMember({
                user: bytes32(bytes20(msg.sender)),
                validUntil: type(uint64).max
            }).serialize(),
            0
        );

        // Submit redeem request
        vault.requestRedeem(1_000_000e18, msg.sender, msg.sender);

        // Fulfill redeem request
        hub.approveRedeems(poolId, scId, assetId, shareClassManager.nowRedeemEpoch(scId, assetId), 1_000_000e18);
        hub.revokeShares(poolId, scId, assetId, shareClassManager.nowRevokeEpoch(scId, assetId), d18(11, 10), 0);
        balanceSheet.submitQueuedShares(poolId, scId, DEFAULT_EXTRA_GAS);
        hub.notifyRedeem(poolId, scId, assetId, bytes32(bytes20(msg.sender)), 1);

        // Deposit for withdraw
        token.approve(address(balanceSheet), 1_100_000e18);
        balanceSheet.deposit(poolId, scId, address(token), 0, 1_100_000e6);

        // Claim redeem request
        vault.withdraw(1_100_000e6, msg.sender, msg.sender);
        balanceSheet.submitQueuedAssets(poolId, scId, assetId, DEFAULT_EXTRA_GAS);

        // Deposit asset and init later
        ERC20 wBtc = new ERC20(18);
        wBtc.file("name", "Wrapped Bitcoin");
        wBtc.file("symbol", "wBTC");
        wBtc.mint(msg.sender, 10_000_000e18);
        spoke.registerAsset(centrifugeId, address(wBtc), 0);
        AssetId wBtcId = newAssetId(centrifugeId, 2);

        wBtc.approve(address(balanceSheet), 10e18);

        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeWithSelector(
            balanceSheet.overridePricePoolPerAsset.selector, poolId, scId, wBtcId, d18(100_000, 1)
        );
        calls[1] = abi.encodeWithSelector(balanceSheet.deposit.selector, poolId, scId, address(wBtc), 0, 10e18);
        calls[2] =
            abi.encodeWithSelector(balanceSheet.submitQueuedAssets.selector, poolId, scId, wBtcId, DEFAULT_EXTRA_GAS);
        balanceSheet.multicall(calls);

        hub.createAccount(poolId, AccountId.wrap(0x05), true);
        hub.initializeHolding(
            poolId,
            scId,
            wBtcId,
            identityValuation,
            AccountId.wrap(0x05),
            AccountId.wrap(0x02),
            AccountId.wrap(0x03),
            AccountId.wrap(0x04)
        );
        hub.updateHoldingValue(poolId, scId, wBtcId);
    }

    function _deploySyncDepositVault(uint16 centrifugeId, ERC20 token, AssetId assetId) internal {
        PoolId poolId = hubRegistry.poolId(centrifugeId, 2);
        guardian.createPool(poolId, msg.sender, USD_ID);
        hub.updateHubManager(poolId, admin, true);
        ShareClassId scId = shareClassManager.previewNextShareClassId(poolId);

        D18 navPerShare = d18(1, 1);

        hub.setPoolMetadata(poolId, bytes("Testing pool"));
        hub.addShareClass(poolId, "RWA Portfolio", "RWA", bytes32(bytes("2")));
        hub.notifyPool(poolId, centrifugeId);
        hub.notifyShareClass(poolId, scId, centrifugeId, address(redemptionRestrictionsHook).toBytes32());

        hub.setRequestManager(poolId, scId, assetId, address(asyncRequestManager).toBytes32());
        hub.updateBalanceSheetManager(centrifugeId, poolId, address(asyncRequestManager).toBytes32(), true);
        hub.updateBalanceSheetManager(centrifugeId, poolId, address(syncManager).toBytes32(), true);

        hub.createAccount(poolId, AccountId.wrap(0x01), true);
        hub.createAccount(poolId, AccountId.wrap(0x02), false);
        hub.createAccount(poolId, AccountId.wrap(0x03), false);
        hub.createAccount(poolId, AccountId.wrap(0x04), false);
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
            poolId, scId, assetId, address(syncDepositVaultFactory).toBytes32(), VaultUpdateKind.DeployAndLink, 0
        );

        hub.updateSharePrice(poolId, scId, navPerShare);
        hub.notifySharePrice(poolId, scId, centrifugeId);
        hub.notifyAssetPrice(poolId, scId, assetId);

        hub.updateContract(
            poolId,
            scId,
            centrifugeId,
            address(syncManager).toBytes32(),
            UpdateContractMessageLib.UpdateContractSyncDepositMaxReserve({
                assetId: assetId.raw(),
                maxReserve: type(uint128).max
            }).serialize(),
            0
        );

        // Deposit
        IShareToken shareToken = IShareToken(spoke.shareToken(poolId, scId));
        SyncDepositVault vault = SyncDepositVault(shareToken.vault(address(token)));

        uint128 investAmount = 1_000_000e6;
        token.approve(address(vault), investAmount);
        vault.deposit(investAmount, msg.sender);
    }
}
