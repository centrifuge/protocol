// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISafe} from "src/common/Guardian.sol";

import "forge-std/Script.sol";
import {FullDeployer} from "script/FullDeployer.s.sol";

contract TestDeployer is FullDeployer {
    function run() public override {
        super.run();

        vm.startBroadcast();
        _configureTestData();
        vm.stopBroadcast();
    }

    function _configureTestData() internal {
        // Deploy and register test USDC
        ERC20 token = new ERC20(6);
        token.file("name", "USD Coin");
        token.file("symbol", "USDC");
        token.mint(msg.sender, 10_000_000e6);
        poolManager.registerAsset(localCentrifugeId, address(token), 0);

        AssetId assetId = newAssetId(localCentrifugeId, 1);

        _deployAsyncVault(token, assetId);
        _deploySyncDepositVault(token, assetId);
    }

    function _deployAsyncVault(ERC20 token, AssetId assetId) internal {
        PoolId poolId = hubRegistry.poolId(localCentrifugeId, 1);
        hub.createPool(poolId, msg.sender, USD);
        hub.updateManager(poolId, vm.envAddress("ADMIN"), true);
        ShareClassId scId = shareClassManager.previewNextShareClassId(poolId);

        D18 navPerShare = d18(1, 1);

        hub.setPoolMetadata(poolId, bytes("Testing pool"));
        hub.addShareClass(poolId, "Tokenized MMF", "MMF", bytes32(bytes("1")));
        hub.notifyPool(poolId, localCentrifugeId);
        hub.notifyShareClass(poolId, scId, localCentrifugeId, bytes32(bytes20(redemptionRestrictionsHook)));

        hub.createAccount(poolId, AccountId.wrap(0x01), true);
        hub.createAccount(poolId, AccountId.wrap(0x02), false);
        hub.createAccount(poolId, AccountId.wrap(0x03), false);
        hub.createAccount(poolId, AccountId.wrap(0x04), false);
        hub.createHolding(
            poolId,
            scId,
            assetId,
            identityValuation,
            AccountId.wrap(0x01),
            AccountId.wrap(0x02),
            AccountId.wrap(0x03),
            AccountId.wrap(0x04)
        );

        hub.updateContract(
            poolId,
            scId,
            localCentrifugeId,
            bytes32(bytes20(address(poolManager))),
            MessageLib.UpdateContractVaultUpdate({
                vaultOrFactory: bytes32(bytes20(address(asyncVaultFactory))),
                assetId: assetId.raw(),
                kind: uint8(VaultUpdateKind.DeployAndLink)
            }).serialize()
        );

        hub.updatePricePerShare(poolId, scId, navPerShare);
        hub.notifySharePrice(poolId, scId, localCentrifugeId);
        hub.notifyAssetPrice(poolId, scId, assetId);

        // Submit deposit request
        IShareToken shareToken = IShareToken(poolManager.shareToken(poolId, scId));
        IAsyncVault vault = IAsyncVault(shareToken.vault(address(token)));

        token.approve(address(vault), 1_000_000e6);
        vault.requestDeposit(1_000_000e6, msg.sender, msg.sender);

        // Fulfill deposit request
        hub.approveDeposits(poolId, scId, assetId, shareClassManager.nowDepositEpoch(scId, assetId), 1_000_000e6);
        hub.issueShares(poolId, scId, assetId, shareClassManager.nowIssueEpoch(scId, assetId), d18(1, 1));

        uint32 maxClaims = shareClassManager.maxDepositClaims(scId, msg.sender.toBytes32(), assetId);
        hub.notifyDeposit(poolId, scId, assetId, msg.sender.toBytes32(), maxClaims);

        // Claim deposit request
        vault.mint(1_000_000e18, msg.sender);

        // Withdraw principal
        balanceSheet.withdraw(poolId, scId, address(token), 0, msg.sender, 1_000_000e6);

        // Update price, deposit principal + yield
        hub.updatePricePerShare(poolId, scId, d18(11, 10));
        hub.notifySharePrice(poolId, scId, localCentrifugeId);
        hub.notifyAssetPrice(poolId, scId, assetId);

        token.approve(address(balanceSheet), 1_100_000e18);
        balanceSheet.deposit(poolId, scId, address(token), 0, msg.sender, 1_100_000e6);

        // Make sender a member to submit redeem request
        hub.updateRestriction(
            poolId,
            scId,
            localCentrifugeId,
            MessageLib.UpdateRestrictionMember({user: bytes32(bytes20(msg.sender)), validUntil: type(uint64).max})
            .serialize()
        );

        // Submit redeem request
        vault.requestRedeem(1_000_000e18, msg.sender, msg.sender);

        // Fulfill redeem request
        hub.approveRedeems(poolId, scId, assetId, shareClassManager.nowRedeemEpoch(scId, assetId), 1_000_000e18);
        hub.revokeShares(poolId, scId, assetId, shareClassManager.nowRevokeEpoch(scId, assetId), d18(11, 10));

        hub.notifyRedeem(poolId, scId, assetId, bytes32(bytes20(msg.sender)), 1);

        // Claim redeem request
        vault.withdraw(1_100_000e6, msg.sender, msg.sender);
    }

    function _deploySyncDepositVault(ERC20 token, AssetId assetId) internal {
        PoolId poolId = hubRegistry.poolId(localCentrifugeId, 2);
        hub.createPool(poolId, msg.sender, USD);
        hub.updateManager(poolId, vm.envAddress("ADMIN"), true);
        ShareClassId scId = shareClassManager.previewNextShareClassId(poolId);

        D18 navPerShare = d18(1, 1);

        hub.setPoolMetadata(poolId, bytes("Testing pool"));
        hub.addShareClass(poolId, "RWA Portfolio", "RWA", bytes32(bytes("2")));
        hub.notifyPool(poolId, localCentrifugeId);
        hub.notifyShareClass(poolId, scId, localCentrifugeId, bytes32(bytes20(redemptionRestrictionsHook)));

        hub.createAccount(poolId, AccountId.wrap(0x01), true);
        hub.createAccount(poolId, AccountId.wrap(0x02), false);
        hub.createAccount(poolId, AccountId.wrap(0x03), false);
        hub.createAccount(poolId, AccountId.wrap(0x04), false);
        hub.createHolding(
            poolId,
            scId,
            assetId,
            identityValuation,
            AccountId.wrap(0x01),
            AccountId.wrap(0x02),
            AccountId.wrap(0x03),
            AccountId.wrap(0x04)
        );

        hub.updateContract(
            poolId,
            scId,
            localCentrifugeId,
            bytes32(bytes20(address(poolManager))),
            MessageLib.UpdateContractVaultUpdate({
                vaultOrFactory: bytes32(bytes20(address(syncDepositVaultFactory))),
                assetId: assetId.raw(),
                kind: uint8(VaultUpdateKind.DeployAndLink)
            }).serialize()
        );

        hub.updatePricePerShare(poolId, scId, navPerShare);
        hub.notifySharePrice(poolId, scId, localCentrifugeId);
        hub.notifyAssetPrice(poolId, scId, assetId);

        // Deposit
        IShareToken shareToken = IShareToken(poolManager.shareToken(poolId, scId));
        SyncDepositVault vault = SyncDepositVault(shareToken.vault(address(token)));

        uint128 investAmount = 1_000_000e6;
        token.approve(address(vault), investAmount);
        vault.deposit(investAmount, msg.sender);
    }
}
