// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {AssetId} from "src/types/AssetId.sol";
import {IAuth} from "src/interfaces/IAuth.sol";
import {AssetManager} from "src/AssetManager.sol";
import {IAssetManager} from "src/interfaces/IAssetManager.sol";

abstract contract AssetManagerBaseTest is Test {
    address self;
    AssetManager manager;
    AssetId assetId = AssetId.wrap(1);
    bytes name = "MyTestAsset";
    bytes32 symbol = "MTA";
    uint8 decimals = 18;

    function setUp() public virtual {
        self = address(this);
        manager = new AssetManager(self);
    }
}

contract AuthTest is AssetManagerBaseTest {
    function testAssignedWardsOnInitialization() public view {
        assertEq(manager.wards(self), 1);
    }

    function testAssigningAWard() public {
        address newWard = makeAddr("ward");
        assertEq(manager.wards(newWard), 0);
        manager.rely(newWard);
        assertEq(manager.wards(newWard), 1);
    }

    function testRemovingAWard() public {
        assertEq(manager.wards(self), 1);
        manager.deny(self);
        assertEq(manager.wards(self), 0);
    }

    function testRevertWhenUnauthorizedCallerRegisterAnAsset() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(makeAddr("unauthorized caller"));
        manager.registerAsset(assetId, "MyNewAsset", "MNA", 18);
    }
}

contract AssetManagementTest is AssetManagerBaseTest {
    function testRegistrationOfANewAsset() public {
        vm.expectEmit();
        emit IAssetManager.NewAssetEntry(assetId, name, symbol, decimals);
        manager.registerAsset(assetId, name, symbol, decimals);
        assertTrue(manager.isRegistered(assetId));

        (bytes memory name_, bytes32 symbol_, uint8 decimals_) = manager.asset(assetId);

        assertEq(keccak256(name_), keccak256(name));
        assertEq(symbol_, symbol);
        assertEq(decimals_, decimals);
    }

    function testRevertOnNewAssetRegistration() public {
        vm.expectRevert(IAssetManager.IncorrectAssetId.selector);
        manager.registerAsset(AssetId.wrap(0), "AssetWithEmptyId", "N/A", 18);
    }

    function testSuccessfulUpdateOfAnExistingAsset() public {
        manager.registerAsset(assetId, name, symbol, decimals);

        name = "MyNewlyUpdatedAsset";
        symbol = "MNUA";

        vm.expectEmit();
        emit IAssetManager.NewAssetEntry(assetId, name, symbol, decimals);
        manager.registerAsset(assetId, name, symbol, 6);

        (bytes memory name_, bytes32 symbol_, uint8 decimals_) = manager.asset(assetId);
        assertEq(keccak256(name_), keccak256(name));
        assertEq(symbol_, symbol);
        assertEq(decimals_, decimals);
    }

    function testRevertOnUpdateAnExistingAsset() public {
        manager.registerAsset(assetId, "MyNewAsset", "MNA", 18);

        vm.expectRevert(IAssetManager.IncorrectAssetId.selector);
        manager.registerAsset(AssetId.wrap(0), "MyUpdatedAsset", "MUNA", 18);
    }

    function testThatNotRegisteredAssetIsNotPresent() public view {
        assertFalse(manager.isRegistered(AssetId.wrap(73475)));
    }
}

contract AssetDecimalsRetrievalTest is AssetManagerBaseTest {
    function setUp() public override {
        super.setUp();
        manager.registerAsset(assetId, name, symbol, decimals);
    }

    function testSuccess() public view {
        assertEq(manager.decimals(assetId.addr()), decimals);
    }

    function testRevertWhenAssetDoesNotExist() public {
        vm.expectRevert(IAssetManager.AssetNotFound.selector);
        manager.decimals(AssetId.wrap(8337).addr());
    }
}
