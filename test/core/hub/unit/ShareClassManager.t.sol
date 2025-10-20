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
import {IShareClassManager} from "../../../../src/core/hub/interfaces/IShareClassManager.sol";

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
        // vm.expectRevert(ShareClassManager.DecreaseMoreThanIssued.selector); // Error doesn't exist
        vm.expectRevert();
        shareClass.updateShares(centrifugeId, poolId, scId, 1, false);
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

contract ShareClassManagerPendingIssuanceTest is ShareClassManagerBaseTest {
    function testIssuanceViewAfterIssue() public {
        uint128 amount = 1000;
        shareClass.updateShares(centrifugeId, poolId, scId, amount, true);

        assertEq(shareClass.issuance(poolId, scId, centrifugeId), amount);
        assertEq(shareClass.totalIssuance(poolId, scId), amount);
    }

    function testIssuanceViewAfterRevoke() public {
        uint128 issueAmount = 1000;
        uint128 revokeAmount = 300;

        shareClass.updateShares(centrifugeId, poolId, scId, issueAmount, true);
        shareClass.updateShares(centrifugeId, poolId, scId, revokeAmount, false);

        assertEq(shareClass.issuance(poolId, scId, centrifugeId), issueAmount - revokeAmount);
        assertEq(shareClass.totalIssuance(poolId, scId), issueAmount - revokeAmount);
    }

    function testIssuanceViewMultipleIssuesAndRevokes() public {
        // Issue 1000
        shareClass.updateShares(centrifugeId, poolId, scId, 1000, true);
        assertEq(shareClass.issuance(poolId, scId, centrifugeId), 1000);

        // Revoke 300
        shareClass.updateShares(centrifugeId, poolId, scId, 300, false);
        assertEq(shareClass.issuance(poolId, scId, centrifugeId), 700);

        // Issue another 500
        shareClass.updateShares(centrifugeId, poolId, scId, 500, true);
        assertEq(shareClass.issuance(poolId, scId, centrifugeId), 1200);

        // Revoke 200
        shareClass.updateShares(centrifugeId, poolId, scId, 200, false);
        assertEq(shareClass.issuance(poolId, scId, centrifugeId), 1000);
    }

    function testIssuanceViewMultipleNetworks() public {
        uint16 network1 = 1;
        uint16 network2 = 2;

        shareClass.updateShares(network1, poolId, scId, 1000, true);
        shareClass.updateShares(network2, poolId, scId, 2000, true);

        assertEq(shareClass.issuance(poolId, scId, network1), 1000);
        assertEq(shareClass.issuance(poolId, scId, network2), 2000);
        assertEq(shareClass.totalIssuance(poolId, scId), 3000);

        shareClass.updateShares(network1, poolId, scId, 300, false);

        assertEq(shareClass.issuance(poolId, scId, network1), 700);
        assertEq(shareClass.issuance(poolId, scId, network2), 2000);
        assertEq(shareClass.totalIssuance(poolId, scId), 2700);
    }

    function testNegativeIssuanceReverts() public {
        // Issue on another network to keep totalIssuance positive
        shareClass.updateShares(2, poolId, scId, 1000, true);

        // Try to revoke without any issuance on network 1
        shareClass.updateShares(centrifugeId, poolId, scId, 100, false);

        // Reading issuance for network 1 should revert with NegativeIssuance
        vm.expectRevert(IShareClassManager.NegativeIssuance.selector);
        shareClass.issuance(poolId, scId, centrifugeId);

        // But we can still read issuance for network 2
        assertEq(shareClass.issuance(poolId, scId, 2), 1000);
    }

    function testNegativeIssuanceRevertsAfterPartialRevoke() public {
        // Issue 500 on network 1 and 1000 on network 2
        shareClass.updateShares(centrifugeId, poolId, scId, 500, true);
        shareClass.updateShares(2, poolId, scId, 1000, true);

        // Revoke 600 on network 1 (more than issued on that network)
        shareClass.updateShares(centrifugeId, poolId, scId, 600, false);

        // This should revert when trying to read issuance for network 1
        vm.expectRevert(IShareClassManager.NegativeIssuance.selector);
        shareClass.issuance(poolId, scId, centrifugeId);

        // But we can still read issuance for network 2
        assertEq(shareClass.issuance(poolId, scId, 2), 1000);

        // Total issuance should be 500 + 1000 - 600 = 900
        assertEq(shareClass.totalIssuance(poolId, scId), 900);
    }

    function testTotalIssuanceWithNegativeNetwork() public {
        // Issue on network 1
        shareClass.updateShares(1, poolId, scId, 1000, true);

        // Create negative issuance on network 2 (revoke more than issued)
        shareClass.updateShares(2, poolId, scId, 500, false);

        // Total issuance should reflect the revocation
        assertEq(shareClass.totalIssuance(poolId, scId), 500);

        // But reading issuance for network 2 should revert
        vm.expectRevert(IShareClassManager.NegativeIssuance.selector);
        shareClass.issuance(poolId, scId, 2);
    }

    function testFuzzIssuanceAccounting(uint128 issue1, uint128 revoke1, uint128 issue2) public {
        vm.assume(issue1 >= revoke1);
        vm.assume(uint256(issue1) + uint256(issue2) <= type(uint128).max);
        vm.assume(uint256(issue1) - uint256(revoke1) + uint256(issue2) <= type(uint128).max);

        shareClass.updateShares(centrifugeId, poolId, scId, issue1, true);
        shareClass.updateShares(centrifugeId, poolId, scId, revoke1, false);
        shareClass.updateShares(centrifugeId, poolId, scId, issue2, true);

        uint128 expectedIssuance = issue1 - revoke1 + issue2;
        assertEq(shareClass.issuance(poolId, scId, centrifugeId), expectedIssuance);
        assertEq(shareClass.totalIssuance(poolId, scId), expectedIssuance);
    }
}
