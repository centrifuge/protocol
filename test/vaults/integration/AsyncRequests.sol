// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;
pragma abicoder v2;

import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {PriceConversionLib} from "src/vaults/libraries/PriceConversionLib.sol";

import "test/vaults/BaseTest.sol";

interface VaultLike {
    function priceComputedAt() external view returns (uint64);
}

contract AsyncRequestsHarness is AsyncRequests {
    constructor(address root, address escrow) AsyncRequests(root, escrow) {}

    function calculatePrice(address vault, uint128 assets, uint128 shares) external view returns (uint256 price) {
        return PriceConversionLib.calculatePrice(vault, assets, shares);
    }
}

contract AsyncRequestsTest is BaseTest {
    // Deployment
    function testDeployment(address nonWard) public {
        vm.assume(
            nonWard != address(root) && nonWard != address(gateway) && nonWard != address(poolManager)
                && nonWard != address(messageDispatcher) && nonWard != address(messageProcessor) && nonWard != address(this)
        );

        // redeploying within test to increase coverage
        new AsyncRequests(address(root), address(escrow));

        // values set correctly
        assertEq(address(asyncRequests.escrow()), address(escrow));
        assertEq(address(asyncRequests.gateway()), address(gateway));
        assertEq(address(asyncRequests.poolManager()), address(poolManager));

        // permissions set correctly
        assertEq(asyncRequests.wards(address(root)), 1);
        assertEq(asyncRequests.wards(address(gateway)), 1);
        assertEq(asyncRequests.wards(address(poolManager)), 1);
        assertEq(asyncRequests.wards(address(messageProcessor)), 1);
        assertEq(asyncRequests.wards(address(messageDispatcher)), 1);
        assertEq(asyncRequests.wards(nonWard), 0);
    }

    // --- Administration ---
    function testFile() public {
        // fail: unrecognized param
        vm.expectRevert(bytes("AsyncRequests/file-unrecognized-param"));
        asyncRequests.file("random", self);

        assertEq(address(asyncRequests.gateway()), address(gateway));
        assertEq(address(asyncRequests.poolManager()), address(poolManager));
        // success
        asyncRequests.file("sender", randomUser);
        assertEq(address(asyncRequests.sender()), randomUser);
        asyncRequests.file("poolManager", randomUser);
        assertEq(address(asyncRequests.poolManager()), randomUser);
        asyncRequests.file("gateway", randomUser);
        assertEq(address(asyncRequests.gateway()), randomUser);

        // remove self from wards
        asyncRequests.deny(self);
        // auth fail
        vm.expectRevert(IAuth.NotAuthorized.selector);
        asyncRequests.file("poolManager", randomUser);
    }

    // --- Price calculations ---
    function testPrice() public {
        AsyncRequestsHarness harness = new AsyncRequestsHarness(address(root), address(escrow));
        assertEq(harness.calculatePrice(address(0), 1, 0), 0);
        assertEq(harness.calculatePrice(address(0), 0, 1), 0);
    }
}
