// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {D18, d18} from "src/misc/types/D18.sol";

import {MessageLib} from "src/common/libraries/MessageLib.sol";

import {ISyncRequests, SyncPriceData} from "src/vaults/interfaces/investments/ISyncRequests.sol";
import {SyncRequests} from "src/vaults/SyncRequests.sol";
import {SyncDepositVault} from "src/vaults/SyncDepositVault.sol";

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
            syncVault.poolId(), syncVault.trancheId(), pricePoolPerShare.inner(), uint64(block.timestamp)
        );
        centrifugeChain.updatePricePoolPerAsset(
            syncVault.poolId(), syncVault.trancheId(), assetId, pricePoolPerAsset.inner(), uint64(block.timestamp)
        );
    }
}

contract SyncRequestsTest is SyncRequestsBaseTest {
    using MessageLib for *;

    // Deployment
    function testDeployment(address nonWard) public {
        _assumeUnauthorizedCaller(nonWard);

        // redeploying within test to increase coverage
        new SyncRequests(address(root), address(escrow));

        // values set correctly
        assertEq(address(syncRequests.escrow()), address(escrow));
        assertEq(address(syncRequests.poolManager()), address(poolManager));
        assertEq(address(syncRequests.balanceSheet()), address(balanceSheet));

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
        vm.expectRevert(bytes("SyncRequests/file-unrecognized-param"));
        syncRequests.file("random", self);

        assertEq(address(syncRequests.poolManager()), address(poolManager));
        assertEq(address(syncRequests.balanceSheet()), address(balanceSheet));

        // success
        syncRequests.file("poolManager", randomUser);
        assertEq(address(syncRequests.poolManager()), randomUser);
        syncRequests.file("balanceSheet", randomUser);
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
        syncRequests.addVault(0, bytes16(0), address(0), address(0), 0);
    }

    function testRemoveVaultUnauthorized(address nonWard) public {
        _expectUnauthorized(nonWard);
        syncRequests.removeVault(0, bytes16(0), address(0), address(0), 0);
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
        syncRequests.setValuation(0, bytes16(0), address(0), 0, address(0));
    }

    function _expectUnauthorized(address caller) internal {
        vm.assume(
            caller != address(root) && caller != address(poolManager) && caller != syncDepositVaultFactory
                && caller != address(this)
        );

        vm.prank(caller);
        vm.expectRevert(IAuth.NotAuthorized.selector);
    }
}

contract SyncRequestsPrices is SyncRequestsBaseTest {
    function testSyncPrices(uint128 pricePoolPerShare_, uint128 pricePoolPerAsset_) public {
        D18 pricePoolPerShare = d18(uint128(bound(pricePoolPerShare_, 1e6, 1e24)));
        D18 pricePoolPerAsset = d18(uint128(bound(pricePoolPerAsset_, 1e4, pricePoolPerShare.inner())));
        D18 priceAssetPerShare = pricePoolPerShare / pricePoolPerAsset;

        (SyncDepositVault syncVault, uint128 assetId) = _deploySyncDepositVault(pricePoolPerShare, pricePoolPerAsset);

        SyncPriceData memory prices =
            syncRequests.prices(syncVault.poolId(), syncVault.trancheId(), assetId, address(erc20), 0);
        assertEq(prices.assetPerShare.inner(), priceAssetPerShare.inner(), "priceAssetPerShare mismatch");
        assertEq(prices.poolPerShare.inner(), pricePoolPerShare.inner(), "pricePoolPerShare mismatch");
        assertEq(prices.poolPerAsset.inner(), pricePoolPerAsset.inner(), "pricePoolPerAsset mismatch");
    }
}
