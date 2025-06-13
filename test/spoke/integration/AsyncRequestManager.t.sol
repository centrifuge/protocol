// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;
pragma abicoder v2;

import {d18, D18} from "src/misc/types/D18.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {IEscrow} from "src/misc/interfaces/IEscrow.sol";

import {PricingLib} from "src/common/libraries/PricingLib.sol";

import {VaultDetails} from "src/spoke/interfaces/ISpoke.sol";

import {IAsyncVault} from "src/vaults/interfaces/IAsyncVault.sol";
import {IBaseRequestManager} from "src/vaults/interfaces/IBaseRequestManager.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";
import {IAsyncRequestManager} from "src/vaults/interfaces/IVaultManagers.sol";

import "test/spoke/BaseTest.sol";

interface VaultLike {
    function priceComputedAt() external view returns (uint64);
}

contract AsyncRequestManagerHarness is AsyncRequestManager {
    constructor(IEscrow globalEscrow, address root, address deployer) AsyncRequestManager(globalEscrow, root, deployer) {}

    function calculatePriceAssetPerShare(IBaseVault vault, uint128 assets, uint128 shares)
        external
        view
        returns (D18 price)
    {
        if (shares == 0) {
            return d18(0);
        }

        if (address(vault) == address(0)) {
            return
                PricingLib.calculatePriceAssetPerShare(address(0), shares, address(0), 0, assets, MathLib.Rounding.Down);
        }

        VaultDetails memory vaultDetails = spoke.vaultDetails(vault);
        address shareToken = vault.share();
        return PricingLib.calculatePriceAssetPerShare(
            shareToken, shares, vaultDetails.asset, vaultDetails.tokenId, assets, MathLib.Rounding.Down
        );
    }
}

contract AsyncRequestManagerTest is BaseTest {
    // Deployment
    function testDeploymentAsync(address nonWard) public {
        vm.assume(
            nonWard != address(root) && nonWard != address(spoke) && nonWard != address(syncManager)
                && nonWard != address(this)
        );

        // redeploying within test to increase coverage
        new AsyncRequestManager(globalEscrow, address(root), address(this));

        // values set correctly
        assertEq(address(asyncManager.spoke()), address(spoke));
        assertEq(address(asyncManager.balanceSheet()), address(balanceSheet));

        // permissions set correctly
        assertEq(asyncManager.wards(address(root)), 1);
        assertEq(asyncManager.wards(address(spoke)), 1);
        assertEq(asyncManager.wards(nonWard), 0);
    }

    // --- Administration ---
    function testFile() public {
        // fail: unrecognized param
        vm.expectRevert(IBaseRequestManager.FileUnrecognizedParam.selector);
        asyncManager.file("random", self);

        assertEq(address(asyncManager.spoke()), address(spoke));
        // success
        asyncManager.file("spoke", randomUser);
        assertEq(address(asyncManager.spoke()), randomUser);
        asyncManager.file("balanceSheet", randomUser);
        assertEq(address(asyncManager.balanceSheet()), randomUser);

        // remove self from wards
        asyncManager.deny(self);
        // auth fail
        vm.expectRevert(IAuth.NotAuthorized.selector);
        asyncManager.file("spoke", randomUser);
    }

    // --- Simple Errors ---
    function testRequestDepositUnlinkedVault() public {
        (, address vault_, uint128 assetId) = deploySimpleVault(VaultKind.Async);
        IAsyncVault vault = IAsyncVault(vault_);

        spoke.unlinkVault(vault.poolId(), vault.scId(), AssetId.wrap(assetId), vault);

        vm.expectRevert(IAsyncRequestManager.AssetNotAllowed.selector);
        asyncManager.requestDeposit(vault, 1, address(0), address(0), address(0));
    }

    // --- Price calculations ---
    function testPrice() public {
        AsyncRequestManagerHarness harness = new AsyncRequestManagerHarness(globalEscrow, address(root), address(this));
        assert(harness.calculatePriceAssetPerShare(IBaseVault(address(0)), 1, 0).isZero());
        assert(harness.calculatePriceAssetPerShare(IBaseVault(address(0)), 0, 1).isZero());
    }
}
