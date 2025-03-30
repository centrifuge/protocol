// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "src/misc/ERC20.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";

import {ISafe} from "src/common/interfaces/IGuardian.sol";
import {VaultUpdateKind} from "src/common/libraries/MessageLib.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId, newAssetId} from "src/common/types/AssetId.sol";
import {PoolId} from "src/common/types/PoolId.sol";

import {ITranche} from "src/vaults/interfaces/token/ITranche.sol";
import {IERC7540Vault} from "src/vaults/interfaces/IERC7540.sol";

import {FullDeployer, PoolsDeployer, VaultsDeployer} from "script/FullDeployer.s.sol";

import {LocalhostAdapter} from "test/integration/adapters/LocalhostAdapter.sol";

// Script to deploy CP and CP with an Localhost Adapter.
contract LocalhostDeployer is FullDeployer {
    function run() public {
        uint16 centrifugeChainId = uint16(vm.envUint("CENTRIFUGE_CHAIN_ID"));

        vm.startBroadcast();

        deployFull(centrifugeChainId, ISafe(vm.envAddress("ADMIN")), msg.sender);
        saveDeploymentOutput();

        LocalhostAdapter adapter = new LocalhostAdapter(gateway, msg.sender);
        wire(adapter, msg.sender);

        _configureTestData(centrifugeChainId);

        vm.stopBroadcast();
    }

    function _configureTestData(uint16 centrifugeChainId) internal {
        // Create pool
        PoolId poolId = poolRouter.createPool(msg.sender, USD, multiShareClass);
        ShareClassId scId = multiShareClass.previewNextShareClassId(poolId);

        // Deploy and register test USDC
        ERC20 token = new ERC20(6);
        token.file("name", "USD Coin");
        token.file("symbol", "USDC");
        token.mint(msg.sender, 10_000_000e6);
        vaultRouter.registerAsset{value: 0.1 ether}(address(token), 0, centrifugeChainId);

        // Deploy vault
        D18 navPerShare = d18(1, 1);

        AssetId assetId = newAssetId(centrifugeChainId, 1);
        (bytes[] memory cs, uint256 c) = (new bytes[](8), 0);
        cs[c++] = abi.encodeWithSelector(poolRouter.setPoolMetadata.selector, bytes("Testing pool"));
        cs[c++] = abi.encodeWithSelector(
            poolRouter.addShareClass.selector, "Tokenized MMF", "MMF", bytes32(bytes("1")), bytes("")
        );
        cs[c++] = abi.encodeWithSelector(poolRouter.notifyPool.selector, centrifugeChainId);
        cs[c++] = abi.encodeWithSelector(
            poolRouter.notifyShareClass.selector, centrifugeChainId, scId, bytes32(bytes20(restrictedRedemptions))
        );
        cs[c++] =
            abi.encodeWithSelector(poolRouter.createHolding.selector, scId, assetId, identityValuation, false, 0x01);
        cs[c++] = abi.encodeWithSelector(
            poolRouter.updateVault.selector,
            scId,
            assetId,
            bytes32(bytes20(address(poolManager))),
            bytes32(bytes20(address(asyncVaultFactory))),
            VaultUpdateKind.DeployAndLink
        );
        cs[c++] = abi.encodeWithSelector(poolRouter.updateSharePrice.selector, scId, navPerShare);
        cs[c++] = abi.encodeWithSelector(poolRouter.notifySharePrice.selector, scId, assetId);

        poolRouter.execute{value: 0.1 ether}(poolId, cs);

        // Submit deposit request
        ITranche shareToken = ITranche(poolManager.tranche(poolId.raw(), scId.raw()));
        IERC7540Vault vault = IERC7540Vault(shareToken.vault(address(token)));

        uint256 investAmount = 1_000_000e6;
        token.approve(address(vault), investAmount);
        vault.requestDeposit(investAmount, msg.sender, msg.sender);

        // Fulfill deposit request
        IERC7726 valuation = holdings.valuation(poolId, scId, assetId);

        (bytes[] memory cs2, uint256 c2) = (new bytes[](2), 0);
        cs2[c2++] = abi.encodeWithSelector(poolRouter.approveDeposits.selector, scId, assetId, investAmount, valuation);
        cs2[c2++] = abi.encodeWithSelector(poolRouter.issueShares.selector, scId, assetId, navPerShare);

        poolRouter.execute{value: 0.1 ether}(poolId, cs2);

        poolRouter.claimDeposit{value: 0.1 ether}(poolId, scId, assetId, bytes32(bytes20(msg.sender)));

        // Claim deposit request
        vault.mint(investAmount, msg.sender);
    }
}
