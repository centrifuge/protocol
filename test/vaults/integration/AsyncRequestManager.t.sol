// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;
pragma abicoder v2;

import {d18, D18} from "../../../src/misc/types/D18.sol";
import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {MathLib} from "../../../src/misc/libraries/MathLib.sol";
import {IEscrow} from "../../../src/misc/interfaces/IEscrow.sol";

import {PricingLib} from "../../../src/common/libraries/PricingLib.sol";

import "../../spoke/integration/BaseTest.sol";

import {VaultDetails} from "../../../src/spoke/interfaces/ISpoke.sol";

import {IBaseVault} from "../../../src/vaults/interfaces/IBaseVault.sol";
import {IAsyncVault} from "../../../src/vaults/interfaces/IAsyncVault.sol";
import {IBaseRequestManager} from "../../../src/vaults/interfaces/IBaseRequestManager.sol";
import {AsyncRequestManager, IAsyncRequestManager} from "../../../src/vaults/AsyncRequestManager.sol";

interface VaultLike {
    function priceComputedAt() external view returns (uint64);
}

contract AsyncRequestManagerHarness is AsyncRequestManager {
    constructor(IEscrow globalEscrow, address deployer) AsyncRequestManager(globalEscrow, deployer) {}

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
    // --- Administration ---
    function testFile() public {
        // fail: unrecognized param
        vm.expectRevert(IBaseRequestManager.FileUnrecognizedParam.selector);
        asyncRequestManager.file("random", self);

        assertEq(address(asyncRequestManager.spoke()), address(spoke));
        // success
        asyncRequestManager.file("spoke", randomUser);
        assertEq(address(asyncRequestManager.spoke()), randomUser);
        asyncRequestManager.file("balanceSheet", randomUser);
        assertEq(address(asyncRequestManager.balanceSheet()), randomUser);

        // remove self from wards
        asyncRequestManager.deny(self);
        // auth fail
        vm.expectRevert(IAuth.NotAuthorized.selector);
        asyncRequestManager.file("spoke", randomUser);
    }

    // --- Simple Errors ---
    function testRequestDepositUnlinkedVault() public {
        (, address vault_, uint128 assetId) = deploySimpleVault(VaultKind.Async);
        IAsyncVault vault = IAsyncVault(vault_);

        spoke.unlinkVault(vault.poolId(), vault.scId(), AssetId.wrap(assetId), vault);

        vm.prank(address(vault));
        vm.expectRevert(IAsyncRequestManager.VaultNotLinked.selector);
        asyncRequestManager.requestDeposit(vault, 1, address(0), address(0), address(0));
    }

    // --- Price calculations ---
    function testPrice() public {
        AsyncRequestManagerHarness harness = new AsyncRequestManagerHarness(globalEscrow, address(this));
        assert(harness.calculatePriceAssetPerShare(IBaseVault(address(0)), 1, 0).isZero());
        assert(harness.calculatePriceAssetPerShare(IBaseVault(address(0)), 0, 1).isZero());
    }
}
