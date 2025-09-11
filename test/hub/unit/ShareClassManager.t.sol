// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {D18, d18} from "../../../src/misc/types/D18.sol";
import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";
import {MathLib} from "../../../src/misc/libraries/MathLib.sol";
import {PoolId} from "../../../src/common/types/PoolId.sol";
import {AssetId} from "../../../src/common/types/AssetId.sol";
import {PricingLib} from "../../../src/common/libraries/PricingLib.sol";
import {ShareClassId} from "../../../src/common/types/ShareClassId.sol";
import {ShareClassManager} from "../../../src/hub/ShareClassManager.sol";
import {IHubRegistry} from "../../../src/hub/interfaces/IHubRegistry.sol";
import {IShareClassManager} from "../../../src/hub/interfaces/IShareClassManager.sol";
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
        (uint128 totalIssuance, D18 navPerShare) = shareClass.metrics(scId);
        assertEq(totalIssuance, 0);
        assertEq(navPerShare.raw(), 0);
    }

    function testExistence() public view {
        assert(shareClass.exists(poolId, scId));
        assert(!shareClass.exists(poolId, ShareClassId.wrap(bytes16(0))));
    }

    function testDefaultMetadata() public view {
        (string memory name, string memory symbol, bytes32 salt) = shareClass.metadata(scId);
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

        (string memory name_, string memory symbol_,) = shareClass.metadata(scId);
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
        emit IShareClassManager.UpdateShareClass(poolId, scId, d18(2, 1));
        shareClass.updateSharePrice(poolId, scId, d18(2, 1));
    }

    function testIncreaseShareClassIssuance(uint128 amount) public {
        vm.expectEmit();
        emit IShareClassManager.RemoteIssueShares(centrifugeId, poolId, scId, amount);
        shareClass.updateShares(centrifugeId, poolId, scId, amount, true);

        (uint128 totalIssuance_, D18 navPerShareMetric) = shareClass.metrics(scId);
        assertEq(totalIssuance_, amount);
        assertEq(navPerShareMetric.raw(), 0, "navPerShare metric should not be updated");
    }

    function testDecreaseShareClassIssuance(uint128 amount) public {
        shareClass.updateShares(centrifugeId, poolId, scId, amount, true);

        vm.expectEmit();
        emit IShareClassManager.RemoteRevokeShares(centrifugeId, poolId, scId, amount);
        shareClass.updateShares(centrifugeId, poolId, scId, amount, false);

        (uint128 totalIssuance_, D18 navPerShareMetric) = shareClass.metrics(scId);
        assertEq(totalIssuance_, 0, "TotalIssuance should be reset");
        assertEq(navPerShareMetric.raw(), 0, "navPerShare metric should not be updated");
    }
}

contract ShareClassManagerRevertsTest is ShareClassManagerBaseTest {
    function testUpdateSharePriceWrongShareClassId() public {
        ShareClassId wrongScId = ShareClassId.wrap(bytes16(uint128(1337)));
        vm.expectRevert(IShareClassManager.ShareClassNotFound.selector);
        shareClass.updateSharePrice(poolId, wrongScId, d18(2, 1));
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
