// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AssetId, VaultBaseTest as BaseTest, PoolId, ShareClassId, SyncDepositVault} from "./VaultBaseTest.sol";

import {D18, d18} from "../../../src/misc/types/D18.sol";
import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {MathLib} from "../../../src/misc/libraries/MathLib.sol";

import {MessageLib} from "../../../src/core/messaging/libraries/MessageLib.sol";

import {IBaseVault} from "../../../src/vaults/interfaces/IBaseVault.sol";
import {IBaseRequestManager} from "../../../src/vaults/interfaces/IBaseRequestManager.sol";
import {ISyncManager, ISyncDepositValuation} from "../../../src/vaults/interfaces/IVaultManagers.sol";

contract SyncManagerBaseTest is BaseTest {
    function _deploySyncDepositVault(D18 pricePoolPerShare, D18 pricePoolPerAsset)
        internal
        returns (SyncDepositVault syncVault, uint128 assetId)
    {
        (, address syncVault_, uint128 assetId_) = deploySimpleVault(syncDepositVaultFactory);
        assetId = assetId_;
        syncVault = SyncDepositVault(syncVault_);

        centrifugeChain.updatePricePoolPerShare(
            syncVault.poolId().raw(), syncVault.scId().raw(), pricePoolPerShare.raw(), uint64(block.timestamp)
        );
        centrifugeChain.updatePricePoolPerAsset(
            syncVault.poolId().raw(), syncVault.scId().raw(), assetId, pricePoolPerAsset.raw(), uint64(block.timestamp)
        );
    }

    function _setValuation(SyncDepositVault vault, address valuation_) internal {
        vm.expectEmit();
        emit ISyncManager.SetValuation(vault.poolId(), vault.scId(), valuation_);
        syncManager.setValuation(vault.poolId(), vault.scId(), valuation_);
        assertEq(address(syncManager.valuation(vault.poolId(), vault.scId())), valuation_);
    }
}

contract SyncManagerTest is SyncManagerBaseTest {
    using MessageLib for *;

    // --- Administration ---
    function testFile() public {
        // fail: unrecognized param
        vm.expectRevert(IBaseRequestManager.FileUnrecognizedParam.selector);
        syncManager.file("random", self);

        assertEq(address(syncManager.spoke()), address(spoke));
        assertEq(address(syncManager.spokeRegistry()), address(spokeRegistry));

        // success
        syncManager.file("spoke", randomUser);
        assertEq(address(syncManager.spoke()), randomUser);
        syncManager.file("spokeRegistry", randomUser);
        assertEq(address(syncManager.spokeRegistry()), randomUser);

        // remove self from wards
        syncManager.deny(self);
        // auth fail
        vm.expectRevert(IAuth.NotAuthorized.selector);
        syncManager.file("spoke", randomUser);
    }

    // --- Simple Errors ---
    function testMintUnlinkedVault() public {
        (SyncDepositVault vault, uint128 assetId) = _deploySyncDepositVault(d18(1), d18(1));
        spokeRegistry.unlinkVault(vault.poolId(), vault.scId(), AssetId.wrap(assetId), address(vault));

        vm.expectRevert(ISyncManager.ExceedsMaxMint.selector);
        syncManager.mint(vault, 1, address(0), address(0));
    }

    function testDepositUnlinkedVault() public {
        (SyncDepositVault vault, uint128 assetId) = _deploySyncDepositVault(d18(1), d18(1));
        spokeRegistry.unlinkVault(vault.poolId(), vault.scId(), AssetId.wrap(assetId), address(vault));

        vm.expectRevert(ISyncManager.ExceedsMaxDeposit.selector);
        syncManager.deposit(vault, 1, address(0), address(0));
    }
}

contract SyncManagerUnauthorizedTest is SyncManagerBaseTest {
    function testFileUnauthorized() public {
        _expectUnauthorized();
        syncManager.file(bytes32(0), address(0));
    }

    function testDepositUnauthorized() public {
        _expectUnauthorized();
        syncManager.deposit(IBaseVault(address(0)), 0, address(0), address(0));
    }

    function testMintUnauthorized() public {
        _expectUnauthorized();
        syncManager.mint(IBaseVault(address(0)), 0, address(0), address(0));
    }

    function testSetValuationUnauthorized() public {
        _expectUnauthorized();
        syncManager.setValuation(PoolId.wrap(0), ShareClassId.wrap(0), address(0));
    }

    function testSetMaxReserveUnauthorized() public {
        _expectUnauthorized();
        syncManager.setMaxReserve(PoolId.wrap(0), ShareClassId.wrap(0), address(0), 0, 0);
    }

    function _expectUnauthorized() internal {
        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
    }
}

contract SyncManagerFromHubTest is SyncManagerBaseTest {
    using MessageLib for *;

    function testFromHubNotEnvoy() public {
        vm.prank(makeAddr("notEnvoy"));
        vm.expectRevert(ISyncManager.NotEnvoy.selector);
        syncManager.fromHub(PoolId.wrap(0), bytes(""));
    }

    function testUnknownTrustedCall() public {
        PoolId testPool = PoolId.wrap(999);
        ShareClassId testSc = ShareClassId.wrap(bytes16("testsc"));

        // Create payload with invalid enum value (max enum value + 1)
        bytes memory invalidPayload = abi.encode(testSc.raw(), uint8(255), bytes32(0));

        vm.prank(address(envoy));
        vm.expectRevert(ISyncManager.UnknownTrustedCall.selector);
        syncManager.fromHub(testPool, invalidPayload);
    }

    function testFromHubValuation() public {
        (SyncDepositVault vault,) = _deploySyncDepositVault(d18(1), d18(1));
        address newValuation = makeAddr("newValuation");

        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        bytes memory payload =
            abi.encode(scId.raw(), uint8(ISyncManager.TrustedCall.Valuation), bytes32(bytes20(newValuation)));

        vm.expectEmit();
        emit ISyncManager.SetValuation(poolId, scId, newValuation);

        vm.prank(address(envoy));
        syncManager.fromHub(poolId, payload);

        assertEq(address(syncManager.valuation(poolId, scId)), newValuation);
    }

    function testFromHubValuationShareTokenDoesNotExist() public {
        PoolId nonExistentPool = PoolId.wrap(999);
        ShareClassId nonExistentSc = ShareClassId.wrap(bytes16("nonexistent"));
        address newValuation = makeAddr("newValuation");

        bytes memory payload =
            abi.encode(nonExistentSc.raw(), uint8(ISyncManager.TrustedCall.Valuation), bytes32(bytes20(newValuation)));

        vm.prank(address(envoy));
        vm.expectRevert(ISyncManager.ShareTokenDoesNotExist.selector);
        syncManager.fromHub(nonExistentPool, payload);
    }

    function testFromHubMaxReserve() public {
        (SyncDepositVault vault, uint128 assetId) = _deploySyncDepositVault(d18(1), d18(1));
        uint128 newMaxReserve = 1_000_000e6;

        (address asset, uint256 tokenId) = spokeRegistry.idToAsset(AssetId.wrap(assetId));

        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        bytes memory payload =
            abi.encode(scId.raw(), uint8(ISyncManager.TrustedCall.MaxReserve), assetId, newMaxReserve);

        vm.expectEmit();
        emit ISyncManager.SetMaxReserve(poolId, scId, asset, tokenId, newMaxReserve);

        vm.prank(address(envoy));
        syncManager.fromHub(poolId, payload);

        assertEq(syncManager.maxReserve(poolId, scId, asset, tokenId), newMaxReserve);
    }

    function testFromHubMaxReserveShareTokenDoesNotExist() public {
        PoolId nonExistentPool = PoolId.wrap(999);
        ShareClassId nonExistentSc = ShareClassId.wrap(bytes16("nonexistent"));
        uint128 assetId = 1;
        uint128 newMaxReserve = 1_000_000e6;

        bytes memory payload =
            abi.encode(nonExistentSc.raw(), uint8(ISyncManager.TrustedCall.MaxReserve), assetId, newMaxReserve);

        vm.prank(address(envoy));
        vm.expectRevert(ISyncManager.ShareTokenDoesNotExist.selector);
        syncManager.fromHub(nonExistentPool, payload);
    }
}

contract SyncManagerUpdateValuation is SyncManagerBaseTest {
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

    function _assertPrices(
        SyncDepositVault syncVault,
        D18 prePoolPerShare,
        D18 expectedPoolPerAsset,
        D18 expectedPoolPerShare,
        uint128 assetId
    ) internal view {
        D18 poolPerShare = syncManager.pricePoolPerShare(syncVault.poolId(), syncVault.scId());
        D18 poolPerAsset =
            spokeRegistry.pricePoolPerAsset(syncVault.poolId(), syncVault.scId(), AssetId.wrap(assetId), true);

        assertNotEq(prePoolPerShare.raw(), expectedPoolPerShare.raw(), "Price should be changed by valuation");
        assertEq(poolPerShare.raw(), expectedPoolPerShare.raw(), "poolPerShare mismatch");
        assertEq(poolPerAsset.raw(), expectedPoolPerAsset.raw(), "poolPerAsset mismatch");
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
        D18 pricePre = syncManager.pricePoolPerShare(syncVault.poolId(), syncVault.scId());

        _setValuation(syncVault, valuation_);

        // Change pricePoolPerShare
        pricePoolPerShare = d18(20e18);
        priceAssetPerShare = d18(4e18); // 20e18 / 5e18

        // Mock valuation and perform checks
        _mockValuation(syncVault, pricePoolPerShare);
        _assertPrices(syncVault, pricePre, pricePoolPerAsset, pricePoolPerShare, assetId);
    }

    function testFuzzedPricesWithValuationERC20(
        uint128 pricePoolPerShare_,
        uint128 pricePoolPerAsset_,
        uint8 multiplier_
    ) public {
        D18 pricePoolPerShare = d18(uint128(bound(pricePoolPerShare_, 1e8, 1e24)));
        D18 pricePoolPerAsset = d18(uint128(bound(pricePoolPerAsset_, 1e6, pricePoolPerShare.raw())));
        D18 priceAssetPerShare = pricePoolPerShare / pricePoolPerAsset;
        uint128 multiplier = uint128(bound(multiplier_, 2, 10));
        vm.assume(priceAssetPerShare.raw() % multiplier == 0);

        (SyncDepositVault syncVault, uint128 assetId) = _deploySyncDepositVault(pricePoolPerShare, pricePoolPerAsset);
        D18 pricePre = syncManager.pricePoolPerShare(syncVault.poolId(), syncVault.scId());

        _setValuation(syncVault, valuation_);

        // Change pricePoolPerShare
        pricePoolPerShare = d18(pricePoolPerShare.raw() * multiplier);
        priceAssetPerShare = pricePoolPerShare / pricePoolPerAsset;

        // Mock valuation and perform checks
        _mockValuation(syncVault, pricePoolPerShare);
        _assertPrices(syncVault, pricePre, pricePoolPerAsset, pricePoolPerShare, assetId);
    }
}
