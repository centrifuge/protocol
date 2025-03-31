// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;
pragma abicoder v2;

import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {PriceConversionLib} from "src/vaults/libraries/PriceConversionLib.sol";

import "test/vaults/BaseTest.sol";

interface VaultLike {
    function priceComputedAt() external view returns (uint64);
}

contract AsyncManagerHarness is AsyncManager {
    constructor(address root, address escrow) AsyncManager(root, escrow) {}

    function calculatePrice(address vault, uint128 assets, uint128 shares) external view returns (uint256 price) {
        return PriceConversionLib.calculatePrice(vault, assets, shares);
    }
}

contract AsyncManagerTest is BaseTest {
    // Deployment
    function testDeployment(address nonWard) public {
        vm.assume(
            nonWard != address(root) && nonWard != address(gateway) && nonWard != address(poolManager)
                && nonWard != address(messageDispatcher) && nonWard != address(messageProcessor) && nonWard != address(this)
        );

        // redeploying within test to increase coverage
        new AsyncManager(address(root), address(escrow));

        // values set correctly
        assertEq(address(asyncManager.escrow()), address(escrow));
        assertEq(address(asyncManager.gateway()), address(gateway));
        assertEq(address(asyncManager.poolManager()), address(poolManager));

        // permissions set correctly
        assertEq(asyncManager.wards(address(root)), 1);
        assertEq(asyncManager.wards(address(gateway)), 1);
        assertEq(asyncManager.wards(address(poolManager)), 1);
        assertEq(asyncManager.wards(address(messageProcessor)), 1);
        assertEq(asyncManager.wards(address(messageDispatcher)), 1);
        assertEq(asyncManager.wards(nonWard), 0);
    }

    // --- Administration ---
    function testFile() public {
        // fail: unrecognized param
        vm.expectRevert(bytes("AsyncManager/file-unrecognized-param"));
        asyncManager.file("random", self);

        assertEq(address(asyncManager.gateway()), address(gateway));
        assertEq(address(asyncManager.poolManager()), address(poolManager));
        // success
        asyncManager.file("sender", randomUser);
        assertEq(address(asyncManager.sender()), randomUser);
        asyncManager.file("poolManager", randomUser);
        assertEq(address(asyncManager.poolManager()), randomUser);
        asyncManager.file("gateway", randomUser);
        assertEq(address(asyncManager.gateway()), randomUser);

        // remove self from wards
        asyncManager.deny(self);
        // auth fail
        vm.expectRevert(IAuth.NotAuthorized.selector);
        asyncManager.file("poolManager", randomUser);
    }

    // --- Price calculations ---
    function testPrice() public {
        AsyncManagerHarness harness = new AsyncManagerHarness(address(root), address(escrow));
        assertEq(harness.calculatePrice(address(0), 1, 0), 0);
        assertEq(harness.calculatePrice(address(0), 0, 1), 0);
    }
}
