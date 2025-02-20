// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;
pragma abicoder v2;

import "test/vaults/BaseTest.sol";

interface VaultLike {
    function priceComputedAt() external view returns (uint64);
}

contract InvestmentManagerHarness is InvestmentManager {
    constructor(address root, address escrow) InvestmentManager(root, escrow) {}

    function calculatePrice(address vault, uint128 assets, uint128 shares) external view returns (uint256 price) {
        return _calculatePrice(vault, assets, shares);
    }
}

contract InvestmentManagerTest is BaseTest {
    // Deployment
    function testDeployment(address nonWard) public {
        vm.assume(
            nonWard != address(root) && nonWard != address(vaultFactory) && nonWard != address(gateway)
                && nonWard != address(this)
        );

        // redeploying within test to increase coverage
        new InvestmentManager(address(root), address(escrow));

        // values set correctly
        assertEq(address(investmentManager.escrow()), address(escrow));
        assertEq(address(investmentManager.gateway()), address(gateway));
        assertEq(address(investmentManager.poolManager()), address(poolManager));
        assertEq(address(gateway.investmentManager()), address(investmentManager));
        assertEq(address(poolManager.investmentManager()), address(investmentManager));

        // permissions set correctly
        assertEq(investmentManager.wards(address(root)), 1);
        assertEq(investmentManager.wards(address(gateway)), 1);
        assertEq(investmentManager.wards(nonWard), 0);
    }

    // --- Administration ---
    function testFile() public {
        // fail: unrecognized param
        vm.expectRevert(bytes("InvestmentManager/file-unrecognized-param"));
        investmentManager.file("random", self);

        assertEq(address(investmentManager.gateway()), address(gateway));
        assertEq(address(investmentManager.poolManager()), address(poolManager));
        // success
        investmentManager.file("poolManager", randomUser);
        assertEq(address(investmentManager.poolManager()), randomUser);
        investmentManager.file("gateway", randomUser);
        assertEq(address(investmentManager.gateway()), randomUser);

        // remove self from wards
        investmentManager.deny(self);
        // auth fail
        vm.expectRevert(bytes("Auth/not-authorized"));
        investmentManager.file("poolManager", randomUser);
    }

    function testHandleInvalidMessage() public {
        vm.expectRevert(bytes("InvestmentManager/invalid-message"));
        investmentManager.handle(abi.encodePacked(uint8(MessagesLib.Call.Invalid)));
    }

    // --- Price calculations ---
    function testPrice() public {
        InvestmentManagerHarness harness = new InvestmentManagerHarness(address(root), address(escrow));
        assertEq(harness.calculatePrice(address(0), 1, 0), 0);
        assertEq(harness.calculatePrice(address(0), 0, 1), 0);
    }
}
