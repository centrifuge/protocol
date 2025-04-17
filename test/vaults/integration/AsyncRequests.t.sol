// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;
pragma abicoder v2;

import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {VaultPricingLib} from "src/vaults/libraries/VaultPricingLib.sol";
import {VaultDetails} from "src/vaults/interfaces/IPoolManager.sol";
import {IAsyncVault} from "src/vaults/interfaces/IERC7540.sol";
import {IAsyncRequests} from "src/vaults/interfaces/investments/IAsyncRequests.sol";
import {IBaseInvestmentManager} from "src/vaults/interfaces/investments/IBaseInvestmentManager.sol";

import "test/vaults/BaseTest.sol";

interface VaultLike {
    function priceComputedAt() external view returns (uint64);
}

contract AsyncRequestsHarness is AsyncRequests {
    constructor(address root, address deployer) AsyncRequests(root, deployer) {}

    function calculatePrice(address vault, uint128 assets, uint128 shares) external view returns (uint256 price) {
        if (vault == address(0)) {
            return VaultPricingLib.calculatePrice(address(0), shares, address(0), 0, assets);
        }

        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault);
        address shareToken = IAsyncVault(vault).share();
        return VaultPricingLib.calculatePrice(shareToken, shares, vaultDetails.asset, vaultDetails.tokenId, assets);
    }
}

contract AsyncRequestsTest is BaseTest {
    // Deployment
    function testDeployment(address nonWard) public {
        vm.assume(
            nonWard != address(root) && nonWard != address(gateway) && nonWard != address(poolManager)
                && nonWard != address(messageDispatcher) && nonWard != address(messageProcessor)
                && nonWard != address(syncRequests) && nonWard != address(this)
        );

        // redeploying within test to increase coverage
        new AsyncRequests(address(root), address(this));

        // values set correctly
        assertEq(address(asyncRequests.sender()), address(messageDispatcher));
        assertEq(address(asyncRequests.poolManager()), address(poolManager));
        assertEq(address(asyncRequests.balanceSheet()), address(balanceSheet));
        assertEq(address(asyncRequests.sharePriceProvider()), address(syncRequests));
        assertEq(address(asyncRequests.poolEscrowProvider()), address(poolEscrowFactory));

        // permissions set correctly
        assertEq(asyncRequests.wards(address(root)), 1);
        assertEq(asyncRequests.wards(address(gateway)), 1);
        assertEq(asyncRequests.wards(address(poolManager)), 1);
        assertEq(asyncRequests.wards(address(messageProcessor)), 1);
        assertEq(asyncRequests.wards(address(messageDispatcher)), 1);
        assertEq(asyncRequests.wards(nonWard), 0);

        assertEq(balanceSheet.wards(address(asyncRequests)), 1);
        assertEq(messageDispatcher.wards(address(asyncRequests)), 1);
    }

    // --- Administration ---
    function testFile() public {
        // fail: unrecognized param
        vm.expectRevert(IBaseInvestmentManager.FileUnrecognizedParam.selector);
        asyncRequests.file("random", self);

        assertEq(address(asyncRequests.poolManager()), address(poolManager));
        // success
        asyncRequests.file("sender", randomUser);
        assertEq(address(asyncRequests.sender()), randomUser);
        asyncRequests.file("poolManager", randomUser);
        assertEq(address(asyncRequests.poolManager()), randomUser);
        asyncRequests.file("balanceSheet", randomUser);
        assertEq(address(asyncRequests.balanceSheet()), randomUser);
        asyncRequests.file("sharePriceProvider", randomUser);
        assertEq(address(asyncRequests.sharePriceProvider()), randomUser);
        asyncRequests.file("poolEscrowProvider", randomUser);
        assertEq(address(asyncRequests.poolEscrowProvider()), randomUser);

        // remove self from wards
        asyncRequests.deny(self);
        // auth fail
        vm.expectRevert(IAuth.NotAuthorized.selector);
        asyncRequests.file("poolManager", randomUser);
    }

    // --- Price calculations ---
    function testPrice() public {
        AsyncRequestsHarness harness = new AsyncRequestsHarness(address(root), address(this));
        assertEq(harness.calculatePrice(address(0), 1, 0), 0);
        assertEq(harness.calculatePrice(address(0), 0, 1), 0);
    }

    // --- Legacy support ---
    function testEscrow(address randomUser) public {
        (uint64 poolId, address vault_,) = deploySimpleVault(VaultKind.Async);
        vm.assume(randomUser != vault_);

        vm.prank(vault_);
        address actual = asyncRequests.escrow();
        address expected = poolEscrowFactory.escrow(poolId);
        assertEq(actual, expected, "Escrow address mismatch");

        vm.prank(randomUser);
        vm.expectRevert(IBaseInvestmentManager.SenderNotVault.selector);
        asyncRequests.escrow();
    }
}
