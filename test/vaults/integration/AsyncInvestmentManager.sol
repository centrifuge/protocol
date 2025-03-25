// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;
pragma abicoder v2;

import "test/vaults/BaseTest.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";

interface VaultLike {
    function priceComputedAt() external view returns (uint64);
}

// contract AsyncInvestmentManagerHarness is AsyncInvestmentManager {
//     constructor(address root, address escrow) AsyncInvestmentManager(root, escrow) {}

//     function calculatePrice(address vault, uint128 assets, uint128 shares) external view returns (uint256 price) {
//         return _calculatePrice(vault, assets, shares);
//     }
// }

contract AsyncInvestmentManagerTest is BaseTest {
    // Deployment
    function testDeployment(address nonWard) public {
        vm.assume(
            nonWard != address(root) && nonWard != address(gateway) && nonWard != address(poolManager)
                && nonWard != address(messageProcessor) && nonWard != address(this)
        );

        // redeploying within test to increase coverage
        new AsyncInvestmentManager(address(root), address(escrow));

        // values set correctly
        assertEq(address(asyncInvestmentManager.escrow()), address(escrow));
        assertEq(address(asyncInvestmentManager.gateway()), address(gateway));
        assertEq(address(asyncInvestmentManager.poolManager()), address(poolManager));
        assertEq(address(gateway.handler()), address(asyncInvestmentManager.sender()));

        // permissions set correctly
        assertEq(asyncInvestmentManager.wards(address(root)), 1);
        assertEq(asyncInvestmentManager.wards(address(gateway)), 1);
        assertEq(asyncInvestmentManager.wards(address(poolManager)), 1);
        assertEq(asyncInvestmentManager.wards(address(messageProcessor)), 1);
        assertEq(asyncInvestmentManager.wards(nonWard), 0);
    }

    // --- Administration ---
    function testFile() public {
        // fail: unrecognized param
        vm.expectRevert(bytes("AsyncInvestmentManager/file-unrecognized-param"));
        asyncInvestmentManager.file("random", self);

        assertEq(address(asyncInvestmentManager.gateway()), address(gateway));
        assertEq(address(asyncInvestmentManager.poolManager()), address(poolManager));
        // success
        asyncInvestmentManager.file("poolManager", randomUser);
        assertEq(address(asyncInvestmentManager.poolManager()), randomUser);
        asyncInvestmentManager.file("gateway", randomUser);
        assertEq(address(asyncInvestmentManager.gateway()), randomUser);

        // remove self from wards
        asyncInvestmentManager.deny(self);
        // auth fail
        vm.expectRevert(IAuth.NotAuthorized.selector);
        asyncInvestmentManager.file("poolManager", randomUser);
    }

    // // --- Price calculations ---
    // function testPrice() public {
    //     AsyncInvestmentManagerHarness harness = new AsyncInvestmentManagerHarness(address(root), address(escrow));
    //     assertEq(harness.calculatePrice(address(0), 1, 0), 0);
    //     assertEq(harness.calculatePrice(address(0), 0, 1), 0);
    // }
}
