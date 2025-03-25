// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "src/misc/ERC20.sol";

import {ISafe} from "src/common/interfaces/IGuardian.sol";
import {VaultUpdateKind} from "src/common/libraries/MessageLib.sol";

import {FullDeployer, PoolsDeployer, VaultsDeployer} from "script/FullDeployer.s.sol";

import {LocalhostAdapter} from "test/integration/adapters/LocalhostAdapter.sol";

import {ShareClassId} from "src/pools/types/ShareClassId.sol";
import {AssetId, newAssetId} from "src/pools/types/AssetId.sol";
import {PoolId} from "src/pools/types/PoolId.sol";

// Script to deploy CP and CP with an Localhost Adapter.
contract LocalhostDeployer is FullDeployer {
    PoolId public POOL_A = PoolId.wrap(33);
    PoolId public POOL_B = PoolId.wrap(44);
    uint16 public CENTRIFUGE_CHAIN_ID = 23;
    ShareClassId public SC_A = ShareClassId.wrap(bytes16("sc"));
    AssetId immutable USDC_C2 = newAssetId(CENTRIFUGE_CHAIN_ID, 1);

    function run() public {
        uint16 centrifugeChainId = uint16(vm.envUint("CENTRIFUGE_CHAIN_ID"));

        vm.startBroadcast();

        deployFull(centrifugeChainId, ISafe(vm.envAddress("ADMIN")), msg.sender);
        saveDeploymentOutput();

        LocalhostAdapter adapter = new LocalhostAdapter(gateway, msg.sender);
        wire(adapter);

        PoolId poolId = poolRouter.createPool(msg.sender, USD, multiShareClass);
        ShareClassId scId = multiShareClass.previewNextShareClassId(poolId);

        ERC20 token = new ERC20(6);
        token.file("name", "USD Coin");
        token.file("symbol", "USDC");
        vaultRouter.registerAsset{value: 0.1 ether}(address(token), 0, CENTRIFUGE_CHAIN_ID);

        (bytes[] memory cs, uint256 c) = (new bytes[](6), 0);
        cs[c++] = abi.encodeWithSelector(poolRouter.setPoolMetadata.selector, bytes("Testing pool"));
        cs[c++] = abi.encodeWithSelector(
            poolRouter.addShareClass.selector, "Tokenized MMF", "MMF", bytes32(bytes("1")), bytes("")
        );
        cs[c++] = abi.encodeWithSelector(poolRouter.notifyPool.selector, CENTRIFUGE_CHAIN_ID);
        cs[c++] = abi.encodeWithSelector(
            poolRouter.notifyShareClass.selector, CENTRIFUGE_CHAIN_ID, scId, address(restrictedRedemptions)
        );
        cs[c++] = abi.encodeWithSelector(poolRouter.createHolding.selector, scId, USDC_C2, identityValuation, 0x01);
        cs[c++] = abi.encodeWithSelector(
            poolRouter.updateVault.selector,
            scId,
            USDC_C2,
            bytes32("target"),
            bytes32("factory"),
            VaultUpdateKind.DeployAndLink
        );

        poolRouter.execute{value: 0.1 ether}(poolId, cs);

        vm.stopBroadcast();
    }
}
