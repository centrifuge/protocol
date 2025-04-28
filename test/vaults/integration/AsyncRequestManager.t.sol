// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;
pragma abicoder v2;

import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";

import {PricingLib} from "src/common/libraries/PricingLib.sol";

import {IEscrow} from "src/vaults/interfaces/IEscrow.sol";
import {VaultDetails} from "src/vaults/interfaces/IPoolManager.sol";
import {IAsyncVault} from "src/vaults/interfaces/IBaseVaults.sol";
import {IAsyncRequestManager} from "src/vaults/interfaces/investments/IAsyncRequestManager.sol";
import {IBaseInvestmentManager} from "src/vaults/interfaces/investments/IBaseInvestmentManager.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVaults.sol";

import "test/vaults/BaseTest.sol";

interface VaultLike {
    function priceComputedAt() external view returns (uint64);
}

contract AsyncRequestManagerHarness is AsyncRequestManager {
    constructor(IEscrow globalEscrow, address root, address deployer)
        AsyncRequestManager(globalEscrow, root, deployer)
    {}

    function calculatePriceAssetPerShare(IBaseVault vault, uint128 assets, uint128 shares)
        external
        view
        returns (uint256 price)
    {
        if (address(vault) == address(0)) {
            return
                PricingLib.calculatePriceAssetPerShare(address(0), shares, address(0), 0, assets, MathLib.Rounding.Down);
        }

        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault);
        address shareToken = vault.share();
        return PricingLib.calculatePriceAssetPerShare(
            shareToken, shares, vaultDetails.asset, vaultDetails.tokenId, assets, MathLib.Rounding.Down
        );
    }
}

contract AsyncRequestManagerTest is BaseTest {
    // Deployment
    function testDeployment(address nonWard) public {
        vm.assume(
            nonWard != address(root) && nonWard != address(gateway) && nonWard != address(poolManager)
                && nonWard != address(messageDispatcher) && nonWard != address(messageProcessor)
                && nonWard != address(syncRequestManager) && nonWard != address(this)
        );

        // redeploying within test to increase coverage
        new AsyncRequestManager(globalEscrow, address(root), address(this));

        // values set correctly
        assertEq(address(asyncRequestManager.sender()), address(messageDispatcher));
        assertEq(address(asyncRequestManager.poolManager()), address(poolManager));
        assertEq(address(asyncRequestManager.balanceSheet()), address(balanceSheet));
        assertEq(address(asyncRequestManager.poolEscrowProvider()), address(poolEscrowFactory));

        // permissions set correctly
        assertEq(asyncRequestManager.wards(address(root)), 1);
        assertEq(asyncRequestManager.wards(address(gateway)), 1);
        assertEq(asyncRequestManager.wards(address(poolManager)), 1);
        assertEq(asyncRequestManager.wards(address(messageProcessor)), 1);
        assertEq(asyncRequestManager.wards(address(messageDispatcher)), 1);
        assertEq(asyncRequestManager.wards(nonWard), 0);

        assertEq(balanceSheet.wards(address(asyncRequestManager)), 1);
        assertEq(messageDispatcher.wards(address(asyncRequestManager)), 1);
    }

    // --- Administration ---
    function testFile() public {
        // fail: unrecognized param
        vm.expectRevert(IBaseInvestmentManager.FileUnrecognizedParam.selector);
        asyncRequestManager.file("random", self);

        assertEq(address(asyncRequestManager.poolManager()), address(poolManager));
        // success
        asyncRequestManager.file("sender", randomUser);
        assertEq(address(asyncRequestManager.sender()), randomUser);
        asyncRequestManager.file("poolManager", randomUser);
        assertEq(address(asyncRequestManager.poolManager()), randomUser);
        asyncRequestManager.file("balanceSheet", randomUser);
        assertEq(address(asyncRequestManager.balanceSheet()), randomUser);
        asyncRequestManager.file("poolEscrowProvider", randomUser);
        assertEq(address(asyncRequestManager.poolEscrowProvider()), randomUser);

        // remove self from wards
        asyncRequestManager.deny(self);
        // auth fail
        vm.expectRevert(IAuth.NotAuthorized.selector);
        asyncRequestManager.file("poolManager", randomUser);
    }

    // --- Simple Errors ---
    function testRequestDepositUnlinkedVault() public {
        (, address vault_, uint128 assetId) = deploySimpleVault(VaultKind.Async);
        IAsyncVault vault = IAsyncVault(vault_);

        poolManager.unlinkVault(vault.poolId(), vault.scId(), AssetId.wrap(assetId), vault);

        vm.expectRevert(IBaseInvestmentManager.AssetNotAllowed.selector);
        asyncRequestManager.requestDeposit(vault, 1, address(0), address(0), address(0));
    }

    // --- Price calculations ---
    function testPrice() public {
        AsyncRequestManagerHarness harness = new AsyncRequestManagerHarness(globalEscrow, address(root), address(this));
        assertEq(harness.calculatePriceAssetPerShare(IBaseVault(address(0)), 1, 0), 0);
        assertEq(harness.calculatePriceAssetPerShare(IBaseVault(address(0)), 0, 1), 0);
    }
}
