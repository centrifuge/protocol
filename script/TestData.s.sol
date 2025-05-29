// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {ERC20} from "src/misc/ERC20.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {VaultUpdateKind} from "src/common/libraries/MessageLib.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId, newAssetId} from "src/common/types/AssetId.sol";
import {AccountId} from "src/common/types/AccountId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {UpdateRestrictionMessageLib} from "src/hooks/libraries/UpdateRestrictionMessageLib.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";
import {SyncDepositVault} from "src/vaults/SyncDepositVault.sol";
import {IAsyncVault} from "src/vaults/interfaces/IAsyncVault.sol";
import {IHub} from "src/hub/interfaces/IHub.sol";
import {ISpoke} from "src/spoke/interfaces/ISpoke.sol";
import {IShareClassManager} from "src/hub/interfaces/IShareClassManager.sol";
import {IBalanceSheet} from "src/hub/interfaces/IBalanceSheet.sol";

contract TestData is Script {
    using CastLib for *;
    using UpdateRestrictionMessageLib for *;

    struct Contracts {
        address admin;
        ISpoke spoke;
        IHub hub;
        IShareClassManager shareClassManager;
        address redemptionRestrictionsHook;
        address identityValuation;
        address asyncVaultFactory;
        address syncDepositVaultFactory;
        IBalanceSheet balanceSheet;
        bytes32 USD_ID;
    }

    function run() public {
        string memory network = vm.envString("NETWORK");
        string memory configFile = string.concat("env/", network, ".json");
        string memory config = vm.readFile(configFile);

        uint16 centrifugeId = uint16(vm.parseJsonUint(config, "$.network.centrifugeId"));
        
        Contracts memory contracts = Contracts({
            admin: vm.parseJsonAddress(config, "$.contracts.adminSafe"),
            spoke: ISpoke(vm.parseJsonAddress(config, "$.contracts.spoke")),
            hub: IHub(vm.parseJsonAddress(config, "$.contracts.hub")),
            shareClassManager: IShareClassManager(vm.parseJsonAddress(config, "$.contracts.shareClassManager")),
            redemptionRestrictionsHook: vm.parseJsonAddress(config, "$.contracts.redemptionRestrictionsHook"),
            identityValuation: vm.parseJsonAddress(config, "$.contracts.identityValuation"),
            asyncVaultFactory: vm.parseJsonAddress(config, "$.contracts.asyncVaultFactory"),
            syncDepositVaultFactory: vm.parseJsonAddress(config, "$.contracts.syncDepositVaultFactory"),
            balanceSheet: IBalanceSheet(vm.parseJsonAddress(config, "$.contracts.balanceSheet")),
            USD_ID: bytes32("USD")
        });

        vm.startBroadcast();
        _configureTestData(centrifugeId, contracts);
        vm.stopBroadcast();
    }

    function _configureTestData(uint16 centrifugeId, Contracts memory contracts) internal {
        // Deploy and register test USDC
        ERC20 token = new ERC20(6);
        token.file("name", "USD Coin");
        token.file("symbol", "USDC");
        token.mint(msg.sender, 10_000_000e6);
        contracts.spoke.registerAsset(centrifugeId, address(token), 0);

        AssetId assetId = newAssetId(centrifugeId, 1);

        _deployAsyncVault(centrifugeId, token, assetId, contracts);
        _deploySyncDepositVault(centrifugeId, token, assetId, contracts);
    }

    function _deployAsyncVault(uint16 centrifugeId, ERC20 token, AssetId assetId, Contracts memory contracts) internal {
        PoolId poolId = PoolId.wrap(bytes32(abi.encodePacked(centrifugeId, uint16(1))));
        contracts.hub.createPool(poolId, msg.sender, contracts.USD_ID);
        contracts.hub.updateHubManager(poolId, contracts.admin, true);
        ShareClassId scId = contracts.shareClassManager.previewNextShareClassId(poolId);

        D18 navPerShare = d18(1, 1);

        contracts.hub.setPoolMetadata(poolId, bytes("Testing pool"));
        contracts.hub.addShareClass(poolId, "Tokenized MMF", "MMF", bytes32(bytes("1")));
        contracts.hub.notifyPool(poolId, centrifugeId);
        contracts.hub.notifyShareClass(poolId, scId, centrifugeId, bytes32(bytes20(contracts.redemptionRestrictionsHook)));

        contracts.hub.createAccount(poolId, AccountId.wrap(0x01), true);
        contracts.hub.createAccount(poolId, AccountId.wrap(0x02), false);
        contracts.hub.createAccount(poolId, AccountId.wrap(0x03), false);
        contracts.hub.createAccount(poolId, AccountId.wrap(0x04), false);
        contracts.hub.initializeHolding(
            poolId,
            scId,
            assetId,
            contracts.identityValuation,
            AccountId.wrap(0x01),
            AccountId.wrap(0x02),
            AccountId.wrap(0x03),
            AccountId.wrap(0x04)
        );

        contracts.hub.updateVault(poolId, scId, assetId, address(contracts.asyncVaultFactory).toBytes32(), VaultUpdateKind.DeployAndLink);

        contracts.hub.updateSharePrice(poolId, scId, navPerShare);
        contracts.hub.notifySharePrice(poolId, scId, centrifugeId);
        contracts.hub.notifyAssetPrice(poolId, scId, assetId);

        // Submit deposit request
        IShareToken shareToken = IShareToken(contracts.spoke.shareToken(poolId, scId));
        IAsyncVault vault = IAsyncVault(shareToken.vault(address(token)));

        token.approve(address(vault), 1_000_000e6);
        vault.requestDeposit(1_000_000e6, msg.sender, msg.sender);

        // Fulfill deposit request
        contracts.hub.approveDeposits(poolId, scId, assetId, contracts.shareClassManager.nowDepositEpoch(scId, assetId), 1_000_000e6);
        contracts.hub.issueShares(poolId, scId, assetId, contracts.shareClassManager.nowIssueEpoch(scId, assetId), d18(1, 1));

        uint32 maxClaims = contracts.shareClassManager.maxDepositClaims(scId, msg.sender.toBytes32(), assetId);
        contracts.hub.notifyDeposit(poolId, scId, assetId, msg.sender.toBytes32(), maxClaims);

        // Claim deposit request
        vault.mint(1_000_000e18, msg.sender);

        // Withdraw principal
        contracts.balanceSheet.withdraw(poolId, scId, address(token), 0, msg.sender, 1_000_000e6);

        // Update price, deposit principal + yield
        contracts.hub.updateSharePrice(poolId, scId, d18(11, 10));
        contracts.hub.notifySharePrice(poolId, scId, centrifugeId);
        contracts.hub.notifyAssetPrice(poolId, scId, assetId);

        token.approve(address(contracts.balanceSheet), 1_100_000e18);
        contracts.balanceSheet.deposit(poolId, scId, address(token), 0, 1_100_000e6);

        // Make sender a member to submit redeem request
        contracts.hub.updateRestriction(
            poolId,
            scId,
            centrifugeId,
            UpdateRestrictionMessageLib.UpdateRestrictionMember({
                user: bytes32(bytes20(msg.sender)),
                validUntil: type(uint64).max
            }).serialize()
        );

        // Submit redeem request
        vault.requestRedeem(1_000_000e18, msg.sender, msg.sender);

        // Fulfill redeem request
        contracts.hub.approveRedeems(poolId, scId, assetId, contracts.shareClassManager.nowRedeemEpoch(scId, assetId), 1_000_000e18);
        contracts.hub.revokeShares(poolId, scId, assetId, contracts.shareClassManager.nowRevokeEpoch(scId, assetId), d18(11, 10));

        contracts.hub.notifyRedeem(poolId, scId, assetId, bytes32(bytes20(msg.sender)), 1);

        // Claim redeem request
        vault.withdraw(1_100_000e6, msg.sender, msg.sender);
    }

    function _deploySyncDepositVault(uint16 centrifugeId, ERC20 token, AssetId assetId, Contracts memory contracts) internal {
        PoolId poolId = PoolId.wrap(bytes32(abi.encodePacked(centrifugeId, uint16(2))));
        contracts.hub.createPool(poolId, msg.sender, contracts.USD_ID);
        contracts.hub.updateHubManager(poolId, contracts.admin, true);
        ShareClassId scId = contracts.shareClassManager.previewNextShareClassId(poolId);

        D18 navPerShare = d18(1, 1);

        contracts.hub.setPoolMetadata(poolId, bytes("Testing pool"));
        contracts.hub.addShareClass(poolId, "RWA Portfolio", "RWA", bytes32(bytes("2")));
        contracts.hub.notifyPool(poolId, centrifugeId);
        contracts.hub.notifyShareClass(poolId, scId, centrifugeId, bytes32(bytes20(contracts.redemptionRestrictionsHook)));

        contracts.hub.createAccount(poolId, AccountId.wrap(0x01), true);
        contracts.hub.createAccount(poolId, AccountId.wrap(0x02), false);
        contracts.hub.createAccount(poolId, AccountId.wrap(0x03), false);
        contracts.hub.createAccount(poolId, AccountId.wrap(0x04), false);
        contracts.hub.initializeHolding(
            poolId,
            scId,
            assetId,
            contracts.identityValuation,
            AccountId.wrap(0x01),
            AccountId.wrap(0x02),
            AccountId.wrap(0x03),
            AccountId.wrap(0x04)
        );

        contracts.hub.updateVault(
            poolId, scId, assetId, address(contracts.syncDepositVaultFactory).toBytes32(), VaultUpdateKind.DeployAndLink
        );

        contracts.hub.updateSharePrice(poolId, scId, navPerShare);
        contracts.hub.notifySharePrice(poolId, scId, centrifugeId);
        contracts.hub.notifyAssetPrice(poolId, scId, assetId);

        // Deposit
        IShareToken shareToken = IShareToken(contracts.spoke.shareToken(poolId, scId));
        SyncDepositVault vault = SyncDepositVault(shareToken.vault(address(token)));

        uint128 investAmount = 1_000_000e6;
        token.approve(address(vault), investAmount);
        vault.deposit(investAmount, msg.sender);
    }
} 