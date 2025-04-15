// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "src/misc/ERC20.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";

import {ISafe} from "src/common/interfaces/IGuardian.sol";
import {VaultUpdateKind} from "src/common/libraries/MessageLib.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId, newAssetId} from "src/common/types/AssetId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {MessageLib, UpdateContractType, VaultUpdateKind} from "src/common/libraries/MessageLib.sol";

import {IShareToken} from "src/vaults/interfaces/token/IShareToken.sol";
import {IAsyncVault} from "src/vaults/interfaces/IERC7540.sol";

import {FullDeployer, HubDeployer, VaultsDeployer} from "script/FullDeployer.s.sol";

// Script to deploy Hub and Vaults with a Localhost Adapter.
contract LocalhostDeployer is FullDeployer {
    using CastLib for address;
    using MessageLib for *;

    uint256 defaultGas;

    function run() public {
        uint16 centrifugeId = uint16(vm.envUint("CENTRIFUGE_ID"));

        vm.startBroadcast();

        deployFull(centrifugeId, ISafe(vm.envAddress("ADMIN")), msg.sender, false);

        // Since `wire()` is not called, separately adding the safe here
        guardian.file("safe", address(adminSafe));

        saveDeploymentOutput();

        (, defaultGas) = gateway.estimate(centrifugeId, MessageLib.NotifyPool(1).serialize());
        _configureTestData(centrifugeId);

        vm.stopBroadcast();
    }

    function _configureTestData(uint16 centrifugeId) internal {
        // Deploy and register test USDC
        ERC20 token = new ERC20(6);
        token.file("name", "USD Coin");
        token.file("symbol", "USDC");
        token.mint(msg.sender, 10_000_000e6);

        vaultRouter.registerAsset{value: defaultGas}(centrifugeId, address(token), 0);
        AssetId assetId = newAssetId(centrifugeId, 1);

        _deployAsyncVault(centrifugeId, token, assetId);
        _deploySyncDepositVault(centrifugeId, token, assetId);
    }

    function _deployAsyncVault(uint16 centrifugeId, ERC20 token, AssetId assetId) internal {
        PoolId poolId = hub.createPool(msg.sender, USD);
        hub.allowPoolAdmin(poolId, vm.envAddress("ADMIN"), true);
        ShareClassId scId = shareClassManager.previewNextShareClassId(poolId);

        D18 navPerShare = d18(1, 1);

        hub.setPoolMetadata(poolId, bytes("Testing pool"));
        hub.addShareClass(poolId, "Tokenized MMF", "MMF", bytes32(bytes("1")), bytes(""));
        hub.notifyPool{value: defaultGas}(poolId, centrifugeId);
        hub.notifyShareClass{value: defaultGas}(poolId, centrifugeId, scId, bytes32(bytes20(freelyTransferable)));
        hub.createHolding(poolId, scId, assetId, identityValuation, false, 0x01);

        hub.updateContract(
            poolId,
            centrifugeId,
            scId,
            bytes32(bytes20(address(poolManager))),
            MessageLib.UpdateContractVaultUpdate({
                vaultOrFactory: bytes32(bytes20(address(asyncVaultFactory))),
                assetId: assetId.raw(),
                kind: uint8(VaultUpdateKind.DeployAndLink)
            }).serialize()
        );

        hub.updatePricePerShare(poolId, scId, navPerShare);
        hub.notifySharePrice(poolId, centrifugeId, scId);
        hub.notifyAssetPrice(poolId, scId, assetId);

        // Submit deposit request
        IShareToken shareToken = IShareToken(poolManager.shareToken(poolId.raw(), scId.raw()));
        IAsyncVault vault = IAsyncVault(shareToken.vault(address(token)));

        uint128 investAmount = 1_000_000e6;
        token.approve(address(vault), investAmount);
        vault.requestDeposit(investAmount, msg.sender, msg.sender);

        // Fulfill deposit request
        hub.approveDeposits(poolId, scId, assetId, shareClassManager.nowDepositEpoch(scId, assetId), investAmount);
        hub.issueShares(poolId, scId, assetId, shareClassManager.nowIssueEpoch(scId, assetId), navPerShare);

        uint32 maxClaims = shareClassManager.maxDepositClaims(scId, msg.sender.toBytes32(), assetId);
        hub.claimDeposit{value: 0.001 ether}(poolId, scId, assetId, msg.sender.toBytes32(), maxClaims);

        // Claim deposit request
        vault.mint(investAmount, msg.sender);
    }

    function _deploySyncDepositVault(uint16 centrifugeId, ERC20 token, AssetId assetId) internal {
        PoolId poolId = hub.createPool(msg.sender, USD);
        hub.allowPoolAdmin(poolId, vm.envAddress("ADMIN"), true);
        ShareClassId scId = shareClassManager.previewNextShareClassId(poolId);

        D18 navPerShare = d18(1, 1);

        hub.setPoolMetadata(poolId, bytes("Testing pool"));
        hub.addShareClass(poolId, "RWA Portfolio", "RWA", bytes32(bytes("2")), bytes(""));
        hub.notifyPool{value: defaultGas}(poolId, centrifugeId);
        hub.notifyShareClass{value: defaultGas}(poolId, centrifugeId, scId, bytes32(bytes20(freelyTransferable)));
        hub.createHolding(poolId, scId, assetId, identityValuation, false, 0x01);

        hub.updateContract(
            poolId,
            centrifugeId,
            scId,
            bytes32(bytes20(address(poolManager))),
            MessageLib.UpdateContractVaultUpdate({
                vaultOrFactory: bytes32(bytes20(address(syncDepositVaultFactory))),
                assetId: assetId.raw(),
                kind: uint8(VaultUpdateKind.DeployAndLink)
            }).serialize()
        );

        hub.updatePricePerShare(poolId, scId, navPerShare);
        hub.notifySharePrice(poolId, centrifugeId, scId);
        hub.notifyAssetPrice(poolId, scId, assetId);

        // Deposit
        IShareToken shareToken = IShareToken(poolManager.shareToken(poolId.raw(), scId.raw()));
        IAsyncVault vault = IAsyncVault(shareToken.vault(address(token)));

        uint128 investAmount = 1_000_000e6;
        token.approve(address(vault), investAmount);
        vault.deposit(investAmount, msg.sender);
    }
}
