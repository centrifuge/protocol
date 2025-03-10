// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MockERC20} from "forge-std/mocks/MockERC20.sol";

import {MessageType, MessageLib} from "src/common/libraries/MessageLib.sol";
import "test/vaults/BaseTest.sol";

contract GatewayTest is BaseTest {
    using MessageLib for *;
    // --- Deployment ----

    function testDeployment(address nonWard) public {
        vm.assume(
            nonWard != address(root) && nonWard != address(guardian) && nonWard != address(this)
            && nonWard != address(gateway)
        );

        // redeploying within test to increase coverage
        new Gateway(address(root), address(poolManager), address(investmentManager), address(gasService));

        // values set correctly
        assertEq(address(gateway.investmentManager()), address(investmentManager));
        assertEq(address(gateway.poolManager()), address(poolManager));
        assertEq(address(gateway.root()), address(root));
        assertEq(address(investmentManager.gateway()), address(gateway));
        assertEq(address(poolManager.gateway()), address(gateway));

        // gateway setup
        assertEq(gateway.quorum(), 3);
        assertEq(gateway.adapters(0), address(adapter1));
        assertEq(gateway.adapters(1), address(adapter2));
        assertEq(gateway.adapters(2), address(adapter3));

        // permissions set correctly
        assertEq(gateway.wards(address(root)), 1);
        assertEq(gateway.wards(address(guardian)), 1);
        assertEq(gateway.wards(nonWard), 0);
    }

    // --- Batched messages ---
    function testBatchedAddPoolAddAssetAllowAssetMessage() public {
        uint64 poolId = 999;
        uint128 assetId = defaultAssetId + 1;
        MockERC20 newAsset = deployMockERC20("newAsset", "NEW", 18);
        bytes memory _addPool = MessageLib.NotifyPool(poolId).serialize();
        // TODO: remove next line when registerAsset feature is supported
        bytes memory _addAsset = abi.encodePacked(uint8(MessageType.RegisterAsset), assetId, address(newAsset));
        bytes memory _allowAsset = MessageLib.AllowAsset(poolId, bytes16(0), assetId).serialize();

        bytes memory _message = abi.encodePacked(_addPool, _addAsset, _allowAsset);
        centrifugeChain.execute(_message);
        assertEq(poolManager.idToAsset(assetId), address(newAsset));
        assertEq(poolManager.isAllowedAsset(poolId, address(newAsset)), true);
    }
}
