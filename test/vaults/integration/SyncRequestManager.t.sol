// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";

import {MessageLib} from "src/common/libraries/MessageLib.sol";
import {PricingLib} from "src/common/libraries/PricingLib.sol";

import {
    ISyncRequestManager,
    Prices,
    ISyncDepositValuation
} from "src/vaults/interfaces/investments/ISyncRequestManager.sol";
import {SyncRequestManager} from "src/vaults/SyncRequestManager.sol";
import {SyncDepositVault} from "src/vaults/SyncDepositVault.sol";
import {IBaseInvestmentManager} from "src/vaults/interfaces/investments/IBaseInvestmentManager.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVaults.sol";

import "test/vaults/BaseTest.sol";

contract SyncRequestManagerBaseTest is BaseTest {
    function _assumeUnauthorizedCaller(address nonWard) internal view {
        vm.assume(
            nonWard != address(root) && nonWard != address(poolManager) && nonWard != address(syncDepositVaultFactory)
                && nonWard != address(this)
        );
    }

    function _deploySyncDepositVault(D18 pricePoolPerShare, D18 pricePoolPerAsset)
        internal
        returns (SyncDepositVault syncVault, uint128 assetId)
    {
        (, address syncVault_, uint128 assetId_) = deploySimpleVault(VaultKind.SyncDepositAsyncRedeem);
        assetId = assetId_;
        syncVault = SyncDepositVault(syncVault_);

        centrifugeChain.updatePricePoolPerShare(
            syncVault.poolId().raw(), syncVault.scId().raw(), pricePoolPerShare.inner(), uint64(block.timestamp)
        );
        centrifugeChain.updatePricePoolPerAsset(
            syncVault.poolId().raw(),
            syncVault.scId().raw(),
            assetId,
            pricePoolPerAsset.inner(),
            uint64(block.timestamp)
        );
    }

    function _setValuation(SyncDepositVault vault, address valuation_) internal {
        vm.expectEmit();
        emit ISyncRequestManager.SetValuation(vault.poolId(), vault.scId(), valuation_);
        syncRequestManager.setValuation(vault.poolId(), vault.scId(), valuation_);
        assertEq(address(syncRequestManager.valuation(vault.poolId(), vault.scId())), valuation_);
    }
}

contract SyncRequestManagerTest is SyncRequestManagerBaseTest {
    using MessageLib for *;

    // Deployment
    function testDeployment(address nonWard) public {
        _assumeUnauthorizedCaller(nonWard);

        // redeploying within test to increase coverage
        new SyncRequestManager(globalEscrow, address(root), address(this));

        // values set correctly
        assertEq(address(syncRequestManager.poolManager()), address(poolManager));
        assertEq(address(syncRequestManager.balanceSheet()), address(balanceSheet));
        assertEq(address(syncRequestManager.poolEscrowProvider()), address(poolEscrowFactory));

        // permissions set correctly
        assertEq(syncRequestManager.wards(address(root)), 1);
        assertEq(syncRequestManager.wards(address(poolManager)), 1);
        assertEq(syncRequestManager.wards(address(syncDepositVaultFactory)), 1);
        assertEq(balanceSheet.wards(address(syncRequestManager)), 1);
        assertEq(syncRequestManager.wards(nonWard), 0);
    }

    // --- Administration ---
    function testFile() public {
        // fail: unrecognized param
        vm.expectRevert(IBaseInvestmentManager.FileUnrecognizedParam.selector);
        syncRequestManager.file("random", self);

        assertEq(address(syncRequestManager.poolManager()), address(poolManager));
        assertEq(address(syncRequestManager.balanceSheet()), address(balanceSheet));

        // success
        syncRequestManager.file("poolManager", randomUser);
        assertEq(address(syncRequestManager.poolManager()), randomUser);
        syncRequestManager.file("balanceSheet", randomUser);
        assertEq(address(syncRequestManager.balanceSheet()), randomUser);
        syncRequestManager.file("poolEscrowProvider", randomUser);
        assertEq(address(syncRequestManager.balanceSheet()), randomUser);

        // remove self from wards
        syncRequestManager.deny(self);
        // auth fail
        vm.expectRevert(IAuth.NotAuthorized.selector);
        syncRequestManager.file("poolManager", randomUser);
    }

    // --- Simple Errors ---
    function testDepositUnlinkedVault() public {
        (SyncDepositVault vault, uint128 assetId) = _deploySyncDepositVault(d18(0), d18(0));
        poolManager.unlinkVault(vault.poolId(), vault.scId(), AssetId.wrap(assetId), vault);

        vm.expectRevert(IBaseInvestmentManager.AssetNotAllowed.selector);
        syncRequestManager.deposit(vault, 1, address(0), address(0));
    }
}

contract SyncRequestManagerUnauthorizedTest is SyncRequestManagerBaseTest {
    function testFileUnauthorized(address nonWard) public {
        _expectUnauthorized(nonWard);
        syncRequestManager.file(bytes32(0), address(0));
    }

    function testAddVaultUnauthorized(address nonWard) public {
        _expectUnauthorized(nonWard);
        syncRequestManager.addVault(
            PoolId.wrap(0), ShareClassId.wrap(0), IBaseVault(address(0)), address(0), AssetId.wrap(0)
        );
    }

    function testRemoveVaultUnauthorized(address nonWard) public {
        _expectUnauthorized(nonWard);
        syncRequestManager.removeVault(
            PoolId.wrap(0), ShareClassId.wrap(0), IBaseVault(address(0)), address(0), AssetId.wrap(0)
        );
    }

    function testDepositUnauthorized(address nonWard) public {
        _expectUnauthorized(nonWard);
        syncRequestManager.deposit(IBaseVault(address(0)), 0, address(0), address(0));
    }

    function testMintUnauthorized(address nonWard) public {
        _expectUnauthorized(nonWard);
        syncRequestManager.mint(IBaseVault(address(0)), 0, address(0), address(0));
    }

    function testSetValuationUnauthorized(address nonWard) public {
        _expectUnauthorized(nonWard);
        syncRequestManager.setValuation(PoolId.wrap(0), ShareClassId.wrap(0), address(0));
    }

    function testUpdate(address nonWard) public {
        _expectUnauthorized(nonWard);
        syncRequestManager.update(PoolId.wrap(0), ShareClassId.wrap(0), bytes(""));
    }

    function _expectUnauthorized(address caller) internal {
        vm.assume(
            caller != address(root) && caller != address(poolManager) && caller != address(syncDepositVaultFactory)
                && caller != address(this)
        );

        vm.prank(caller);
        vm.expectRevert(IAuth.NotAuthorized.selector);
    }
}

contract SyncRequestManagerPrices is SyncRequestManagerBaseTest {
    function testPricesWithoutValuation(uint128 pricePoolPerShare_, uint128 pricePoolPerAsset_) public {
        D18 pricePoolPerShare = d18(uint128(bound(pricePoolPerShare_, 1e6, 1e24)));
        D18 pricePoolPerAsset = d18(uint128(bound(pricePoolPerAsset_, 1e4, pricePoolPerShare.inner())));
        D18 priceAssetPerShare = pricePoolPerShare / pricePoolPerAsset;

        (SyncDepositVault syncVault, uint128 assetId) = _deploySyncDepositVault(pricePoolPerShare, pricePoolPerAsset);

        Prices memory prices = syncRequestManager.prices(syncVault.poolId(), syncVault.scId(), AssetId.wrap(assetId));
        assertEq(prices.assetPerShare.inner(), priceAssetPerShare.inner(), "priceAssetPerShare mismatch");
        assertEq(prices.poolPerShare.inner(), pricePoolPerShare.inner(), "pricePoolPerShare mismatch");
        assertEq(prices.poolPerAsset.inner(), pricePoolPerAsset.inner(), "pricePoolPerAsset mismatch");
    }
}

contract SyncRequestManagerUpdateValuation is SyncRequestManagerBaseTest {
    using MathLib for uint256;

    address valuation_ = makeAddr("valuation");

    function _mockValuation(SyncDepositVault syncVault, D18 pricePoolPerShare) internal {
        vm.mockCall(
            address(valuation_),
            abi.encodeWithSelector(
                ISyncDepositValuation.pricePoolPerShare.selector, syncVault.poolId(), syncVault.scId()
            ),
            abi.encode(pricePoolPerShare)
        );
    }

    function _assertPrices(SyncDepositVault syncVault, D18 prePoolPerShare, Prices memory expected, uint128 assetId)
        internal
        view
    {
        Prices memory prices = syncRequestManager.prices(syncVault.poolId(), syncVault.scId(), AssetId.wrap(assetId));

        D18 pricePost = syncRequestManager.pricePoolPerShare(syncVault.poolId(), syncVault.scId());
        assertNotEq(prePoolPerShare.inner(), pricePost.inner(), "Price should be changed by valuation");
        assertEq(expected.poolPerShare.inner(), prices.poolPerShare.inner(), "poolPerShare mismatch");
        assertEq(expected.poolPerShare.inner(), pricePost.inner(), "poolPerShare vs pricePost mismatch");

        assertEq(expected.poolPerAsset.inner(), prices.poolPerAsset.inner(), "poolPerAsset mismatch");
        assertEq(expected.assetPerShare.inner(), prices.assetPerShare.inner(), "assetPerShare mismatch");
    }

    function testSetValuationERC20() public {
        (SyncDepositVault syncVault,) = _deploySyncDepositVault(d18(1e18), d18(1e18));

        _setValuation(syncVault, valuation_);
    }

    function testPricesWithValuationERC20() public {
        D18 pricePoolPerShare = d18(10e18);
        D18 pricePoolPerAsset = d18(5e18);
        D18 priceAssetPerShare = d18(2e18);

        (SyncDepositVault syncVault, uint128 assetId) = _deploySyncDepositVault(pricePoolPerShare, pricePoolPerAsset);
        D18 pricePre = syncRequestManager.pricePoolPerShare(syncVault.poolId(), syncVault.scId());

        _setValuation(syncVault, valuation_);

        // Change pricePoolPerShare
        pricePoolPerShare = d18(20e18);
        priceAssetPerShare = d18(4e18); // 20e18 / 5e18

        // Mock valuation and perform checks
        _mockValuation(syncVault, pricePoolPerShare);
        _assertPrices(
            syncVault,
            pricePre,
            Prices({assetPerShare: priceAssetPerShare, poolPerAsset: pricePoolPerAsset, poolPerShare: pricePoolPerShare}),
            assetId
        );
    }

    function testFuzzedPricesWithValuationERC20(
        uint128 pricePoolPerShare_,
        uint128 pricePoolPerAsset_,
        uint8 multiplier_
    ) public {
        D18 pricePoolPerShare = d18(uint128(bound(pricePoolPerShare_, 1e8, 1e24)));
        D18 pricePoolPerAsset = d18(uint128(bound(pricePoolPerAsset_, 1e6, pricePoolPerShare.inner())));
        D18 priceAssetPerShare = pricePoolPerShare / pricePoolPerAsset;
        uint128 multiplier = uint128(bound(multiplier_, 2, 10));
        vm.assume(priceAssetPerShare.inner() % multiplier == 0);

        (SyncDepositVault syncVault, uint128 assetId) = _deploySyncDepositVault(pricePoolPerShare, pricePoolPerAsset);
        D18 pricePre = syncRequestManager.pricePoolPerShare(syncVault.poolId(), syncVault.scId());

        _setValuation(syncVault, valuation_);

        // Change pricePoolPerShare
        pricePoolPerShare = d18(pricePoolPerShare.inner() * multiplier);
        priceAssetPerShare = pricePoolPerShare / pricePoolPerAsset;

        // Mock valuation and perform checks
        _mockValuation(syncVault, pricePoolPerShare);
        _assertPrices(
            syncVault,
            pricePre,
            Prices({assetPerShare: priceAssetPerShare, poolPerAsset: pricePoolPerAsset, poolPerShare: pricePoolPerShare}),
            assetId
        );
    }
}
