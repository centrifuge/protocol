// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";

import {MessageLib} from "src/common/libraries/MessageLib.sol";

import {Prices} from "src/vaults/interfaces/investments/ISharePriceProvider.sol";
import {ISyncRequests} from "src/vaults/interfaces/investments/ISyncRequests.sol";
import {SyncRequests} from "src/vaults/SyncRequests.sol";
import {VaultPricingLib} from "src/vaults/libraries/VaultPricingLib.sol";
import {SyncDepositVault} from "src/vaults/SyncDepositVault.sol";
import {IBaseInvestmentManager} from "src/vaults/interfaces/investments/IBaseInvestmentManager.sol";

import "test/vaults/BaseTest.sol";

contract SyncRequestsBaseTest is BaseTest {
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

    function _setValuation(SyncDepositVault vault, address valuation_, uint256 tokenId) internal {
        vm.expectEmit();
        emit ISyncRequests.SetValuation(vault.poolId(), vault.scId(), vault.asset(), tokenId, valuation_);
        syncRequests.setValuation(vault.poolId(), vault.scId(), vault.asset(), tokenId, valuation_);
        assertEq(address(syncRequests.valuation(vault.poolId(), vault.scId(), vault.asset(), tokenId)), valuation_);
    }
}

contract SyncRequestsTest is SyncRequestsBaseTest {
    using MessageLib for *;

    // Deployment
    function testDeployment(address nonWard) public {
        _assumeUnauthorizedCaller(nonWard);

        // redeploying within test to increase coverage
        new SyncRequests(address(root), address(this));

        // values set correctly
        assertEq(address(syncRequests.poolManager()), address(poolManager));
        assertEq(address(syncRequests.balanceSheet()), address(balanceSheet));
        assertEq(address(syncRequests.poolEscrowProvider()), address(poolEscrowFactory));

        // permissions set correctly
        assertEq(syncRequests.wards(address(root)), 1);
        assertEq(syncRequests.wards(address(poolManager)), 1);
        assertEq(syncRequests.wards(address(syncDepositVaultFactory)), 1);
        assertEq(balanceSheet.wards(address(syncRequests)), 1);
        assertEq(syncRequests.wards(nonWard), 0);
    }

    // --- Administration ---
    function testFile() public {
        // fail: unrecognized param
        vm.expectRevert(IBaseInvestmentManager.FileUnrecognizedParam.selector);
        syncRequests.file("random", self);

        assertEq(address(syncRequests.poolManager()), address(poolManager));
        assertEq(address(syncRequests.balanceSheet()), address(balanceSheet));

        // success
        syncRequests.file("poolManager", randomUser);
        assertEq(address(syncRequests.poolManager()), randomUser);
        syncRequests.file("balanceSheet", randomUser);
        assertEq(address(syncRequests.balanceSheet()), randomUser);
        syncRequests.file("poolEscrowProvider", randomUser);
        assertEq(address(syncRequests.balanceSheet()), randomUser);

        // remove self from wards
        syncRequests.deny(self);
        // auth fail
        vm.expectRevert(IAuth.NotAuthorized.selector);
        syncRequests.file("poolManager", randomUser);
    }
}

contract SyncRequestsUnauthorizedTest is SyncRequestsBaseTest {
    function testFileUnauthorized(address nonWard) public {
        _expectUnauthorized(nonWard);
        syncRequests.file(bytes32(0), address(0));
    }

    function testAddVaultUnauthorized(address nonWard) public {
        _expectUnauthorized(nonWard);
        syncRequests.addVault(PoolId.wrap(0), ShareClassId.wrap(0), address(0), address(0), AssetId.wrap(0));
    }

    function testRemoveVaultUnauthorized(address nonWard) public {
        _expectUnauthorized(nonWard);
        syncRequests.removeVault(PoolId.wrap(0), ShareClassId.wrap(0), address(0), address(0), AssetId.wrap(0));
    }

    function testDepositUnauthorized(address nonWard) public {
        _expectUnauthorized(nonWard);
        syncRequests.deposit(address(0), 0, address(0), address(0));
    }

    function testMintUnauthorized(address nonWard) public {
        _expectUnauthorized(nonWard);
        syncRequests.mint(address(0), 0, address(0), address(0));
    }

    function testSetValuationUnauthorized(address nonWard) public {
        _expectUnauthorized(nonWard);
        syncRequests.setValuation(PoolId.wrap(0), ShareClassId.wrap(0), address(0), 0, address(0));
    }

    function testUpdate(address nonWard) public {
        _expectUnauthorized(nonWard);
        syncRequests.update(PoolId.wrap(0), ShareClassId.wrap(0), bytes(""));
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

contract SyncRequestsPrices is SyncRequestsBaseTest {
    function testPricesWithoutValuation(uint128 pricePoolPerShare_, uint128 pricePoolPerAsset_) public {
        D18 pricePoolPerShare = d18(uint128(bound(pricePoolPerShare_, 1e6, 1e24)));
        D18 pricePoolPerAsset = d18(uint128(bound(pricePoolPerAsset_, 1e4, pricePoolPerShare.inner())));
        D18 priceAssetPerShare = pricePoolPerShare / pricePoolPerAsset;

        (SyncDepositVault syncVault, uint128 assetId) = _deploySyncDepositVault(pricePoolPerShare, pricePoolPerAsset);

        Prices memory prices =
            syncRequests.prices(syncVault.poolId(), syncVault.scId(), AssetId.wrap(assetId), syncVault.asset(), 0);
        assertEq(prices.assetPerShare.inner(), priceAssetPerShare.inner(), "priceAssetPerShare mismatch");
        assertEq(prices.poolPerShare.inner(), pricePoolPerShare.inner(), "pricePoolPerShare mismatch");
        assertEq(prices.poolPerAsset.inner(), pricePoolPerAsset.inner(), "pricePoolPerAsset mismatch");
    }
}

contract SyncRequestsUpdateValuation is SyncRequestsBaseTest {
    using MathLib for uint256;

    address valuation_ = makeAddr("valuation");

    function testSetValuationERC20() public {
        (SyncDepositVault syncVault,) = _deploySyncDepositVault(d18(1e18), d18(1e18));

        _setValuation(syncVault, valuation_, 0);
    }

    function testPricesWithValuationERC20() public {
        D18 pricePoolPerShare = d18(10e18);
        D18 pricePoolPerAsset = d18(5e18);
        D18 priceAssetPerShare = d18(2e18);

        (SyncDepositVault syncVault, uint128 assetId) = _deploySyncDepositVault(pricePoolPerShare, pricePoolPerAsset);
        IShareToken shareToken = poolManager.shareToken(syncVault.poolId(), syncVault.scId());
        D18 pricePre = syncRequests.priceAssetPerShare(syncVault.poolId(), syncVault.scId(), AssetId.wrap(assetId));

        _setValuation(syncVault, valuation_, 0);

        // Change priceAssetPerShare
        uint256 shareUnitAmount = 10 ** shareToken.decimals();
        priceAssetPerShare = d18(4e18);
        pricePoolPerShare = d18(20e18);
        uint256 assetPerShareAmount = priceAssetPerShare.mulUint256(shareUnitAmount);

        // Mock valuation
        vm.mockCall(
            address(valuation_),
            abi.encodeWithSelector(IERC7726.getQuote.selector, shareUnitAmount, shareToken, syncVault.asset()),
            abi.encode(assetPerShareAmount)
        );

        Prices memory prices =
            syncRequests.prices(syncVault.poolId(), syncVault.scId(), AssetId.wrap(assetId), syncVault.asset(), 0);
        D18 pricePost = syncRequests.priceAssetPerShare(syncVault.poolId(), syncVault.scId(), AssetId.wrap(assetId));
        assertEq(prices.assetPerShare.inner(), priceAssetPerShare.inner(), "priceAssetPerShare mismatch");
        assertEq(prices.assetPerShare.inner(), pricePost.inner(), "priceAssetPerShare vs pricePost mismatch");
        assertNotEq(prices.assetPerShare.inner(), pricePre.inner());
        assertEq(prices.poolPerAsset.inner(), pricePoolPerAsset.inner(), "pricePoolPerAsset 2mismatch");
        assertEq(prices.poolPerShare.inner(), pricePoolPerShare.inner(), "pricePoolPerShare mismatch");
    }

    function testFuzzedPricesWithValuationERC20(
        uint128 pricePoolPerShare_,
        uint128 pricePoolPerAsset_,
        uint8 multiplier_
    ) public {
        D18 pricePoolPerShare = d18(uint128(bound(pricePoolPerShare_, 1e8, 1e24)));
        D18 pricePoolPerAsset = d18(uint128(bound(pricePoolPerAsset_, 1e6, pricePoolPerShare.inner())));
        D18 priceAssetPerShare = pricePoolPerShare / pricePoolPerAsset;
        vm.assume(priceAssetPerShare.inner() % 1e12 == 0);
        uint128 multiplier = uint128(bound(multiplier_, 2, 10));

        (SyncDepositVault syncVault, uint128 assetId) = _deploySyncDepositVault(pricePoolPerShare, pricePoolPerAsset);
        IShareToken shareToken = poolManager.shareToken(syncVault.poolId(), syncVault.scId());
        D18 pricePre = syncRequests.priceAssetPerShare(syncVault.poolId(), syncVault.scId(), AssetId.wrap(assetId));

        _setValuation(syncVault, valuation_, 0);

        // Change priceAssetPerShare
        uint256 shareUnitAmount = 10 ** shareToken.decimals();
        uint256 assetUnitAmount = 10 ** VaultPricingLib.getAssetDecimals(syncVault.asset(), 0);
        priceAssetPerShare = d18(priceAssetPerShare.inner() * multiplier);
        uint256 assetPerShareAmount = priceAssetPerShare.mulUint256(shareUnitAmount);
        pricePoolPerShare = d18(assetPerShareAmount.toUint128(), assetUnitAmount.toUint128()) * pricePoolPerAsset;

        // Mock valuation
        vm.mockCall(
            address(valuation_),
            abi.encodeWithSelector(IERC7726.getQuote.selector, shareUnitAmount, shareToken, syncVault.asset()),
            abi.encode(assetPerShareAmount)
        );

        Prices memory prices =
            syncRequests.prices(syncVault.poolId(), syncVault.scId(), AssetId.wrap(assetId), syncVault.asset(), 0);
        D18 pricePost = syncRequests.priceAssetPerShare(syncVault.poolId(), syncVault.scId(), AssetId.wrap(assetId));
        assertEq(
            prices.assetPerShare.inner(), priceAssetPerShare.inner(), "assetPerShare vs priceAssetPerShare mismatch"
        );
        assertEq(prices.assetPerShare.inner(), pricePost.inner(), "assetPerShare vs pricePost mismatch");
        assertNotEq(prices.assetPerShare.inner(), pricePre.inner());
        assertEq(prices.poolPerAsset.inner(), pricePoolPerAsset.inner(), "pricePoolPerAsset 2mismatch");
        assertEq(prices.poolPerShare.inner(), pricePoolPerShare.inner(), "pricePoolPerShare mismatch");
    }

    function testConversionWithValuationERC20() public {
        D18 pricePoolPerShare = d18(10e18);
        D18 pricePoolPerAsset = d18(5e18);
        D18 priceAssetPerShare = d18(2e18);

        (SyncDepositVault syncVault,) = _deploySyncDepositVault(pricePoolPerShare, pricePoolPerAsset);
        IShareToken shareToken = poolManager.shareToken(syncVault.poolId(), syncVault.scId());
        _setValuation(syncVault, valuation_, 0);

        // Mock valuation
        uint256 shareUnitAmount = 10 ** shareToken.decimals();
        vm.mockCall(
            address(valuation_),
            abi.encodeWithSelector(IERC7726.getQuote.selector, shareUnitAmount, shareToken, syncVault.asset()),
            abi.encode(priceAssetPerShare.mulUint256(shareUnitAmount))
        );

        uint256 shares = shareUnitAmount;
        uint256 assets = priceAssetPerShare.mulUint256(shares);
        assertEq(syncRequests.convertToAssets(address(syncVault), shares), assets, "convertToAssets mismatch");
        assertEq(syncRequests.previewMint(address(syncVault), address(0), shares), assets, "previewMint mismatch");
        assertEq(syncRequests.convertToShares(address(syncVault), assets), shares, "convertToShares mismatch");
        assertEq(syncRequests.previewDeposit(address(syncVault), address(0), assets), shares, "previewDeposit mismatch");
    }

    function testFuzzedConversionWithValuationERC20(uint128 pricePoolPerShare_, uint128 pricePoolPerAsset_) public {
        uint128 shift = 1e4;
        D18 pricePoolPerShare = d18(uint128(bound(pricePoolPerShare_, 1e2, 1e20)) * shift);
        D18 pricePoolPerAsset = d18(uint128(bound(pricePoolPerAsset_, 1, pricePoolPerShare.inner() / shift)) * shift);
        D18 priceAssetPerShare = pricePoolPerShare / pricePoolPerAsset;

        (SyncDepositVault syncVault,) = _deploySyncDepositVault(pricePoolPerShare, pricePoolPerAsset);
        IShareToken shareToken = poolManager.shareToken(syncVault.poolId(), syncVault.scId());
        _setValuation(syncVault, valuation_, 0);

        // Mock valuation
        uint256 shareUnitAmount = 10 ** IERC20Metadata(shareToken).decimals();
        vm.mockCall(
            address(valuation_),
            abi.encodeWithSelector(IERC7726.getQuote.selector, shareUnitAmount, shareToken, syncVault.asset()),
            abi.encode(priceAssetPerShare.mulUint256(shareUnitAmount))
        );

        uint256 shares = shareUnitAmount;
        uint256 assets = priceAssetPerShare.mulUint256(shares);
        assertEq(syncRequests.convertToAssets(address(syncVault), shares), assets, "convertToAssets mismatch");
        assertEq(syncRequests.previewMint(address(syncVault), address(0), shares), assets, "previewMint mismatch");
        assertEq(syncRequests.convertToShares(address(syncVault), assets), shares, "convertToShares mismatch");
        assertEq(syncRequests.previewDeposit(address(syncVault), address(0), assets), shares, "previewDeposit mismatch");
    }
}
