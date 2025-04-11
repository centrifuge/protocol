// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "src/misc/ERC20.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";

import {ISafe} from "src/common/interfaces/IGuardian.sol";
import {VaultUpdateKind} from "src/common/libraries/MessageLib.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId, newAssetId} from "src/common/types/AssetId.sol";
import {AccountId} from "src/common/types/AccountId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {MessageLib, UpdateContractType, VaultUpdateKind} from "src/common/libraries/MessageLib.sol";

import {IShareToken} from "src/vaults/interfaces/token/IShareToken.sol";
import {IAsyncVault} from "src/vaults/interfaces/IERC7540.sol";

import {FullDeployer, HubDeployer, VaultsDeployer} from "script/FullDeployer.s.sol";

// Script to deploy CP and CP with an Localhost Adapter.
contract LocalhostDeployer is FullDeployer {
    using MessageLib for *;

    function run() public {
        uint16 centrifugeId = uint16(vm.envUint("CENTRIFUGE_ID"));

        vm.startBroadcast();

        deployFull(centrifugeId, ISafe(vm.envAddress("ADMIN")), msg.sender);

        // Since `wire()` is not called, separately adding the safe here
        guardian.file("safe", address(adminSafe));

        saveDeploymentOutput();

        _configureTestData(centrifugeId);

        vm.stopBroadcast();
    }

    function _configureTestData(uint16 centrifugeId) internal {
        // Create pool
        PoolId poolId = hub.createPool(msg.sender, USD);
        ShareClassId scId = shareClassManager.previewNextShareClassId(poolId);

        // Deploy and register test USDC
        ERC20 token = new ERC20(6);
        token.file("name", "USD Coin");
        token.file("symbol", "USDC");
        token.mint(msg.sender, 10_000_000e6);
        vaultRouter.registerAsset{value: 0.001 ether}(centrifugeId, address(token), 0);

        // Deploy vault
        D18 navPerShare = d18(1, 1);
        AssetId assetId = newAssetId(centrifugeId, 1);

        hub.setPoolMetadata(poolId, bytes("Testing pool"));
        hub.addShareClass(poolId, "Tokenized MMF", "MMF", bytes32(bytes("1")), bytes(""));
        hub.notifyPool{value: 0.001 ether}(poolId, centrifugeId);
        hub.notifyShareClass{value: 0.001 ether}(poolId, centrifugeId, scId, bytes32(bytes20(freelyTransferable)));

        hub.createAccount(poolId, AccountId.wrap(0x01), true);
        hub.createAccount(poolId, AccountId.wrap(0x02), false);
        hub.createAccount(poolId, AccountId.wrap(0x03), false);
        hub.createAccount(poolId, AccountId.wrap(0x04), false);
        hub.createHolding(poolId, scId, assetId, identityValuation, AccountId.wrap(0x01), AccountId.wrap(0x02), AccountId.wrap(0x03), AccountId.wrap(0x04));

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

        hub.updatePricePoolPerShare(poolId, scId, navPerShare, "");
        hub.notifySharePrice(poolId, centrifugeId, scId);

        // Submit deposit request
        IShareToken shareToken = IShareToken(poolManager.shareToken(poolId.raw(), scId.raw()));
        IAsyncVault vault = IAsyncVault(shareToken.vault(address(token)));

        uint128 investAmount = 1_000_000e6;
        token.approve(address(vault), investAmount);
        vault.requestDeposit(investAmount, msg.sender, msg.sender);

        // Fulfill deposit request
        IERC7726 valuation = holdings.valuation(poolId, scId, assetId);

        hub.approveDeposits(poolId, scId, assetId, investAmount, valuation);
        hub.issueShares(poolId, scId, assetId, navPerShare);

        hub.claimDeposit{value: 0.001 ether}(poolId, scId, assetId, bytes32(bytes20(msg.sender)));

        // Claim deposit request
        vault.mint(investAmount, msg.sender);
    }
}
