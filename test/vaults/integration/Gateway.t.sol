// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {MockERC20} from "forge-std/mocks/MockERC20.sol";
import "test/BaseTest.sol";

contract GatewayTest is BaseTest {
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
        bytes memory _addPool = abi.encodePacked(uint8(MessagesLib.Call.AddPool), poolId);
        bytes memory _addAsset = abi.encodePacked(uint8(MessagesLib.Call.AddAsset), assetId, address(newAsset));
        bytes memory _allowAsset = abi.encodePacked(uint8(MessagesLib.Call.AllowAsset), poolId, assetId);

        bytes memory _message = abi.encodePacked(
            uint8(MessagesLib.Call.Batch),
            uint16(_addPool.length),
            _addPool,
            uint16(_addAsset.length),
            _addAsset,
            uint16(_allowAsset.length),
            _allowAsset
        );
        centrifugeChain.execute(_message);
        assertEq(poolManager.idToAsset(assetId), address(newAsset));
        assertEq(poolManager.isAllowedAsset(poolId, address(newAsset)), true);
    }

    function testBatchedMessageWithLengthProvidedButNoMessageBytes() public {
        uint64 poolId = 999;
        uint128 assetId = defaultAssetId + 1;
        MockERC20 newAsset = deployMockERC20("newAsset", "NEW", 18);
        bytes memory _addPool = abi.encodePacked(uint8(MessagesLib.Call.AddPool), poolId);

        bytes memory _message =
            abi.encodePacked(uint8(MessagesLib.Call.Batch), uint16(_addPool.length), _addPool, uint16(8));

        vm.expectRevert(bytes("Gateway/corrupted-message"));
        centrifugeChain.execute(_message);
    }

    function testRecursiveBatchedMessageFails() public {
        uint64 poolId = 999;
        uint128 assetId = defaultAssetId + 1;
        MockERC20 newAsset = deployMockERC20("newAsset", "NEW", 18);
        bytes memory _addPool = abi.encodePacked(uint8(MessagesLib.Call.AddPool), poolId);

        bytes memory _addAsset = abi.encodePacked(uint8(MessagesLib.Call.AddAsset), assetId, address(newAsset));
        bytes memory _allowAsset = abi.encodePacked(uint8(MessagesLib.Call.AllowAsset), poolId, assetId);

        bytes memory _addAndAllowAssetMessage = abi.encodePacked(
            uint8(MessagesLib.Call.Batch), uint16(_addAsset.length), _addAsset, uint16(_allowAsset.length), _allowAsset
        );

        bytes memory _message = abi.encodePacked(
            uint8(MessagesLib.Call.Batch),
            uint16(_addPool.length),
            _addPool,
            uint16(_addAndAllowAssetMessage.length),
            _addAndAllowAssetMessage
        );
        vm.expectRevert(bytes("Gateway/no-recursive-batching-allowed"));
        centrifugeChain.execute(_message);
    }
}
