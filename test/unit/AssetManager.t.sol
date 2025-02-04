// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IERC165} from "forge-std/interfaces/IERC165.sol";

import {AssetId} from "src/types/AssetId.sol";
import {IAuth} from "src/interfaces/IAuth.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {AssetManager} from "src/AssetManager.sol";
import {IAssetManager} from "src/interfaces/IAssetManager.sol";
import {IERC6909} from "src/interfaces/ERC6909/IERC6909.sol";
import {IERC6909MetadataExt} from "src/interfaces/ERC6909/IERC6909MetadataExt.sol";
import {IERC6909TotalSupplyExt} from "src/interfaces/ERC6909/IERC6909TotalSupplyExt.sol";

abstract contract AssetManagerBaseTest is Test {
    address self;
    AssetManager manager;
    AssetId assetId = AssetId.wrap(1);
    string name = "MyTestAsset";
    string symbol = "MTA";
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

        (string memory name_, string memory symbol_, uint8 decimals_) = manager.asset(assetId);

        assertEq(keccak256(abi.encodePacked(name_)), keccak256(abi.encodePacked(name)));
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

        (string memory name_, string memory symbol_, uint8 decimals_) = manager.asset(assetId);
        assertEq(keccak256(abi.encodePacked(name_)), keccak256(abi.encodePacked(name)));
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

contract AssetMetadataRetrievalTest is AssetManagerBaseTest {
    using MathLib for uint128;

    uint256 rawAssetId;

    function setUp() public override {
        super.setUp();
        rawAssetId = uint256(assetId.raw());
        manager.registerAsset(assetId, name, symbol, decimals);
    }

    function testRetrievingDecimals() public view {
        assertEq(manager.decimals(rawAssetId), decimals);
    }

    function testRevertWhenAssetDoesNotExist() public {
        vm.expectRevert(IAssetManager.AssetNotFound.selector);
        manager.decimals(8337);
    }

    function testRetrievingName() public view {
        // when exists
        assertEq(manager.name(uint256(assetId.raw())), name);

        // when doesn't exist
        assertEq(manager.name(1234), "");
    }

    function testRetrivingSymbol() public view {
        // when exists
        assertEq(manager.symbol(rawAssetId), symbol);

        // when doesn't exist
        assertEq(manager.symbol(1234), "");
    }
}

contract AssetManagerSupportedInterfacesTest is AssetManagerBaseTest {
    function testSupport() public view {
        assertTrue(manager.supportsInterface(type(IERC165).interfaceId));
        assertTrue(manager.supportsInterface(type(IERC6909).interfaceId));
        assertTrue(manager.supportsInterface(type(IERC6909MetadataExt).interfaceId));
        assertTrue(manager.supportsInterface(type(IERC6909TotalSupplyExt).interfaceId));
    }
}
