// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {D18, d18} from "../../../../src/misc/types/D18.sol";
import {CastLib} from "../../../../src/misc/libraries/CastLib.sol";
import {MathLib} from "../../../../src/misc/libraries/MathLib.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../../src/core/types/AssetId.sol";
import {PricingLib} from "../../../../src/core/libraries/PricingLib.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {ShareClassManager} from "../../../../src/core/hub/ShareClassManager.sol";
import {IHubRegistry} from "../../../../src/core/hub/interfaces/IHubRegistry.sol";
import {IShareClassManager, IssuancePerNetwork} from "../../../../src/core/hub/interfaces/IShareClassManager.sol";

import "forge-std/Test.sol";

uint16 constant CHAIN_ID = 1;
uint64 constant POOL_ID = 42;
uint32 constant SC_ID_INDEX = 1;
ShareClassId constant SC_ID = ShareClassId.wrap(bytes16((uint128(POOL_ID) << 64) + SC_ID_INDEX));
AssetId constant USDC = AssetId.wrap(69);
AssetId constant OTHER_STABLE = AssetId.wrap(1337);
uint8 constant DECIMALS_USDC = 6;
uint8 constant DECIMALS_OTHER_STABLE = 12;
uint8 constant DECIMALS_POOL = 18;
uint128 constant DENO_USDC = uint128(10 ** DECIMALS_USDC);
uint128 constant DENO_OTHER_STABLE = uint128(10 ** DECIMALS_OTHER_STABLE);
uint128 constant DENO_POOL = uint128(10 ** DECIMALS_POOL);
uint128 constant OTHER_STABLE_PER_POOL = 100;
uint128 constant MIN_REQUEST_AMOUNT_USDC = DENO_USDC;
uint128 constant MAX_REQUEST_AMOUNT_USDC = 1e18;
uint128 constant MIN_REQUEST_AMOUNT_SHARES = DENO_POOL;
uint128 constant MAX_REQUEST_AMOUNT_SHARES = type(uint128).max / 1e10;
string constant SC_NAME = "ExampleName";
string constant SC_SYMBOL = "ExampleSymbol";
bytes32 constant SC_SALT = bytes32("ExampleSalt");
bytes32 constant SC_SECOND_SALT = bytes32("AnotherExampleSalt");
uint32 constant STORAGE_INDEX_METRICS = 3;

contract HubRegistryMock {
    function decimals(PoolId) external pure returns (uint8) {
        return DECIMALS_POOL;
    }

    function decimals(AssetId assetId) external pure returns (uint8) {
        if (assetId == USDC) {
            return DECIMALS_USDC;
        } else if (assetId == OTHER_STABLE) {
            return DECIMALS_OTHER_STABLE;
        } else {
            revert("IHubRegistry.decimals() - Unknown assetId");
        }
    }
}

abstract contract ShareClassManagerBaseTest is Test {
    using MathLib for uint128;
    using MathLib for uint256;
    using CastLib for string;
    using PricingLib for *;

    ShareClassManager public shareClass;
    address hubRegistryMock = address(new HubRegistryMock());
    uint16 centrifugeId = 1;
    PoolId poolId = PoolId.wrap(POOL_ID);
    ShareClassId scId = SC_ID;
    bytes32 investor = bytes32("investor");

    modifier notThisContract(address addr) {
        vm.assume(address(this) != addr);
        _;
    }

    function setUp() public virtual {
        shareClass = new ShareClassManager(IHubRegistry(hubRegistryMock), address(this));
        vm.expectEmit();
        emit IShareClassManager.AddShareClass(poolId, scId, SC_ID_INDEX, SC_NAME, SC_SYMBOL, SC_SALT);
        shareClass.addShareClass(poolId, SC_NAME, SC_SYMBOL, SC_SALT);

        assertEq(IHubRegistry(hubRegistryMock).decimals(poolId), DECIMALS_POOL);
        assertEq(IHubRegistry(hubRegistryMock).decimals(USDC), DECIMALS_USDC);
        assertEq(IHubRegistry(hubRegistryMock).decimals(OTHER_STABLE), DECIMALS_OTHER_STABLE);
    }

    function _intoPoolAmount(AssetId assetId, uint128 amount) internal view returns (uint128) {
        return PricingLib.convertWithPrice(
            amount,
            IHubRegistry(hubRegistryMock).decimals(assetId),
            IHubRegistry(hubRegistryMock).decimals(poolId),
            d18(1, 1)
        );
    }

    function _poolAtomsToAsset(AssetId assetId, uint256 poolAtoms) internal view returns (uint128) {
        return PricingLib.convertWithPrice(
            poolAtoms,
            IHubRegistry(hubRegistryMock).decimals(poolId),
            IHubRegistry(hubRegistryMock).decimals(assetId),
            d18(1, 1)
        );
    }

    function _assetToPoolAtoms(AssetId assetId, uint128 amount) internal view returns (uint256) {
        return PricingLib.convertWithPrice(
            amount,
            IHubRegistry(hubRegistryMock).decimals(assetId),
            IHubRegistry(hubRegistryMock).decimals(poolId),
            d18(1, 1)
        );
    }

    function _toD18(uint128 amount, uint8 decimals) internal pure returns (D18) {
        return D18.wrap(uint128(uint256(amount) * 10 ** (18 - decimals)));
    }

    function _fromD18(D18 amount, uint8 decimals) internal pure returns (uint128) {
        return uint128(amount.raw() / 10 ** (18 - decimals));
    }
}

contract ShareClassManagerSimpleTest is ShareClassManagerBaseTest {
    using MathLib for uint128;
    using CastLib for string;

    function testInitialValues() public view {
        assertEq(shareClass.shareClassCount(poolId), 1);
        assert(shareClass.shareClassIds(poolId, scId));
    }

    function testDefaultGetShareClassNavPerShare() public view {
        assertEq(shareClass.totalIssuance(poolId, scId), 0);

        (D18 pricePoolPerShare, uint64 computedAt) = shareClass.pricePoolPerShare(poolId, scId);
        assertEq(pricePoolPerShare.raw(), 0);
        assertEq(computedAt, 0);
    }

    function testExistence() public view {
        assert(shareClass.exists(poolId, scId));
        assert(!shareClass.exists(poolId, ShareClassId.wrap(bytes16(0))));
    }

    function testDefaultMetadata() public view {
        (string memory name, string memory symbol, bytes32 salt) = shareClass.metadata(poolId, scId);
        assertEq(name, SC_NAME);
        assertEq(symbol, SC_SYMBOL);
        assertEq(salt, SC_SALT);
    }

    function testUpdateMetadata(string memory name, string memory symbol) public {
        vm.assume(bytes(name).length > 0 && bytes(name).length <= 128);
        vm.assume(bytes(symbol).length > 0 && bytes(symbol).length <= 32);

        vm.expectEmit();
        emit IShareClassManager.UpdateMetadata(poolId, scId, name, symbol);
        shareClass.updateMetadata(poolId, scId, name, symbol);

        (string memory name_, string memory symbol_,) = shareClass.metadata(poolId, scId);
        assertEq(name, name_, "Metadata name mismatch");
        assertEq(symbol, symbol_, "Metadata symbol mismatch");
    }

    function testPreviewNextShareClassId() public view {
        ShareClassId preview = shareClass.previewNextShareClassId(poolId);
        ShareClassId calc = ShareClassId.wrap(bytes16((uint128(POOL_ID) << 64) + SC_ID_INDEX + 1));
        assertEq(ShareClassId.unwrap(preview), ShareClassId.unwrap(calc));
    }

    function testAddShareClass(string memory name, string memory symbol, bytes32 salt) public {
        vm.assume(bytes(name).length > 0 && bytes(name).length <= 128);
        vm.assume(bytes(symbol).length > 0 && bytes(symbol).length <= 32);
        vm.assume(salt != bytes32(0));
        vm.assume(salt != SC_SALT);

        ShareClassId nextScId = shareClass.previewNextShareClassId(poolId);

        emit IShareClassManager.AddShareClass(poolId, nextScId, 2, name, symbol, salt);
        shareClass.addShareClass(poolId, name, symbol, salt);

        assertEq(shareClass.shareClassCount(poolId), 2);
        assert(shareClass.shareClassIds(poolId, nextScId));
        assert(ShareClassId.unwrap(shareClass.previewNextShareClassId(poolId)) != ShareClassId.unwrap(nextScId));
    }

    function testPreviewShareClassId(uint32 index) public view {
        assertEq(shareClass.previewShareClassId(poolId, index).raw(), bytes16((uint128(poolId.raw()) << 64) + index));
    }

    function testUpdateSharePrice() public {
        vm.expectEmit();
        emit IShareClassManager.UpdatePricePoolPerShare(poolId, scId, d18(2, 1), uint64(block.timestamp));
        shareClass.updateSharePrice(poolId, scId, d18(2, 1), uint64(block.timestamp));
    }

    function testUpdateSharePriceWithPastTimestamp() public {
        uint64 timestamp = uint64(block.timestamp);

        vm.warp(block.timestamp + 3 days);

        vm.expectEmit();
        emit IShareClassManager.UpdatePricePoolPerShare(poolId, scId, d18(1, 1), timestamp);
        shareClass.updateSharePrice(poolId, scId, d18(1, 1), timestamp);

        (D18 price, uint64 computedAt) = shareClass.pricePoolPerShare(poolId, scId);
        assertEq(price.raw(), d18(1, 1).raw());
        assertEq(computedAt, timestamp, "Should store the original computation timestamp");
    }

    function testUpdateSharePriceSequential() public {
        uint64 timestamp1 = uint64(block.timestamp);
        shareClass.updateSharePrice(poolId, scId, d18(1, 1), timestamp1);

        vm.warp(block.timestamp + 1 days);

        // Second update with later timestamp and different price
        uint64 timestamp2 = uint64(block.timestamp);
        vm.expectEmit();
        emit IShareClassManager.UpdatePricePoolPerShare(poolId, scId, d18(11, 10), timestamp2);
        shareClass.updateSharePrice(poolId, scId, d18(11, 10), timestamp2);

        (D18 price, uint64 computedAt) = shareClass.pricePoolPerShare(poolId, scId);
        assertEq(price.raw(), d18(11, 10).raw(), "Should update to new price");
        assertEq(computedAt, timestamp2, "Should update to new timestamp");
        assertGt(computedAt, timestamp1, "New timestamp should be greater than previous");
    }

    function testIncreaseShareClassIssuance(uint128 amount) public {
        vm.expectEmit();
        emit IShareClassManager.RemoteIssueShares(centrifugeId, poolId, scId, amount);
        shareClass.updateShares(centrifugeId, poolId, scId, amount, true);

        IssuancePerNetwork memory ipn = shareClass.pendingIssuance(poolId, scId, centrifugeId);
        assertEq(ipn.issuance, 0, "Settled issuance should be zero");
        assertEq(ipn.pendingIncrease, amount, "Pending increase should match");
        assertEq(ipn.pendingDecrease, 0, "Pending decrease should be zero");

        shareClass.settle(centrifugeId, poolId, scId);

        ipn = shareClass.pendingIssuance(poolId, scId, centrifugeId);

        assertEq(ipn.issuance, amount, "Settled issuance should match");
        assertEq(ipn.pendingIncrease, 0, "Pending increase should be reset");
        assertEq(ipn.pendingDecrease, 0, "Pending decrease should be zero");

        assertEq(shareClass.totalIssuance(poolId, scId), amount);
        (D18 pricePoolPerShare, uint64 computedAt) = shareClass.pricePoolPerShare(poolId, scId);
        assertEq(pricePoolPerShare.raw(), 0, "pricePoolPerShare metric should not be updated");
        assertEq(computedAt, 0);
    }

    function testDecreaseShareClassIssuance(uint128 amount) public {
        shareClass.updateShares(centrifugeId, poolId, scId, amount, true);

        vm.expectEmit();
        emit IShareClassManager.RemoteRevokeShares(centrifugeId, poolId, scId, amount);
        shareClass.updateShares(centrifugeId, poolId, scId, amount, false);

        assertEq(shareClass.totalIssuance(poolId, scId), 0, "TotalIssuance should be reset");
        (D18 pricePoolPerShare, uint64 computedAt) = shareClass.pricePoolPerShare(poolId, scId);
        assertEq(pricePoolPerShare.raw(), 0, "pricePoolPerShare metric should not be updated");
        assertEq(computedAt, 0);
    }
}

contract ShareClassManagerRevertsTest is ShareClassManagerBaseTest {
    function testCannotSetFuturePrice() public {
        vm.expectRevert(IShareClassManager.CannotSetFuturePrice.selector);
        shareClass.updateSharePrice(poolId, scId, d18(2, 1), uint64(block.timestamp + 1));
    }

    function testUpdateSharePriceWrongShareClassId() public {
        ShareClassId wrongScId = ShareClassId.wrap(bytes16(uint128(1337)));
        vm.expectRevert(IShareClassManager.ShareClassNotFound.selector);
        shareClass.updateSharePrice(poolId, wrongScId, d18(2, 1), uint64(block.timestamp));
    }

    function testUpdateMetadataWrongShareClassId() public {
        ShareClassId wrongScId = ShareClassId.wrap(bytes16(uint128(1337)));
        vm.expectRevert(IShareClassManager.ShareClassNotFound.selector);
        shareClass.updateMetadata(poolId, wrongScId, "name", "symbol");
    }

    function testUpdateSharesWrongShareClassId() public {
        ShareClassId wrongScId = ShareClassId.wrap(bytes16(uint128(1337)));
        vm.expectRevert(IShareClassManager.ShareClassNotFound.selector);
        shareClass.updateShares(centrifugeId, poolId, wrongScId, 100, true);
    }

    function testDecreaseOverFlow() public {
        shareClass.updateShares(centrifugeId, poolId, scId, 1, false);

        vm.expectRevert(IShareClassManager.DecreaseMoreThanIssued.selector);
        shareClass.settle(centrifugeId, poolId, scId);
    }

    function testAddShareClassInvalidNameEmpty() public {
        vm.expectRevert(IShareClassManager.InvalidMetadataName.selector);
        shareClass.addShareClass(poolId, "", SC_SYMBOL, SC_SECOND_SALT);
    }

    function testAddShareClassInvalidNameExcess() public {
        vm.expectRevert(IShareClassManager.InvalidMetadataName.selector);
        shareClass.addShareClass(poolId, string(abi.encodePacked(new bytes(129))), SC_SYMBOL, SC_SECOND_SALT);
    }

    function testAddShareClassInvalidSymbolEmpty() public {
        vm.expectRevert(IShareClassManager.InvalidMetadataSymbol.selector);
        shareClass.addShareClass(poolId, SC_NAME, "", SC_SECOND_SALT);
    }

    function testAddShareClassInvalidSymbolExcess() public {
        vm.expectRevert(IShareClassManager.InvalidMetadataSymbol.selector);
        shareClass.addShareClass(poolId, SC_NAME, string(abi.encodePacked(new bytes(33))), SC_SECOND_SALT);
    }

    function testAddShareClassEmptySalt() public {
        vm.expectRevert(IShareClassManager.InvalidSalt.selector);
        shareClass.addShareClass(poolId, SC_NAME, SC_SYMBOL, bytes32(0));
    }

    function testAddShareClassSaltAlreadyUsed() public {
        vm.expectRevert(IShareClassManager.AlreadyUsedSalt.selector);
        shareClass.addShareClass(poolId, SC_NAME, SC_SYMBOL, SC_SALT);
    }

    function testUpdateMetadataClassInvalidNameEmpty() public {
        vm.expectRevert(IShareClassManager.InvalidMetadataName.selector);
        shareClass.updateMetadata(poolId, scId, "", SC_SYMBOL);
    }

    function testUpdateMetadataClassInvalidNameExcess() public {
        vm.expectRevert(IShareClassManager.InvalidMetadataName.selector);
        shareClass.updateMetadata(poolId, scId, string(abi.encodePacked(new bytes(129))), SC_SYMBOL);
    }

    function testUpdateMetadataClassInvalidSymbolEmpty() public {
        vm.expectRevert(IShareClassManager.InvalidMetadataSymbol.selector);
        shareClass.updateMetadata(poolId, scId, SC_NAME, "");
    }

    function testUpdateMetadataClassInvalidSymbolExcess() public {
        vm.expectRevert(IShareClassManager.InvalidMetadataSymbol.selector);
        shareClass.updateMetadata(poolId, scId, SC_NAME, string(abi.encodePacked(new bytes(33))));
    }
}
