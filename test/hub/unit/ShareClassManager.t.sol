// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {MathLib} from "src/misc/libraries/MathLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {ConversionLib} from "src/misc/libraries/ConversionLib.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {
    IShareClassManager,
    EpochInvestAmounts,
    EpochRedeemAmounts,
    UserOrder,
    ShareClassMetadata,
    ShareClassMetrics,
    QueuedOrder,
    RequestType
} from "src/hub/interfaces/IShareClassManager.sol";
import {IShareClassManager} from "src/hub/interfaces/IShareClassManager.sol";
import {IHubRegistry} from "src/hub/interfaces/IHubRegistry.sol";
import {ShareClassManager} from "src/hub/ShareClassManager.sol";

uint64 constant POOL_ID = 42;
uint32 constant SC_ID_INDEX = 1;
ShareClassId constant SC_ID = ShareClassId.wrap(bytes16((uint128(POOL_ID) << 64) + SC_ID_INDEX));
address constant POOL_CURRENCY = address(840);
AssetId constant USDC = AssetId.wrap(69);
AssetId constant OTHER_STABLE = AssetId.wrap(1337);
uint8 constant DECIMALS_USDC = 6;
uint8 constant DECIMALS_OTHER_STABLE = 12;
uint8 constant DECIMALS_POOL = 18;
uint128 constant DENO_USDC = uint128(10 ** DECIMALS_USDC);
uint128 constant DENO_OTHER_STABLE = uint128(10 ** DECIMALS_OTHER_STABLE);
uint128 constant DENO_POOL = uint128(10 ** DECIMALS_POOL);
uint128 constant MIN_REQUEST_AMOUNT_USDC = DENO_USDC;
uint128 constant MAX_REQUEST_AMOUNT_USDC = 1e18;
uint128 constant MIN_REQUEST_AMOUNT_SHARES = DENO_POOL;
uint128 constant MAX_REQUEST_AMOUNT_SHARES = type(uint128).max / 1e10;
string constant SC_NAME = "ExampleName";
string constant SC_SYMBOL = "ExampleSymbol";
bytes32 constant SC_SALT = bytes32("ExampleSalt");
bytes32 constant SC_SECOND_SALT = bytes32("AnotherExampleSalt");

uint32 constant STORAGE_INDEX_EPOCH_ID = 3;
uint32 constant STORAGE_INDEX_METRICS = 5;
uint32 constant STORAGE_INDEX_EPOCH_POINTERS = 8;

contract HubRegistryMock {
    function currency(PoolId) external pure returns (AssetId) {
        return AssetId.wrap(uint64(uint160(POOL_CURRENCY)));
    }

    function decimals(PoolId) external pure returns (uint8) {
        return DECIMALS_POOL;
    }

    function decimals(AssetId assetId) external pure returns (uint8) {
        if (assetId.eq(USDC)) {
            return DECIMALS_USDC;
        } else if (assetId.eq(OTHER_STABLE)) {
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
    using ConversionLib for *;

    ShareClassManager public shareClass;

    address hubRegistryMock = address(new HubRegistryMock());

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
        shareClass.addShareClass(poolId, SC_NAME, SC_SYMBOL, SC_SALT, bytes(""));

        assertEq(IHubRegistry(hubRegistryMock).currency(poolId).addr(), POOL_CURRENCY);
        assertEq(IHubRegistry(hubRegistryMock).decimals(poolId), DECIMALS_POOL);
        assertEq(IHubRegistry(hubRegistryMock).decimals(USDC), DECIMALS_USDC);
        assertEq(IHubRegistry(hubRegistryMock).decimals(OTHER_STABLE), DECIMALS_OTHER_STABLE);
    }

    function _intoPoolAmount(AssetId assetId, uint128 amount) internal view returns (uint128) {
        return ConversionLib.convertWithPrice(
            amount,
            IHubRegistry(hubRegistryMock).decimals(assetId),
            IHubRegistry(hubRegistryMock).decimals(poolId),
            _pricePoolPerAsset(assetId)
        ).toUint128();
    }

    function _calcSharesIssued(AssetId assetId, uint128 depositAmountAsset, D18 pricePoolPerShare)
        internal
        returns (uint128)
    {
        return ConversionLib.convertWithPrice(
            depositAmountAsset,
            IHubRegistry(hubRegistryMock).decimals(assetId),
            IHubRegistry(hubRegistryMock).decimals(poolId),
            _pricePoolPerAsset(assetId) / pricePoolPerShare
        ).toUint128();
    }

    function _pricePoolPerAsset(AssetId assetId) internal pure returns (D18) {
        if (assetId.eq(USDC)) {
            return d18(1, 1);
        } else if (assetId.eq(OTHER_STABLE)) {
            return d18(1, 2);
        } else {
            revert("ShareClassManagerBaseTest._priceAssetPerPool() - Unknown assetId");
        }
    }

    function _assertDepositRequestEq(AssetId asset, bytes32 investor_, UserOrder memory expected) internal view {
        (uint128 pending, uint32 lastUpdate) = shareClass.depositRequest(scId, asset, investor_);

        assertEq(pending, expected.pending, "Mismatch: Deposit UserOrder.pending");
        assertEq(lastUpdate, expected.lastUpdate, "Mismatch: Deposit UserOrder.lastUpdate");
    }

    function _assertQueuedDepositRequestEq(AssetId asset, bytes32 investor_, QueuedOrder memory expected)
        internal
        view
    {
        (bool isCancelling, uint128 amount) = shareClass.queuedDepositRequest(scId, asset, investor_);

        assertEq(isCancelling, expected.isCancelling, "isCancelling deposit mismatch");
        assertEq(amount, expected.amount, "amount deposit mismatch");
    }

    function _assertRedeemRequestEq(AssetId asset, bytes32 investor_, UserOrder memory expected) internal view {
        (uint128 pending, uint32 lastUpdate) = shareClass.redeemRequest(scId, asset, investor_);

        assertEq(pending, expected.pending, "Mismatch: Redeem UserOrder.pending");
        assertEq(lastUpdate, expected.lastUpdate, "Mismatch: Redeem UserOrder.lastUpdate");
    }

    function _assertQueuedRedeemRequestEq(AssetId asset, bytes32 investor_, QueuedOrder memory expected)
        internal
        view
    {
        (bool isCancelling, uint128 amount) = shareClass.queuedRedeemRequest(scId, asset, investor_);

        assertEq(isCancelling, expected.isCancelling, "isCancelling deposit mismatch");
        assertEq(amount, expected.amount, "amount deposit mismatch");
    }

    function _assertEpochInvestAmountsEq(AssetId assetId, uint32 epochId, EpochInvestAmounts memory expected)
        internal
        view
    {
        (
            uint128 pendingAssetAmount,
            uint128 approvedAssetAmount,
            uint128 approvedPoolAmount,
            D18 pricePoolPerAsset,
            D18 navPoolPerShare,
            uint64 issuedAt
        ) = shareClass.epochInvestAmounts(scId, assetId, epochId);

        assertEq(pendingAssetAmount, expected.pendingAssetAmount, "Mismatch: EpochInvestAmount.pendingAssetAmount");
        assertEq(approvedAssetAmount, expected.approvedAssetAmount, "Mismatch: EpochInvestAmount.approvedAssetAmount");
        assertEq(approvedPoolAmount, expected.approvedPoolAmount, "Mismatch: EpochInvestAmount.approvedPoolAmount");
        assertEq(
            pricePoolPerAsset.raw(), expected.pricePoolPerAsset.raw(), "Mismatch: EpochInvestAmount.pricePoolPerAsset"
        );
        assertEq(navPoolPerShare.raw(), expected.navPoolPerShare.raw(), "Mismatch: EpochInvestAmount.navPoolPerShare");
        assertEq(issuedAt, expected.issuedAt, "Mismatch: EpochInvestAmount.issuedAt");
    }

    function _assertEpochRedeemAmountsEq(AssetId assetId, uint32 epochId, EpochRedeemAmounts memory expected)
        internal
        view
    {}

    function _totalIssuance() internal view returns (uint128 totalIssuance_) {
        (totalIssuance_,) = shareClass.metrics(scId);
    }

    function _nowDeposit(AssetId assetId) internal view returns (uint32) {
        return shareClass.nowDepositEpoch(scId, assetId);
    }

    function _nowIssue(AssetId assetId) internal view returns (uint32) {
        return shareClass.nowIssueEpoch(scId, assetId);
    }
}

///@dev Contains all simple tests which are expected to succeed
contract ShareClassManagerSimpleTest is ShareClassManagerBaseTest {
    using MathLib for uint128;
    using CastLib for string;

    function testDeployment(address nonWard) public view {
        vm.assume(nonWard != address(shareClass.hubRegistry()) && nonWard != address(this));

        assertEq(address(shareClass.hubRegistry()), hubRegistryMock);
        assertEq(shareClass.nowDepositEpoch(scId, USDC), 1);
        assertEq(shareClass.nowRedeemEpoch(scId, USDC), 1);
        assertEq(shareClass.shareClassCount(poolId), 1);
        assert(shareClass.shareClassIds(poolId, scId));

        assertEq(shareClass.wards(address(this)), 1);
        assertEq(shareClass.wards(address(shareClass.hubRegistry())), 0);

        assertEq(shareClass.wards(nonWard), 0);
    }

    function testFile() public {
        address hubRegistryNew = makeAddr("hubRegistryNew");
        vm.expectEmit(true, true, true, true);
        emit IShareClassManager.File("hubRegistry", hubRegistryNew);
        shareClass.file("hubRegistry", hubRegistryNew);

        assertEq(address(shareClass.hubRegistry()), hubRegistryNew);
    }

    function testDefaultGetShareClassNavPerShare() public view {
        (uint128 totalIssuance, D18 navPerShare) = shareClass.metrics(scId);
        assertEq(totalIssuance, 0);
        assertEq(navPerShare.inner(), 0);
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

    function testUpdateMetadata(string memory name, string memory symbol, bytes32 salt) public {
        vm.assume(bytes(name).length > 0 && bytes(name).length <= 128);
        vm.assume(bytes(symbol).length > 0 && bytes(symbol).length <= 32);
        vm.assume(salt != SC_SALT && salt != bytes32(0));
        vm.assume(salt != bytes32(0));

        // New salt triggers revert
        vm.expectRevert(IShareClassManager.InvalidSalt.selector);
        shareClass.updateMetadata(poolId, scId, name, symbol, salt, bytes(""));

        vm.expectEmit();
        emit IShareClassManager.UpdateMetadata(poolId, scId, name, symbol, SC_SALT);
        shareClass.updateMetadata(poolId, scId, name, symbol, SC_SALT, bytes(""));

        (string memory name_, string memory symbol_, bytes32 salt_) = shareClass.metadata(scId);

        assertEq(name, name_, "Metadata name mismatch");
        assertEq(symbol, symbol_, "Metadata symbol mismatch");
        assertEq(SC_SALT, salt_, "Salt mismatch");
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

        // Mock epochId to 5
        uint32 mockEpochId = 42;
        vm.store(
            address(shareClass),
            keccak256(abi.encode(poolId, uint256(STORAGE_INDEX_EPOCH_ID))),
            bytes32(uint256(mockEpochId))
        );

        ShareClassId nextScId = shareClass.previewNextShareClassId(poolId);

        emit IShareClassManager.AddShareClass(poolId, nextScId, 2, name, symbol, salt);
        shareClass.addShareClass(poolId, name, symbol, salt, bytes(""));

        assertEq(shareClass.shareClassCount(poolId), 2);
        assert(shareClass.shareClassIds(poolId, nextScId));
        assert(ShareClassId.unwrap(shareClass.previewNextShareClassId(poolId)) != ShareClassId.unwrap(nextScId));
    }

    function testPreviewShareClassId(uint32 index) public view {
        assertEq(shareClass.previewShareClassId(poolId, index).raw(), bytes16((uint128(poolId.raw()) << 64) + index));
    }

    function testUpdatePricePerShare() public {
        vm.expectEmit();
        emit IShareClassManager.UpdateShareClass(poolId, scId, 0, d18(2, 1), 0);
        shareClass.updatePricePerShare(poolId, scId, d18(2, 1));
    }

    function testIncreaseShareClassIssuance(uint128 amount) public {
        vm.expectEmit();
        emit IShareClassManager.RemoteIssueShares(poolId, scId, amount);
        shareClass.increaseShareClassIssuance(poolId, scId, amount);

        (uint128 totalIssuance_, D18 navPerShareMetric) = shareClass.metrics(scId);
        assertEq(totalIssuance_, amount);
        assertEq(navPerShareMetric.inner(), 0, "navPerShare metric should not be updated");
    }

    function testDecreaseShareClassIssuance(uint128 amount) public {
        shareClass.increaseShareClassIssuance(poolId, scId, amount);
        vm.expectEmit();
        emit IShareClassManager.RemoteRevokeShares(poolId, scId, amount);
        shareClass.decreaseShareClassIssuance(poolId, scId, amount);

        (uint128 totalIssuance_, D18 navPerShareMetric) = shareClass.metrics(scId);
        assertEq(totalIssuance_, 0, "TotalIssuance should be reset");
        assertEq(navPerShareMetric.inner(), 0, "navPerShare metric should not be updated");
    }
}

///@dev Contains all deposit related tests which are expected to succeed and don't make use of transient storage
contract ShareClassManagerDepositsNonTransientTest is ShareClassManagerBaseTest {
    using MathLib for *;

    function _deposit(uint128 depositAmountUsdc_, uint128 approvedAmountUsdc_)
        internal
        returns (uint128 depositAmountUsdc, uint128 approvedAmountUsdc, uint128 approvedAmountPool)
    {
        depositAmountUsdc = uint128(bound(depositAmountUsdc_, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC));
        approvedAmountUsdc = uint128(bound(approvedAmountUsdc, MIN_REQUEST_AMOUNT_USDC - 1, depositAmountUsdc));
        approvedAmountPool = _intoPoolAmount(USDC, approvedAmountUsdc);

        shareClass.requestDeposit(poolId, scId, depositAmountUsdc, investor, USDC);
        shareClass.approveDeposits(poolId, scId, USDC, _nowDeposit(USDC), approvedAmountUsdc, _pricePoolPerAsset(USDC));
    }

    function testRequestDeposit(uint128 amount) public {
        amount = uint128(bound(amount, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC));

        assertEq(shareClass.pendingDeposit(scId, USDC), 0);
        _assertDepositRequestEq(USDC, investor, UserOrder(0, 0));

        vm.expectEmit(true, true, true, true);
        emit IShareClassManager.UpdateDepositRequest(
            poolId, scId, USDC, shareClass.nowDepositEpoch(scId, USDC), investor, amount, amount, 0, false
        );
        shareClass.requestDeposit(poolId, scId, amount, investor, USDC);

        assertEq(shareClass.pendingDeposit(scId, USDC), amount);
        _assertDepositRequestEq(USDC, investor, UserOrder(amount, 1));
    }

    function testCancelDepositRequest(uint128 amount) public {
        amount = uint128(bound(amount, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC));
        shareClass.requestDeposit(poolId, scId, amount, investor, USDC);

        vm.expectEmit(true, true, true, true);
        emit IShareClassManager.UpdateDepositRequest(
            poolId, scId, USDC, shareClass.nowDepositEpoch(scId, USDC), investor, 0, 0, 0, false
        );
        (uint128 cancelledAmount) = shareClass.cancelDepositRequest(poolId, scId, investor, USDC);

        assertEq(cancelledAmount, amount);
        assertEq(shareClass.pendingDeposit(scId, USDC), 0);
        _assertDepositRequestEq(USDC, investor, UserOrder(0, 1));
    }

    function testApproveDepositsSingleAssetManyInvestors(
        uint8 numInvestors,
        uint128 depositAmount,
        uint128 approvedUsdc
    ) public {
        numInvestors = uint8(bound(numInvestors, 1, 100));
        depositAmount = uint128(bound(depositAmount, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC));
        approvedUsdc = uint128(bound(approvedUsdc, 1, numInvestors * depositAmount));

        uint128 deposits = 0;
        for (uint16 i = 0; i < numInvestors; i++) {
            bytes32 investor = bytes32(uint256(keccak256(abi.encodePacked("investor_", i))));
            uint128 investorDeposit = depositAmount + i;
            deposits += investorDeposit;
            shareClass.requestDeposit(poolId, scId, investorDeposit, investor, USDC);

            assertEq(shareClass.pendingDeposit(scId, USDC), deposits);
        }

        assertEq(_nowDeposit(USDC), 1);

        vm.expectEmit();
        emit IShareClassManager.ApproveDeposits(
            poolId,
            scId,
            USDC,
            _nowDeposit(USDC),
            _intoPoolAmount(USDC, approvedUsdc),
            approvedUsdc,
            deposits - approvedUsdc
        );
        shareClass.approveDeposits(poolId, scId, USDC, _nowDeposit(USDC), approvedUsdc, _pricePoolPerAsset(USDC));

        assertEq(shareClass.pendingDeposit(scId, USDC), deposits - approvedUsdc);

        // Only one epoch should have passed
        assertEq(_nowDeposit(USDC), 2);

        _assertEpochInvestAmountsEq(
            USDC,
            1,
            EpochInvestAmounts(
                deposits,
                approvedUsdc,
                _intoPoolAmount(USDC, approvedUsdc),
                _pricePoolPerAsset(USDC),
                d18(0),
                0 /* Not yet issued */
            )
        );
    }

    function testApproveDepositsTwoAssetsSameEpoch(uint128 depositAmount, uint128 approvedUSDC) public {
        uint128 depositAmountUsdc = uint128(bound(depositAmount, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC));
        uint128 depositAmountOther =
            uint128(bound(depositAmount, MIN_REQUEST_AMOUNT_USDC / 100, MAX_REQUEST_AMOUNT_USDC / 100));
        uint128 approvedUsdc = uint128(bound(approvedUSDC, MIN_REQUEST_AMOUNT_USDC - 1, depositAmountUsdc));
        uint128 approvedOtherStable =
            uint128(bound(approvedUSDC, MIN_REQUEST_AMOUNT_USDC / 100 - 1, depositAmountOther));

        bytes32 investorUsdc = bytes32("investorUsdc");
        bytes32 investorOther = bytes32("investorOther");

        shareClass.requestDeposit(poolId, scId, depositAmountUsdc, investorUsdc, USDC);
        shareClass.requestDeposit(poolId, scId, depositAmountOther, investorOther, OTHER_STABLE);

        assertEq(_nowDeposit(USDC), 1);
        assertEq(_nowDeposit(OTHER_STABLE), 1);

        shareClass.approveDeposits(poolId, scId, USDC, _nowDeposit(USDC), approvedUsdc, _pricePoolPerAsset(USDC));
        shareClass.approveDeposits(
            poolId, scId, OTHER_STABLE, _nowDeposit(OTHER_STABLE), approvedOtherStable, _pricePoolPerAsset(OTHER_STABLE)
        );

        assertEq(_nowDeposit(USDC), 2);
        assertEq(_nowDeposit(OTHER_STABLE), 2);

        _assertEpochInvestAmountsEq(
            USDC,
            1,
            EpochInvestAmounts(
                depositAmountUsdc,
                approvedUsdc,
                _intoPoolAmount(USDC, approvedUsdc),
                _pricePoolPerAsset(USDC),
                d18(0),
                0 /* Not yet issued */
            )
        );
        _assertEpochInvestAmountsEq(
            OTHER_STABLE,
            1,
            EpochInvestAmounts(
                depositAmountOther,
                approvedOtherStable,
                _intoPoolAmount(OTHER_STABLE, approvedOtherStable),
                _pricePoolPerAsset(OTHER_STABLE),
                d18(0),
                0 /* Not yet issued */
            )
        );
    }

    function testIssueSharesSingleEpoch(
        uint128 navPoolPerShare_,
        uint128 fuzzDepositAmountUsdc,
        uint128 fuzzApprovedAmountUsdc
    ) public {
        D18 navPoolPerShare = d18(uint128(bound(navPoolPerShare_, 1e14, type(uint128).max / 1e18)));
        (uint128 depositAmountUsdc, uint128 approvedAmountUsdc, uint128 approvedAmountPool) =
            _deposit(fuzzDepositAmountUsdc, fuzzApprovedAmountUsdc);

        uint128 shares = _calcSharesIssued(USDC, approvedAmountUsdc, navPoolPerShare);

        assertEq(_totalIssuance(), 0, "Mismatch: totalIssuance");

        (uint128 issuedShareAmount, uint128 depositAssetAmount, uint128 depositPoolAmount) =
            shareClass.issueShares(poolId, scId, USDC, _nowIssue(USDC), navPoolPerShare);
        assertEq(issuedShareAmount, shares, "Mismatch: return issuedShareAmount");
        assertEq(depositAssetAmount, approvedAmountUsdc, "Mismatch: return depositAssetAmount");
        assertEq(depositPoolAmount, approvedAmountPool, "Mismatch: return depositPoolAmount");

        assertEq(_totalIssuance(), shares, "Mismatch: totalIssuance");

        _assertEpochInvestAmountsEq(
            USDC,
            1,
            EpochInvestAmounts(
                depositAmountUsdc,
                approvedAmountUsdc,
                _intoPoolAmount(USDC, approvedAmountUsdc),
                _pricePoolPerAsset(USDC),
                navPoolPerShare,
                block.timestamp.toUint64() /* Not yet issued */
            )
        );
    }

    function testFullClaimDepositSingleEpoch() public {
        vm.expectRevert(IShareClassManager.NoOrderFound.selector);
        shareClass.claimDeposit(poolId, scId, investor, USDC);

        uint128 approvedAmountUsdc = 100 * DENO_USDC;
        uint128 depositAmountUsdc = approvedAmountUsdc;
        uint128 approvedAmountPool = _intoPoolAmount(USDC, approvedAmountUsdc);
        assertEq(approvedAmountPool, 100 * DENO_POOL);

        shareClass.requestDeposit(poolId, scId, depositAmountUsdc, investor, USDC);
        shareClass.approveDeposits(poolId, scId, USDC, _nowDeposit(USDC), approvedAmountUsdc, _pricePoolPerAsset(USDC));

        vm.expectRevert(IShareClassManager.IssuanceRequired.selector);
        shareClass.claimDeposit(poolId, scId, investor, USDC);

        D18 navPoolPerShare = d18(11, 10);
        (uint128 issuedShareAmount,,) = shareClass.issueShares(poolId, scId, USDC, _nowIssue(USDC), navPoolPerShare);

        vm.expectEmit();
        emit IShareClassManager.ClaimDeposit(
            poolId,
            scId,
            1,
            investor,
            USDC,
            approvedAmountUsdc,
            depositAmountUsdc - approvedAmountUsdc,
            issuedShareAmount,
            block.timestamp.toUint64()
        );
        (uint128 payoutShareAmount, uint128 depositAssetAmount, uint128 cancelledAssetAmount, bool canClaimAgain) =
            shareClass.claimDeposit(poolId, scId, investor, USDC);

        assertEq(issuedShareAmount, payoutShareAmount, "Mismatch: payoutShareAmount");
        assertEq(approvedAmountUsdc, depositAssetAmount, "Mismatch: depositAssetAmount");
        assertEq(0, cancelledAssetAmount, "Mismatch: cancelledAssetAmount");
        assertEq(false, canClaimAgain, "Mismatch: canClaimAgain");
        assertEq(_totalIssuance(), issuedShareAmount);

        _assertDepositRequestEq(USDC, investor, UserOrder(depositAmountUsdc - approvedAmountUsdc, 2));
    }

    function testClaimDepositSingleEpoch(
        uint128 navPoolPerShare_,
        uint128 fuzzDepositAmountUsdc,
        uint128 fuzzApprovedAmountUsdc
    ) public {
        vm.expectRevert(IShareClassManager.NoOrderFound.selector);
        shareClass.claimDeposit(poolId, scId, investor, USDC);

        D18 navPoolPerShare = d18(uint128(bound(navPoolPerShare_, 1e14, type(uint128).max / 1e18)));
        (uint128 depositAmountUsdc, uint128 approvedAmountUsdc, uint128 approvedAmountPool) =
            _deposit(fuzzDepositAmountUsdc, fuzzApprovedAmountUsdc);

        vm.expectRevert(IShareClassManager.IssuanceRequired.selector);
        shareClass.claimDeposit(poolId, scId, investor, USDC);

        (uint128 issuedShareAmount,,) = shareClass.issueShares(poolId, scId, USDC, _nowIssue(USDC), navPoolPerShare);

        vm.expectEmit();
        emit IShareClassManager.ClaimDeposit(
            poolId,
            scId,
            1,
            investor,
            USDC,
            approvedAmountUsdc,
            depositAmountUsdc - approvedAmountUsdc,
            issuedShareAmount,
            block.timestamp.toUint64()
        );
        (uint128 payoutShareAmount, uint128 depositAssetAmount, uint128 cancelledAssetAmount, bool canClaimAgain) =
            shareClass.claimDeposit(poolId, scId, investor, USDC);

        assertEq(issuedShareAmount, payoutShareAmount, "Mismatch: payoutShareAmount");
        assertEq(approvedAmountUsdc, depositAssetAmount, "Mismatch: depositAssetAmount");
        assertEq(0, cancelledAssetAmount, "Mismatch: cancelledAssetAmount");
        assertEq(false, canClaimAgain, "Mismatch: canClaimAgain");
        assertEq(_totalIssuance(), issuedShareAmount);

        _assertDepositRequestEq(USDC, investor, UserOrder(depositAmountUsdc - approvedAmountUsdc, 2));
    }

    /*
    function testClaimDepositSkipped() public  {
        uint128 pending = MAX_REQUEST_AMOUNT_USDC;
        uint32 mockLatestIssuance = 10;
        uint32 mockEpochId = mockLatestIssuance + 1;
        shareClass.requestDeposit(poolId, scId, pending, investor, USDC);

        // Mock latestIssuance to 10
        vm.store(
            address(shareClass),
            keccak256(abi.encode(USDC, keccak256(abi.encode(scId, uint256(STORAGE_INDEX_EPOCH_POINTERS))))),
            bytes32(
                (uint256(0)) // latestDepositApproval
                    | (uint256(0) << 32) // latestRedeemApproval
                    | (uint256(mockLatestIssuance) << 64) // latestIssuance
                    | (uint256(0) << 96) // latestRevocation
            )
        );
        // Mock epochId to 11
        vm.store(
            address(shareClass),
            keccak256(abi.encode(poolId, uint256(STORAGE_INDEX_EPOCH_ID))),
            bytes32(uint256(mockEpochId))
        );

    (uint128 payout, uint128 payment, uint128 cancelled) = shareClass.claimDeposit(poolId, scId, investor, USDC);
        assertEq(cancelled, 0, "no queued cancellation");
        assertEq(payout + payment, 0);
        _assertDepositRequestEq(scId, USDC, investor, UserOrder(pending, mockEpochId));
    }

    function testClaimDepositZeroApproved() public {
        shareClass.requestDeposit(poolId, scId, 1, investor, USDC);
        shareClass.requestDeposit(poolId, scId, 10, bytes32("investorOther"), USDC);
        shareClass.approveDeposits(poolId, scId, 1, USDC, oracleMock);
        shareClass.issueShares(poolId, scId, USDC, d18(1));

        vm.expectEmit();
        emit IShareClassManager.ClaimDeposit(poolId, scId, 1, investor, USDC, 0, 1, 0);
        shareClass.claimDeposit(poolId, scId, investor, USDC);
    }

    function testClaimRedeemZeroApproved() public {
    vm.store(address(shareClass), keccak256(abi.encode(scId, uint256(STORAGE_INDEX_METRICS))), bytes32(uint256(11)));

        shareClass.requestRedeem(poolId, scId, 1, investor, USDC);
        shareClass.requestRedeem(poolId, scId, 10, bytes32("investorOther"), USDC);
        shareClass.approveRedeems(poolId, scId, 1, USDC);
        shareClass.revokeShares(poolId, scId, USDC, d18(1), oracleMock);

        vm.expectEmit();
        emit IShareClassManager.ClaimRedeem(poolId, scId, 1, investor, USDC, 0, 1, 0);
        shareClass.claimRedeem(poolId, scId, investor, USDC);
    }

    function testRevokeShareExceedIssuance() public {
        shareClass.requestRedeem(poolId, scId, 1, investor, USDC);
        shareClass.requestRedeem(poolId, scId, 10, bytes32("investorOther"), USDC);
        shareClass.approveRedeems(poolId, scId, 1, USDC);

        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.RevokeMoreThanIssued.selector));
        shareClass.revokeShares(poolId, scId, USDC, d18(1), oracleMock);
    }

    function testQueuedDepositWithoutCancellation(uint128 amount) public  {
        amount = uint128(bound(amount, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC / 3));
        uint32 epochId = 1;
        D18 shareToPoolQuote = d18(1, 1);
        uint128 claimedShares = usdcToPool(amount);
        uint128 queuedAmount = 0;

        // Initial deposit request
        _assertQueuedDepositRequestEq(scId, USDC, investor, QueuedOrder(false, queuedAmount));
        shareClass.requestDeposit(poolId, scId, amount, investor, USDC);
        _assertDepositRequestEq(scId, USDC, investor, UserOrder(amount, epochId));
        assertEq(shareClass.pendingDeposit(scId, USDC), amount);
        shareClass.approveDeposits(poolId, scId, amount, USDC, oracleMock);
        epochId = 2;

        // Expect queued increment due to approval
        queuedAmount += amount;
        vm.expectEmit();
        emit IShareClassManager.UpdateRequest(
            poolId, scId, epochId, RequestType.Deposit, investor, USDC, amount, 0, queuedAmount, false
        );
        shareClass.requestDeposit(poolId, scId, amount, investor, USDC);
        _assertDepositRequestEq(scId, USDC, investor, UserOrder(queuedAmount, epochId - 1));
        assertEq(shareClass.pendingDeposit(scId, USDC), 0);
        _assertQueuedDepositRequestEq(scId, USDC, investor, QueuedOrder(false, queuedAmount));
        _assertQueuedRedeemRequestEq(scId, USDC, investor, QueuedOrder(false, 0));

        // Expect queued increment due to approval
        queuedAmount += amount;
        vm.expectEmit();
        emit IShareClassManager.UpdateRequest(
            poolId, scId, epochId, RequestType.Deposit, investor, USDC, amount, 0, queuedAmount, false
        );
        shareClass.requestDeposit(poolId, scId, amount, investor, USDC);
        _assertQueuedDepositRequestEq(scId, USDC, investor, QueuedOrder(false, queuedAmount));

        // Issue shares + claim -> expect queued to move to pending
        shareClass.issueShares(poolId, scId, USDC, shareToPoolQuote);
        vm.expectEmit();
        emit IShareClassManager.ClaimDeposit(poolId, scId, 1, investor, USDC, amount, 0, claimedShares);
        emit IShareClassManager.UpdateRequest(
            poolId, scId, epochId, RequestType.Deposit, investor, USDC, queuedAmount, queuedAmount, 0, false
        );
        shareClass.claimDeposit(poolId, scId, investor, USDC);

        _assertDepositRequestEq(scId, USDC, investor, UserOrder(queuedAmount, epochId));
        assertEq(shareClass.pendingDeposit(scId, USDC), queuedAmount);
        _assertQueuedDepositRequestEq(scId, USDC, investor, QueuedOrder(false, 0));
        _assertQueuedRedeemRequestEq(scId, USDC, investor, QueuedOrder(false, 0));
    }

    function testQueuedDepositWithNonEmptyQueuedCancellation(uint128 amount)
        public

    {
        vm.assume(amount % 2 == 0);
        amount = uint128(bound(amount, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC));
        D18 shareToPoolQuote = d18(1, 1);
        uint128 approvedAssetAmount = amount / 4;
        uint128 pendingAssetAmount = amount - approvedAssetAmount;
        uint128 issuedShares = usdcToPool(approvedAssetAmount);
        uint128 queuedAmount = 0;
        uint32 epochId = 1;

        // Initial deposit request
        shareClass.requestDeposit(poolId, scId, amount, investor, USDC);
        shareClass.approveDeposits(poolId, scId, approvedAssetAmount, USDC, oracleMock);

        // Expect queued increment due to approval
        epochId = 2;
        queuedAmount += amount;
        shareClass.requestDeposit(poolId, scId, amount, investor, USDC);
        vm.expectEmit();
        emit IShareClassManager.UpdateRequest(
    poolId, scId, epochId, RequestType.Deposit, investor, USDC, amount, pendingAssetAmount, queuedAmount, true
        );
        (uint128 cancelledPending) = shareClass.cancelDepositRequest(poolId, scId, investor, USDC);
        assertEq(cancelledPending, 0, "Cancellation queued");

        // Expect revert due to queued cancellation
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.CancellationQueued.selector));
        shareClass.requestDeposit(poolId, scId, 1, investor, USDC);
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.CancellationQueued.selector));
        shareClass.cancelDepositRequest(poolId, scId, investor, USDC);

        // Issue shares + claim -> expect cancel fulfillment
        shareClass.issueShares(poolId, scId, USDC, shareToPoolQuote);
        vm.expectEmit();
        emit IShareClassManager.ClaimDeposit(
            poolId, scId, 1, investor, USDC, approvedAssetAmount, pendingAssetAmount, issuedShares
        );
        emit IShareClassManager.UpdateRequest(
            poolId, scId, epochId, RequestType.Deposit, investor, USDC, 0, 0, 0, false
        );
        (uint128 claimedShareAmount, uint128 claimedAssetAmount, uint128 cancelledTotal) =
            shareClass.claimDeposit(poolId, scId, investor, USDC);
        assertEq(claimedShareAmount, issuedShares, "Claimed share amount mismatch");
        assertEq(claimedAssetAmount, approvedAssetAmount, "Claimed asset amount mismatch");
        assertEq(cancelledTotal, pendingAssetAmount + queuedAmount, "Cancelled amount mismatch");

        _assertDepositRequestEq(scId, USDC, investor, UserOrder(0, epochId));
        assertEq(shareClass.pendingDeposit(scId, USDC), 0, "Pending deposit mismatch");
        _assertQueuedDepositRequestEq(scId, USDC, investor, QueuedOrder(false, 0));
        _assertQueuedRedeemRequestEq(scId, USDC, investor, QueuedOrder(false, 0));
    }

    function testQueuedDepositWithEmptyQueuedCancellation(uint128 amount) public  {
        vm.assume(amount % 2 == 0);
        amount = uint128(bound(amount, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC));
        D18 shareToPoolQuote = d18(1, 1);
        uint128 approvedAssetAmount = amount / 4;
        uint128 pendingAssetAmount = amount - approvedAssetAmount;
        uint128 issuedShares = usdcToPool(approvedAssetAmount);
        uint32 epochId = 1;

        // Initial deposit request
        shareClass.requestDeposit(poolId, scId, amount, investor, USDC);
        shareClass.approveDeposits(poolId, scId, approvedAssetAmount, USDC, oracleMock);
        epochId = 2;

        // Expect queued increment due to approval
        vm.expectEmit();
        emit IShareClassManager.UpdateRequest(
            poolId, scId, epochId, RequestType.Deposit, investor, USDC, amount, pendingAssetAmount, 0, true
        );
        (uint128 cancelledPending) = shareClass.cancelDepositRequest(poolId, scId, investor, USDC);
        assertEq(cancelledPending, 0, "Cancellation queued");

        // Issue shares + claim -> expect cancel fulfillment
        shareClass.issueShares(poolId, scId, USDC, shareToPoolQuote);
        vm.expectEmit();
        emit IShareClassManager.ClaimDeposit(
            poolId, scId, 1, investor, USDC, approvedAssetAmount, pendingAssetAmount, issuedShares
        );
        emit IShareClassManager.UpdateRequest(
            poolId, scId, epochId, RequestType.Deposit, investor, USDC, 0, 0, 0, false
        );
        (uint128 claimedShareAmount, uint128 claimedAssetAmount, uint128 cancelledTotal) =
            shareClass.claimDeposit(poolId, scId, investor, USDC);
        assertEq(claimedShareAmount, issuedShares, "Claimed share amount mismatch");
        assertEq(claimedAssetAmount, approvedAssetAmount, "Claimed asset amount mismatch");
        assertEq(cancelledTotal, pendingAssetAmount, "Cancelled amount mismatch");

        _assertDepositRequestEq(scId, USDC, investor, UserOrder(0, epochId));
        assertEq(shareClass.pendingDeposit(scId, USDC), 0, "Pending deposit mismatch");
        _assertQueuedDepositRequestEq(scId, USDC, investor, QueuedOrder(false, 0));
        _assertQueuedRedeemRequestEq(scId, USDC, investor, QueuedOrder(false, 0));
    }
    }

    ///@dev Contains all redeem related tests which are expected to succeed and don't make use of transient storage
    contract ShareClassManagerRedeemsNonTransientTest is ShareClassManagerBaseTest {
    using MathLib for uint128;

    function testRequestRedeem(uint128 amount) public  {
        amount = uint128(bound(amount, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC));

        assertEq(shareClass.pendingRedeem(scId, USDC), 0);
        _assertRedeemRequestEq(scId, USDC, investor, UserOrder(0, 0));

        vm.expectEmit(true, true, true, true);
        emit IShareClassManager.UpdateRequest(
            poolId, scId, 1, RequestType.Redeem, investor, USDC, amount, amount, 0, false
        );
        shareClass.requestRedeem(poolId, scId, amount, investor, USDC);

        assertEq(shareClass.pendingRedeem(scId, USDC), amount);
        _assertRedeemRequestEq(scId, USDC, investor, UserOrder(amount, 1));
    }

    function testCancelRedeemRequest(uint128 amount) public  {
        amount = uint128(bound(amount, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC));
        shareClass.requestRedeem(poolId, scId, amount, investor, USDC);

        vm.expectEmit(true, true, true, true);
        emit IShareClassManager.UpdateRequest(poolId, scId, 1, RequestType.Redeem, investor, USDC, 0, 0, 0, false);
        (uint128 cancelledAmount) = shareClass.cancelRedeemRequest(poolId, scId, investor, USDC);

        assertEq(cancelledAmount, amount);
        assertEq(shareClass.pendingRedeem(scId, USDC), 0);
        _assertRedeemRequestEq(scId, USDC, investor, UserOrder(0, 1));
    }

    function testApproveRedeemsSingleAssetManyInvestors(
        uint8 numInvestors,
        uint128 redeemAmount,
        uint128 approvedRedeem
    ) public  {
        redeemAmount = uint128(bound(redeemAmount, MIN_REQUEST_AMOUNT_SHARES, MAX_REQUEST_AMOUNT_SHARES));
        approvedRedeem = uint128(bound(approvedRedeem, MIN_REQUEST_AMOUNT_SHARES, redeemAmount));
        numInvestors = uint8(bound(numInvestors, 1, 100));

        uint128 totalRedeems = 0;
        for (uint16 i = 0; i < numInvestors; i++) {
            bytes32 investor = bytes32(uint256(keccak256(abi.encodePacked("investor_", i))));
            uint128 investorRedeem = redeemAmount + i;
            totalRedeems += investorRedeem;
            shareClass.requestRedeem(poolId, scId, investorRedeem, investor, USDC);

            assertEq(shareClass.pendingRedeem(scId, USDC), totalRedeems);
        }
        assertEq(shareClass.epochId(poolId), 1);

        uint128 pendingRedeems_ = totalRedeems - approvedRedeem;

        vm.expectEmit(true, true, true, true);
        emit IShareClassManager.NewEpoch(poolId, 2);
        vm.expectEmit(true, true, true, true);
        emit IShareClassManager.ApproveRedeems(poolId, scId, 1, USDC, approvedRedeem, pendingRedeems_);
        shareClass.approveRedeems(poolId, scId, approvedRedeem, USDC);

        assertEq(shareClass.pendingRedeem(scId, USDC), pendingRedeems_);

        // Only one epoch should have passed
        assertEq(shareClass.epochId(poolId), 2);

        _assertEpochAmountsEq(scId, USDC, 1, EpochAmounts(0, 0, 0, 0, totalRedeems, approvedRedeem, 0));
    }

    function testApproveRedeemsTwoAssetsSameEpoch(uint128 redeemAmount, uint128 approvedRedeem)
        public

    {
    uint128 redeemAmountUsdc = uint128(bound(redeemAmount, MIN_REQUEST_AMOUNT_SHARES, MAX_REQUEST_AMOUNT_SHARES));
        uint128 redeemAmountOther =
            uint128(bound(redeemAmount, MIN_REQUEST_AMOUNT_SHARES - 1, MAX_REQUEST_AMOUNT_SHARES - 1));
        uint128 approvedRedeemUsdc = uint128(bound(approvedRedeem, MIN_REQUEST_AMOUNT_SHARES, redeemAmountUsdc));
        uint128 approvedRedeemOther = uint128(bound(approvedRedeem, DENO_OTHER_STABLE, redeemAmountOther));
        bytes32 investorUsdc = bytes32("investorUsdc");
        bytes32 investorOther = bytes32("investorOther");
        uint128 pendingUsdc = redeemAmountUsdc - approvedRedeemUsdc;
        uint128 pendingOther = redeemAmountOther - approvedRedeemOther;

        shareClass.requestRedeem(poolId, scId, redeemAmountUsdc, investorUsdc, USDC);
        shareClass.requestRedeem(poolId, scId, redeemAmountOther, investorOther, OTHER_STABLE);

        (uint128 approvedRedeemUsdc_, uint128 pendingUsdc_) =
            shareClass.approveRedeems(poolId, scId, approvedRedeemUsdc, USDC);
        (uint128 approvedRedeemOther_, uint128 pendingOther_) =
            shareClass.approveRedeems(poolId, scId, approvedRedeemOther, OTHER_STABLE);

        assertEq(shareClass.epochId(poolId), 2);
        assertEq(approvedRedeemUsdc_, approvedRedeemUsdc, "approved shares USDC mismatch");
        assertEq(pendingUsdc_, pendingUsdc, "pending shares USDC mismatch");
        assertEq(approvedRedeemOther_, approvedRedeemOther, "approved shares OtherCurrency mismatch");
        assertEq(pendingOther_, pendingOther, "pending shares OtherCurrency mismatch");

        EpochAmounts memory epochAmountsUsdc = EpochAmounts(0, 0, 0, 0, redeemAmountUsdc, approvedRedeemUsdc, 0);
        EpochAmounts memory epochAmountsOther = EpochAmounts(0, 0, 0, 0, redeemAmountOther, approvedRedeemOther, 0);
        _assertEpochAmountsEq(scId, USDC, 1, epochAmountsUsdc);
        _assertEpochAmountsEq(scId, OTHER_STABLE, 1, epochAmountsOther);
    }

    function testRevokeSharesSingleEpoch(uint128 navPerShare, uint128 redeemAmount, uint128 approvedRedeem)
        public

    {
        redeemAmount = uint128(bound(redeemAmount, MIN_REQUEST_AMOUNT_SHARES, MAX_REQUEST_AMOUNT_SHARES));
        approvedRedeem = uint128(bound(approvedRedeem, MIN_REQUEST_AMOUNT_SHARES, redeemAmount));
        D18 shareToPoolQuote = d18(uint128(bound(navPerShare, 1e15, type(uint128).max / 1e18)));
        uint128 poolAmount = shareToPoolQuote.mulUint128(approvedRedeem);
        uint128 assetAmount = poolToUsdc(poolAmount);

        // Mock total issuance to equal redeemAmount
        vm.store(
            address(shareClass),
            keccak256(abi.encode(scId, uint256(STORAGE_INDEX_METRICS))),
            bytes32(uint256(redeemAmount))
        );
        assertEq(totalIssuance(scId), redeemAmount);

        shareClass.requestRedeem(poolId, scId, redeemAmount, investor, USDC);
        shareClass.approveRedeems(poolId, scId, approvedRedeem, USDC);

        assertEq(totalIssuance(scId), redeemAmount);
        _assertEpochPointersEq(scId, USDC, EpochPointers(0, 1, 0, 0));

        (uint128 payoutAssetAmount, uint128 payoutPoolAmount) =
            shareClass.revokeShares(poolId, scId, USDC, shareToPoolQuote, oracleMock);
        assertEq(assetAmount, payoutAssetAmount, "payout asset amount mismatch");
        assertEq(poolAmount, payoutPoolAmount, "payout pool amount mismatch");

        assertEq(totalIssuance(scId), redeemAmount - approvedRedeem);
        _assertEpochPointersEq(scId, USDC, EpochPointers(0, 1, 0, 1));

        _assertEpochAmountsEq(scId, USDC, 1, EpochAmounts(0, 0, 0, 0, redeemAmount, approvedRedeem, assetAmount));
    }

    function testClaimRedeemSingleEpoch(uint128 navPerShare, uint128 redeemAmount, uint128 approvedRedeem)
        public

    {
        redeemAmount = uint128(bound(redeemAmount, MIN_REQUEST_AMOUNT_SHARES, MAX_REQUEST_AMOUNT_SHARES));
        approvedRedeem = uint128(bound(approvedRedeem, MIN_REQUEST_AMOUNT_SHARES, redeemAmount));
        D18 shareToPoolQuote = d18(uint128(bound(navPerShare, 1e15, type(uint128).max / 1e18)));
        uint128 pendingRedeem = redeemAmount - approvedRedeem;
        uint128 payout = poolToUsdc(shareToPoolQuote.mulUint128(approvedRedeem));

        // Mock total issuance to equal redeemAmount
        vm.store(
            address(shareClass),
            keccak256(abi.encode(scId, uint256(STORAGE_INDEX_METRICS))),
            bytes32(uint256(redeemAmount))
        );
        assertEq(totalIssuance(scId), redeemAmount);

        shareClass.requestRedeem(poolId, scId, redeemAmount, investor, USDC);
        shareClass.approveRedeems(poolId, scId, approvedRedeem, USDC);
        shareClass.revokeShares(poolId, scId, USDC, shareToPoolQuote, oracleMock);
        assertEq(totalIssuance(scId), pendingRedeem);
        _assertRedeemRequestEq(scId, USDC, investor, UserOrder(redeemAmount, 1));

        if (payout > 0) {
            vm.expectEmit(true, true, true, true);
    emit IShareClassManager.ClaimRedeem(poolId, scId, 1, investor, USDC, approvedRedeem, pendingRedeem, payout);
        }
        (uint128 payoutAssetAmount, uint128 depositShareAmount, uint128 cancelledAmount) =
            shareClass.claimRedeem(poolId, scId, investor, USDC);

        assertEq(payout, payoutAssetAmount, "payout asset amount mismatch");
        assertEq(payout > 0 ? approvedRedeem : 0, depositShareAmount, "payment shares mismatch");
        _assertRedeemRequestEq(
            scId, USDC, investor, UserOrder(payout > 0 ? pendingRedeem : pendingRedeem + approvedRedeem, 2)
        );
        assertEq(cancelledAmount, 0, "no queued cancellation");

        // Ensure another claim has no impact
    (payoutAssetAmount, depositShareAmount, cancelledAmount) = shareClass.claimRedeem(poolId, scId, investor, USDC);
        assertEq(payoutAssetAmount + depositShareAmount, 0, "replay must not be possible");
        assertEq(cancelledAmount, 0, "no queued cancellation");
    }

    function testClaimRedeemSkipped() public  {
        uint128 pending = MAX_REQUEST_AMOUNT_USDC;
        uint32 mockLatestRevocation = 10;
        uint32 mockEpochId = mockLatestRevocation + 1;
        shareClass.requestRedeem(poolId, scId, pending, investor, USDC);

        // Mock latestRevocation to 10
        vm.store(
            address(shareClass),
            keccak256(abi.encode(USDC, keccak256(abi.encode(scId, uint256(STORAGE_INDEX_EPOCH_POINTERS))))),
            bytes32(
                (uint256(0)) // latestDepositApproval
                    | (uint256(0) << 32) // latestRedeemApproval
                    | (uint256(0) << 64) // latestIssuance
                    | (uint256(mockLatestRevocation) << 96) // latestRevocation
            )
        );
        // Mock epochId to 11
        vm.store(
            address(shareClass),
            keccak256(abi.encode(poolId, uint256(STORAGE_INDEX_EPOCH_ID))),
            bytes32(uint256(mockEpochId))
        );

        (uint128 payout, uint128 payment, uint256 cancelled) = shareClass.claimRedeem(poolId, scId, investor, USDC);
        assertEq(payout + payment + cancelled, 0);
        _assertRedeemRequestEq(scId, USDC, investor, UserOrder(pending, mockEpochId));
    }

    function testQueuedRedeemWithoutCancellation(uint128 amount) public  {
        amount = uint128(bound(amount, MIN_REQUEST_AMOUNT_SHARES, MAX_REQUEST_AMOUNT_SHARES / 3));
        D18 shareToPoolQuote = d18(1, 1);
        uint128 claimedAssetAmount = poolToUsdc(amount);
        uint128 approvedShareAmount = amount;
        uint128 pendingShareAmount = 0;
        uint128 queuedAmount = 0;
        uint32 epochId = 1;

        // Mock total issuance to equal total approved redeem amount
        vm.store(
    address(shareClass), keccak256(abi.encode(scId, uint256(STORAGE_INDEX_METRICS))), bytes32(uint256(amount))
        );

        // Initial deposit request
        _assertQueuedRedeemRequestEq(scId, USDC, investor, QueuedOrder(false, queuedAmount));
        shareClass.requestRedeem(poolId, scId, amount, investor, USDC);
        _assertRedeemRequestEq(scId, USDC, investor, UserOrder(amount, epochId));
        assertEq(shareClass.pendingRedeem(scId, USDC), amount);
        shareClass.approveRedeems(poolId, scId, amount, USDC);
        assertEq(shareClass.pendingRedeem(scId, USDC), 0);
        epochId = 2;

        // Expect queued increment due to approval
        queuedAmount += amount;
        vm.expectEmit();
        emit IShareClassManager.UpdateRequest(
            poolId,
            scId,
            epochId,
            RequestType.Redeem,
            investor,
            USDC,
            approvedShareAmount,
            pendingShareAmount,
            queuedAmount,
            false
        );
        shareClass.requestRedeem(poolId, scId, amount, investor, USDC);
        _assertRedeemRequestEq(scId, USDC, investor, UserOrder(queuedAmount, epochId - 1));
        assertEq(shareClass.pendingRedeem(scId, USDC), 0);
        _assertQueuedRedeemRequestEq(scId, USDC, investor, QueuedOrder(false, queuedAmount));
        _assertQueuedDepositRequestEq(scId, USDC, investor, QueuedOrder(false, 0));

        // Expect queued increment due to approval
        queuedAmount += amount;
        vm.expectEmit();
        emit IShareClassManager.UpdateRequest(
            poolId, scId, epochId, RequestType.Redeem, investor, USDC, amount, 0, queuedAmount, false
        );
        shareClass.requestRedeem(poolId, scId, amount, investor, USDC);
        _assertQueuedRedeemRequestEq(scId, USDC, investor, QueuedOrder(false, queuedAmount));

        // Issue shares + claim -> expect queued to move to pending
        shareClass.revokeShares(poolId, scId, USDC, shareToPoolQuote, oracleMock);
        pendingShareAmount = queuedAmount;
        vm.expectEmit();
        emit IShareClassManager.ClaimRedeem(poolId, scId, 1, investor, USDC, amount, 0, claimedAssetAmount);
        emit IShareClassManager.UpdateRequest(
    poolId, scId, epochId, RequestType.Redeem, investor, USDC, pendingShareAmount, pendingShareAmount, 0, false
        );
        shareClass.claimRedeem(poolId, scId, investor, USDC);

        _assertRedeemRequestEq(scId, USDC, investor, UserOrder(pendingShareAmount, epochId));
        assertEq(shareClass.pendingRedeem(scId, USDC), pendingShareAmount, "pending redeem mismatch");
        _assertQueuedRedeemRequestEq(scId, USDC, investor, QueuedOrder(false, 0));
        _assertQueuedDepositRequestEq(scId, USDC, investor, QueuedOrder(false, 0));
    }

    function testQueuedRedeemWithNonEmptyQueuedCancellation(uint128 amount)
        public

    {
        vm.assume(amount % 2 == 0);
        amount = uint128(bound(amount, MIN_REQUEST_AMOUNT_SHARES, MAX_REQUEST_AMOUNT_SHARES / 2));
        D18 shareToPoolQuote = d18(1, 1);
        uint128 approvedShareAmount = amount / 4;
        uint128 pendingShareAmount = amount - approvedShareAmount;
        uint128 revokedAssetAmount = poolToUsdc(approvedShareAmount);
        uint128 queuedAmount = 0;
        uint32 epochId = 1;

        // Mock total issuance to equal total approved redeem amount
        vm.store(
            address(shareClass),
            keccak256(abi.encode(scId, uint256(STORAGE_INDEX_METRICS))),
            bytes32(uint256(approvedShareAmount))
        );

        // Initial deposit request
        shareClass.requestRedeem(poolId, scId, amount, investor, USDC);
        shareClass.approveRedeems(poolId, scId, approvedShareAmount, USDC);
        epochId = 2;

        // Expect queued increment due to approval
        queuedAmount += amount;
        shareClass.requestRedeem(poolId, scId, amount, investor, USDC);
        vm.expectEmit();
        emit IShareClassManager.UpdateRequest(
    poolId, scId, epochId, RequestType.Redeem, investor, USDC, amount, pendingShareAmount, queuedAmount, true
        );
        (uint128 cancelledPending) = shareClass.cancelRedeemRequest(poolId, scId, investor, USDC);
        assertEq(cancelledPending, 0, "Cancellation queued");

        // Expect revert due to queued cancellation
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.CancellationQueued.selector));
        shareClass.requestRedeem(poolId, scId, 1, investor, USDC);
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.CancellationQueued.selector));
        shareClass.cancelRedeemRequest(poolId, scId, investor, USDC);

        // Issue shares + claim -> expect cancel fulfillment
        shareClass.revokeShares(poolId, scId, USDC, shareToPoolQuote, oracleMock);
        vm.expectEmit();
        emit IShareClassManager.ClaimRedeem(
            poolId, scId, 1, investor, USDC, approvedShareAmount, pendingShareAmount, revokedAssetAmount
        );
    emit IShareClassManager.UpdateRequest(poolId, scId, epochId, RequestType.Redeem, investor, USDC, 0, 0, 0, false);
        (uint128 claimedAssetAmount, uint128 claimedShareAmount, uint128 cancelledTotal) =
            shareClass.claimRedeem(poolId, scId, investor, USDC);
        assertEq(claimedAssetAmount, revokedAssetAmount, "Claimed asset amount mismatch");
        assertEq(claimedShareAmount, approvedShareAmount, "Claimed share amount mismatch");
        assertEq(cancelledTotal, pendingShareAmount + queuedAmount, "Cancelled amount mismatch");

        _assertRedeemRequestEq(scId, USDC, investor, UserOrder(0, epochId));
        assertEq(shareClass.pendingRedeem(scId, USDC), 0, "Pending deposit mismatch");
        _assertQueuedRedeemRequestEq(scId, USDC, investor, QueuedOrder(false, 0));
        _assertQueuedRedeemRequestEq(scId, USDC, investor, QueuedOrder(false, 0));
    }

    function testQueuedRedeemWithEmptyQueuedCancellation(uint128 amount) public  {
        vm.assume(amount % 2 == 0);
        amount = uint128(bound(amount, MIN_REQUEST_AMOUNT_SHARES, MAX_REQUEST_AMOUNT_SHARES / 2));
        D18 shareToPoolQuote = d18(1, 1);
        uint128 approvedShareAmount = amount / 4;
        uint128 pendingShareAmount = amount - approvedShareAmount;
        uint128 revokedAssetAmount = poolToUsdc(approvedShareAmount);
        uint32 epochId = 1;

        // Mock total issuance to equal total approved redeem amount
        vm.store(
            address(shareClass),
            keccak256(abi.encode(scId, uint256(STORAGE_INDEX_METRICS))),
            bytes32(uint256(approvedShareAmount))
        );

        // Initial redeem request
        shareClass.requestRedeem(poolId, scId, amount, investor, USDC);
        shareClass.approveRedeems(poolId, scId, approvedShareAmount, USDC);
        epochId = 2;

        // Expect queued increment due to approval
        vm.expectEmit();
        emit IShareClassManager.UpdateRequest(
            poolId, scId, epochId, RequestType.Redeem, investor, USDC, amount, pendingShareAmount, 0, true
        );
        (uint128 cancelledPending) = shareClass.cancelRedeemRequest(poolId, scId, investor, USDC);
        assertEq(cancelledPending, 0, "Cancellation queued");

        // Issue shares + claim -> expect cancel fulfillment
        shareClass.revokeShares(poolId, scId, USDC, shareToPoolQuote, oracleMock);
        vm.expectEmit();
        emit IShareClassManager.ClaimRedeem(
            poolId, scId, 1, investor, USDC, approvedShareAmount, pendingShareAmount, revokedAssetAmount
        );
    emit IShareClassManager.UpdateRequest(poolId, scId, epochId, RequestType.Redeem, investor, USDC, 0, 0, 0, false);
        (uint128 claimedAssetAmount, uint128 claimedShareAmount, uint128 cancelledTotal) =
            shareClass.claimRedeem(poolId, scId, investor, USDC);
        assertEq(claimedAssetAmount, revokedAssetAmount, "Claimed share amount mismatch");
        assertEq(claimedShareAmount, approvedShareAmount, "Claimed asset amount mismatch");
        assertEq(cancelledTotal, pendingShareAmount, "Cancelled amount mismatch");

        _assertRedeemRequestEq(scId, USDC, investor, UserOrder(0, epochId));
        assertEq(shareClass.pendingRedeem(scId, USDC), 0, "Pending redeem mismatch");
        _assertQueuedRedeemRequestEq(scId, USDC, investor, QueuedOrder(false, 0));
        _assertQueuedRedeemRequestEq(scId, USDC, investor, QueuedOrder(false, 0));
    }
    */
}
/*
///@dev Contains all tests which require transient storage to reset between calls
contract ShareClassManagerTransientTest is ShareClassManagerBaseTest {
    using MathLib for uint128;

    function testIssueSharesManyEpochs(
        uint8 maxEpochId,
        uint128 navPerShare_,
        uint128 depositAmount,
        uint128 approvedUSDC
    ) public  {
        depositAmount = uint128(bound(depositAmount, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC / 100));
        D18 shareToPoolQuote = d18(uint128(bound(navPerShare_, 1e15, type(uint128).max / 1e18)));
        maxEpochId = uint8(bound(maxEpochId, 3, 50));
        approvedUSDC = uint128(bound(approvedUSDC, MIN_REQUEST_AMOUNT_USDC, depositAmount));
        uint128 shares = 0;
        uint128 pendingUSDC = depositAmount;
        uint128 approvedPool = usdcToPool(approvedUSDC);

        // Bump up latestApproval epochs
        for (uint8 i = 1; i < maxEpochId; i++) {
            bytes32 investor = bytes32(uint256(keccak256(abi.encodePacked("investor_", i))));
            _resetTransientEpochIncrement();
            shareClass.requestDeposit(poolId, scId, depositAmount, investor, USDC);
            shareClass.approveDeposits(poolId, scId, approvedUSDC, USDC, oracleMock);

            pendingUSDC += depositAmount - approvedUSDC;
        }
        assertEq(totalIssuance(scId), 0);

        // Assert issued events
        uint128 totalIssuance_;

        pendingUSDC = depositAmount;
        for (uint8 i = 1; i < maxEpochId; i++) {
            pendingUSDC += depositAmount - approvedUSDC;
            uint128 epochShares = shareToPoolQuote.reciprocalMulUint128(approvedPool);
            totalIssuance_ += epochShares;
            uint128 nav = shareToPoolQuote.mulUint128(totalIssuance_);

            vm.expectEmit(true, true, true, true);
            emit IShareClassManager.IssueShares(poolId, scId, i, nav, shareToPoolQuote, totalIssuance_, epochShares);
        }

        shareClass.issueShares(poolId, scId, USDC, shareToPoolQuote);
        _assertEpochPointersEq(scId, USDC, EpochPointers(maxEpochId - 1, 0, maxEpochId - 1, 0));

        // Ensure each epoch is issued separately
        pendingUSDC = depositAmount;
        for (uint8 i = 1; i < maxEpochId; i++) {
            uint128 epochShares = shareToPoolQuote.reciprocalMulUint128(approvedPool);
            shares += epochShares;

            _assertEpochAmountsEq(
                scId, USDC, i, EpochAmounts(pendingUSDC, approvedUSDC, approvedPool, epochShares, 0, 0, 0)
            );
            pendingUSDC += depositAmount - approvedUSDC;
        }
        assertEq(totalIssuance(scId), shares, "totalIssuance mismatch");
        (uint128 issuance, D18 navPerShare) = shareClass.metrics(scId);
        // @dev navPerShare should be 0 since we are using updateShareClass(..) to set it
        assertEq(navPerShare.inner(), 0);
        assertEq(issuance, shares, "totalIssuance mismatch");

        // Ensure another issuance reverts
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ApprovalRequired.selector));
        shareClass.issueShares(poolId, scId, USDC, shareToPoolQuote);
    }

    function testClaimDepositManyEpochs(
        uint8 maxEpochId,
        uint128 navPerShare,
        uint128 depositAmount,
        uint128 maxApproval
    ) public  {
        D18 shareToPoolQuote = d18(uint128(bound(navPerShare, 1e10, type(uint128).max / 1e18)));
        maxEpochId = uint8(bound(maxEpochId, 3, 50));
        depositAmount =
            maxEpochId * uint128(bound(depositAmount, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC / 100));
        maxApproval = uint128(bound(maxApproval, MIN_REQUEST_AMOUNT_USDC, depositAmount));
        uint128 pending = depositAmount;
        uint128 epochApprovedUSDC = maxApproval / maxEpochId;
        uint128 epochApprovedPool = usdcToPool(epochApprovedUSDC);
        uint128 totalApprovedUSDC = 0;
        uint128 shares = 0;

        shareClass.requestDeposit(poolId, scId, depositAmount, investor, USDC);

        // Approve many epochs and issue shares
        for (uint8 i = 1; i < maxEpochId; i++) {
            shareClass.approveDeposits(poolId, scId, epochApprovedUSDC, USDC, oracleMock);
            totalApprovedUSDC += epochApprovedUSDC;
            shares += shareToPoolQuote.reciprocalMulUint128(epochApprovedPool);
            pending = depositAmount - epochApprovedUSDC;
            _resetTransientEpochIncrement();
        }
        shareClass.issueShares(poolId, scId, USDC, shareToPoolQuote);
        assertEq(totalIssuance(scId), shares, "totalIssuance mismatch");

        // Ensure each epoch is claimed separately
        pending = depositAmount;
        for (uint8 i = 1; i < maxEpochId; i++) {
            uint128 epochShares = shareToPoolQuote.reciprocalMulUint128(epochApprovedPool);

            if (epochShares > 0) {
                pending -= epochApprovedUSDC;
            }
            vm.expectEmit(true, true, true, true);
            emit IShareClassManager.ClaimDeposit(
                poolId, scId, i, investor, USDC, epochApprovedUSDC, pending, epochShares
            );
        }

        (uint128 userShares, uint128 payment,) = shareClass.claimDeposit(poolId, scId, investor, USDC);
        assertEq(totalApprovedUSDC + pending, depositAmount, "approved + pending must equal request amount");
        assertEq(shares, userShares, "shares mismatch");
        assertEq(totalApprovedUSDC, payment, "payment mismatch");

        UserOrder memory userOrder = UserOrder(pending, maxEpochId);
        _assertDepositRequestEq(scId, USDC, investor, userOrder);
    }

    function testRevokeSharesManyEpochs(
        uint8 maxEpochId,
        uint128 navPerShare_,
        uint128 redeemAmount,
        uint128 approvedRedeem
    ) public  {
        redeemAmount = uint128(bound(redeemAmount, MIN_REQUEST_AMOUNT_SHARES, MAX_REQUEST_AMOUNT_SHARES));
        approvedRedeem = uint128(bound(approvedRedeem, MIN_REQUEST_AMOUNT_SHARES, redeemAmount));
        D18 shareToPoolQuote = d18(uint128(bound(navPerShare_, 1e15, type(uint128).max / 1e18)));
        maxEpochId = uint8(bound(maxEpochId, 3, 50));
        uint128 totalIssuance_ = maxEpochId * redeemAmount;
        uint128 redeemedShares = 0;
        uint128 pendingRedeems = redeemAmount;

        // Mock total issuance to equal total redeemAmount
        vm.store(
            address(shareClass),
            keccak256(abi.encode(scId, uint256(STORAGE_INDEX_METRICS))),
            bytes32(uint256(totalIssuance_))
        );

        // Bump up latestApproval epochs
        for (uint8 i = 1; i < maxEpochId; i++) {
            bytes32 investor = bytes32(uint256(keccak256(abi.encodePacked("investor_", i))));
            _resetTransientEpochIncrement();
            shareClass.requestRedeem(poolId, scId, redeemAmount, investor, USDC);
            shareClass.approveRedeems(poolId, scId, approvedRedeem, USDC);
        }
        assertEq(totalIssuance(scId), totalIssuance_);

        // Assert revoked events
        for (uint8 i = 1; i < maxEpochId; i++) {
            totalIssuance_ -= approvedRedeem;
            uint128 nav = shareToPoolQuote.mulUint128(totalIssuance_);
            pendingRedeems += redeemAmount - approvedRedeem;
            uint128 revokedAssetAmount = poolToUsdc(shareToPoolQuote.mulUint128(approvedRedeem));

            vm.expectEmit(true, true, true, true);
            emit IShareClassManager.RevokeShares(
                poolId, scId, i, nav, shareToPoolQuote, totalIssuance_, approvedRedeem, revokedAssetAmount
            );
        }

        shareClass.revokeShares(poolId, scId, USDC, shareToPoolQuote, oracleMock);
        _assertEpochPointersEq(scId, USDC, EpochPointers(0, maxEpochId - 1, 0, maxEpochId - 1));

        // Ensure each epoch was revoked separately
        pendingRedeems = redeemAmount;
        for (uint8 i = 1; i < maxEpochId; i++) {
            redeemedShares += approvedRedeem;
            uint128 revokedAssetAmount = poolToUsdc(shareToPoolQuote.mulUint128(approvedRedeem));

            _assertEpochAmountsEq(
                scId, USDC, i, EpochAmounts(0, 0, 0, 0, pendingRedeems, approvedRedeem, revokedAssetAmount)
            );
            pendingRedeems += redeemAmount - approvedRedeem;
        }
        assertEq(totalIssuance(scId), totalIssuance_);
        (uint128 issuance, D18 navPerShare) = shareClass.metrics(scId);
        // @dev navPerShare should be 0 since we are using updateShareClass(..) to set it
        assertEq(navPerShare.inner(), 0);
        assertEq(issuance, totalIssuance_);

        // Ensure another issuance reverts
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ApprovalRequired.selector));
        shareClass.revokeShares(poolId, scId, USDC, shareToPoolQuote, oracleMock);
    }

    function testClaimRedeemManyEpochs(
        uint8 maxEpochId,
        uint128 navPerShare,
        uint128 redeemAmount,
        uint128 epochApproved
    ) public  {
        maxEpochId = uint8(bound(maxEpochId, 3, 50));
        D18 shareToPoolQuote = d18(uint128(bound(navPerShare, 1e15, type(uint128).max / 1e18)));
        redeemAmount = maxEpochId * uint128(bound(redeemAmount, MIN_REQUEST_AMOUNT_SHARES, MAX_REQUEST_AMOUNT_SHARES));
        epochApproved = uint128(bound(epochApproved, MIN_REQUEST_AMOUNT_SHARES, redeemAmount / maxEpochId));
        uint128 pendingRedeem = redeemAmount;
        uint128 totalApproved = 0;
        uint128 payout = 0;

        // Mock total issuance to equal total redeemAmount
        vm.store(
            address(shareClass),
            keccak256(abi.encode(scId, uint256(STORAGE_INDEX_METRICS))),
            bytes32(uint256(redeemAmount))
        );

        shareClass.requestRedeem(poolId, scId, redeemAmount, investor, USDC);

        // Approve many epochs and revoke shares
        for (uint8 i = 1; i < maxEpochId; i++) {
            shareClass.approveRedeems(poolId, scId, epochApproved, USDC);
            totalApproved += epochApproved;
            pendingRedeem -= epochApproved;
            _resetTransientEpochIncrement();
        }
        shareClass.revokeShares(poolId, scId, USDC, shareToPoolQuote, oracleMock);
        assertEq(totalIssuance(scId), pendingRedeem, "totalIssuance mismatch");

        // Ensure each epoch is claimed separately
        pendingRedeem = redeemAmount;
        for (uint8 i = 1; i < maxEpochId; i++) {
            uint128 epochPayout = poolToUsdc(shareToPoolQuote.mulUint128(epochApproved));

            if (epochPayout > 0) {
                payout += epochPayout;
                pendingRedeem -= epochApproved;
            }
            vm.expectEmit(true, true, true, true);
            emit IShareClassManager.ClaimRedeem(
                poolId, scId, i, investor, USDC, epochApproved, pendingRedeem, epochPayout
            );
        }
        (uint128 payoutAssetAmount, uint128 depositShareAmount,) = shareClass.claimRedeem(poolId, scId, investor, USDC);

        assertEq(totalApproved + pendingRedeem, redeemAmount, "approved + pending must equal request amount");
        assertEq(payout, payoutAssetAmount, "payout asset amount mismatch");
        assertEq(totalApproved, depositShareAmount, "payment shares mismatch");

        UserOrder memory userOrder = UserOrder(pendingRedeem, maxEpochId);
        _assertRedeemRequestEq(scId, USDC, investor, userOrder);
    }

    function testDepositsWithRedeemsFullFlow(
        uint128 navPerShare_,
        uint128 depositRequest,
        uint128 redeemRequest,
        uint128 depositApproval,
        uint128 redeemApproval
    ) public  {
        D18 navPerShareDeposit = d18(uint128(bound(navPerShare_, 1e10, type(uint128).max / 1e18)));
        D18 navPerShareRedeem = d18(uint128(bound(navPerShare_, 1e10, navPerShareDeposit.inner())));
        uint128 shares = navPerShareDeposit.reciprocalMulUint128(usdcToPool(MAX_REQUEST_AMOUNT_USDC));
        depositRequest = uint128(bound(depositRequest, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC));
        redeemRequest = uint128(bound(redeemRequest, MIN_REQUEST_AMOUNT_SHARES, shares));
        depositApproval = uint128(bound(depositRequest, MIN_REQUEST_AMOUNT_USDC, depositRequest));
        redeemApproval = uint128(bound(redeemRequest, MIN_REQUEST_AMOUNT_SHARES, redeemRequest));
        EpochAmounts memory epochAmounts = EpochAmounts(0, 0, 0, 0, 0, 0, 0);

        // Step 1: Do initial deposit flow with 100% deposit approval rate to add sufficient shares for later redemption
        uint32 epochId = 2;
        shareClass.requestDeposit(poolId, scId, MAX_REQUEST_AMOUNT_USDC, investor, USDC);
        shareClass.approveDeposits(poolId, scId, MAX_REQUEST_AMOUNT_USDC, USDC, oracleMock);
        shareClass.issueShares(poolId, scId, USDC, navPerShareDeposit);
        shareClass.claimDeposit(poolId, scId, investor, USDC);

        assertEq(totalIssuance(scId), shares);
        assertEq(shareClass.epochId(poolId), 2);
        _assertDepositRequestEq(scId, USDC, investor, UserOrder(0, 2));
        _assertEpochAmountsEq(
            scId,
            USDC,
            1,
            EpochAmounts(
                MAX_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC, usdcToPool(MAX_REQUEST_AMOUNT_USDC), shares, 0, 0, 0
            )
        );

        // Step 2a: Deposit + redeem at same
        _resetTransientEpochIncrement();
        shareClass.requestDeposit(poolId, scId, depositRequest, investor, USDC);
        shareClass.requestRedeem(poolId, scId, redeemRequest, investor, USDC);
        _assertDepositRequestEq(scId, USDC, investor, UserOrder(depositRequest, epochId));
        _assertRedeemRequestEq(scId, USDC, investor, UserOrder(redeemRequest, epochId));

        // Step 2b: Approve deposits
        epochAmounts.depositPending = depositRequest;
        epochAmounts.depositApproved = depositApproval;
        shareClass.approveDeposits(poolId, scId, depositApproval, USDC, oracleMock);
        epochAmounts.depositPool = usdcToPool(depositApproval);
        _assertEpochAmountsEq(scId, USDC, epochId, epochAmounts);

        // Step 2c: Approve redeems
        epochAmounts.redeemPending = redeemRequest;
        epochAmounts.redeemApproved = redeemApproval;
        shareClass.approveRedeems(poolId, scId, redeemApproval, USDC);
        _assertDepositRequestEq(scId, USDC, investor, UserOrder(depositRequest, epochId));
        _assertRedeemRequestEq(scId, USDC, investor, UserOrder(redeemRequest, epochId));
        _assertEpochAmountsEq(scId, USDC, epochId, epochAmounts);

        // Step 2d: Issue shares
        shareClass.issueShares(poolId, scId, USDC, navPerShareDeposit);
        epochAmounts.depositShares = navPerShareDeposit.reciprocalMulUint128(usdcToPool(depositRequest));
        shares += epochAmounts.depositShares;
        assertEq(totalIssuance(scId), shares);
        _assertEpochAmountsEq(scId, USDC, epochId, epochAmounts);

        // Step 2e: Revoke shares
        shareClass.revokeShares(poolId, scId, USDC, navPerShareRedeem, oracleMock);
        shares -= epochAmounts.redeemApproved;
        (uint128 issuance, D18 navPerShare) = shareClass.metrics(scId);
        assertEq(issuance, shares);
        // @dev navPerShare should be 0 since we are using updateShareClass(..) to set it
        assertEq(navPerShare.inner(), 0);
        epochAmounts.redeemAssets = poolToUsdc(navPerShareRedeem.mulUint128(redeemApproval));
        _assertEpochAmountsEq(scId, USDC, epochId, epochAmounts);

        // Step 2f: Claim deposit and redeem
        epochId += 1;
        (, uint128 claimDepositAssetPaymentAmount,) = shareClass.claimDeposit(poolId, scId, investor, USDC);
        (, uint128 claimRedeemSharePaymentAmount,) = shareClass.claimRedeem(poolId, scId, investor, USDC);
uint128 pendingDeposit = claimDepositAssetPaymentAmount == 0 ? 0 : depositRequest - epochAmounts.depositApproved;
        _assertDepositRequestEq(scId, USDC, investor, UserOrder(pendingDeposit, epochId));
        uint128 pendingRedeem =
            claimRedeemSharePaymentAmount == 0 ? redeemRequest : redeemRequest - epochAmounts.redeemApproved;
        _assertRedeemRequestEq(scId, USDC, investor, UserOrder(pendingRedeem, epochId));
        _assertEpochAmountsEq(scId, USDC, 2, epochAmounts);
        _assertEpochAmountsEq(scId, USDC, epochId, EpochAmounts(0, 0, 0, 0, 0, 0, 0));
    }
}

///@dev Contains all deposit tests which deal with rounding edge cases
contract ShareClassManagerRoundingEdgeCasesDeposit is ShareClassManagerBaseTest {
    using MathLib for uint128;

    bytes32 constant INVESTOR_A = bytes32("investorA");
    bytes32 constant INVESTOR_B = bytes32("investorB");
    bytes32 constant INVESTOR_C = bytes32("investorC");

    function _approveAllDepositsAndIssue(uint128 expectedShareIssuance, D18 navPerShare) private {
        shareClass.approveDeposits(poolId, scId, MAX_REQUEST_AMOUNT_USDC, USDC, oracleMock);
        shareClass.issueShares(poolId, scId, USDC, navPerShare);
        assertEq(totalIssuance(scId), expectedShareIssuance, "Mismatch in expected shares");
    }

    /// @dev Investors cannot claim the single issued share atom (one of smallest denomination of share)
    function testClaimDepositSingleShareAtom() public  {
        uint128 approvedAssetAmount = DENO_USDC;
        uint128 issuedShares = 1;
        D18 navPerShare = d18(usdcToPool(approvedAssetAmount), issuedShares);

        shareClass.requestDeposit(poolId, scId, 1, INVESTOR_A, USDC);
        shareClass.requestDeposit(poolId, scId, approvedAssetAmount - 1, INVESTOR_B, USDC);
        _approveAllDepositsAndIssue(issuedShares, navPerShare);

        (uint128 claimedA, uint128 paymentA, uint128 cancelledA) =
            shareClass.claimDeposit(poolId, scId, INVESTOR_A, USDC);
        (uint128 claimedB, uint128 paymentB, uint128 cancelledB) =
            shareClass.claimDeposit(poolId, scId, INVESTOR_B, USDC);

        assertEq(claimedA, claimedB, "Claimed shares should be equal");
        assertEq(claimedA + claimedB + 1, issuedShares, "System should have 1 share class token atom surplus");
        assertEq(paymentA + paymentB, 0, "Payment should be zero since neither investor could claim single share atom");
        assertEq(cancelledA + cancelledB, 0, "No queued cancellation");
        assertEq(shareClass.pendingDeposit(scId, USDC), 0, "Pending deposit should be zero");

        _assertDepositRequestEq(scId, USDC, INVESTOR_A, UserOrder(1, 2));
        _assertDepositRequestEq(scId, USDC, INVESTOR_B, UserOrder(approvedAssetAmount - 1, 2));
    }

    /// @dev Investors can claim 50% rounded down of an uneven number of shares => 1 share atom surplus in system
    function testClaimDepositEvenInvestorsUnevenClaimable() public  {
        uint128 approvedAssetAmount = 100 * DENO_USDC;
        uint128 issuedShares = 11;
        D18 navPerShare = d18(usdcToPool(approvedAssetAmount), issuedShares);

        shareClass.requestDeposit(poolId, scId, 49 * approvedAssetAmount / 100, INVESTOR_A, USDC);
        shareClass.requestDeposit(poolId, scId, 51 * approvedAssetAmount / 100, INVESTOR_B, USDC);
        _approveAllDepositsAndIssue(issuedShares, navPerShare);

        (uint128 claimedA, uint128 paymentA, uint128 cancelledA) =
            shareClass.claimDeposit(poolId, scId, INVESTOR_A, USDC);
        (uint128 claimedB, uint128 paymentB, uint128 cancelledB) =
            shareClass.claimDeposit(poolId, scId, INVESTOR_B, USDC);

        assertEq(claimedA, claimedB, "Claimed shares should be equal");
        assertEq(claimedA + claimedB + 1, issuedShares, "System should have 1 share class token atom surplus");
        assert(paymentA != paymentB);
        assertEq(cancelledA + cancelledB, 0, "No queued cancellation");
    }

    /// @dev Investors can claim 1/3 of an even number of shares => 1 share atom surplus in system
    function testClaimDepositUnevenInvestorsEvenClaimable() public  {
        uint128 approvedAssetAmount = 100 * DENO_USDC;
        uint128 issuedShares = 10;
        D18 navPerShare = d18(usdcToPool(approvedAssetAmount), issuedShares);

        shareClass.requestDeposit(poolId, scId, 30 * approvedAssetAmount / 100, INVESTOR_A, USDC);
        shareClass.requestDeposit(poolId, scId, 31 * approvedAssetAmount / 100, INVESTOR_B, USDC);
        shareClass.requestDeposit(poolId, scId, 39 * approvedAssetAmount / 100, INVESTOR_C, USDC);
        _approveAllDepositsAndIssue(issuedShares, navPerShare);

        (uint128 claimedA, uint128 paymentA, uint128 cancelledA) =
            shareClass.claimDeposit(poolId, scId, INVESTOR_A, USDC);
        (uint128 claimedB, uint128 paymentB, uint128 cancelledB) =
            shareClass.claimDeposit(poolId, scId, INVESTOR_B, USDC);
        (uint128 claimedC, uint128 paymentC, uint128 cancelledC) =
            shareClass.claimDeposit(poolId, scId, INVESTOR_C, USDC);

        assertEq(claimedA, claimedB, "Claimed shares should be equal");
        assertEq(claimedB, claimedC, "Claimed shares should be equal");
        assertEq(
            claimedA + claimedB + claimedC + 1, issuedShares, "System should have 1 share class token atom surplus"
        );
        assert(paymentA != paymentB && paymentB != paymentC && paymentC != paymentA);
        assertEq(cancelledA + cancelledB + cancelledC, 0, "No queued cancellation");
    }
}

///@dev Contains all deposit tests which deal with rounding edge cases
contract ShareClassManagerRoundingEdgeCasesRedeem is ShareClassManagerBaseTest {
    using MathLib for uint128;
    using MathLib for uint256;

    bytes32 constant INVESTOR_A = bytes32("investorA");
    bytes32 constant INVESTOR_B = bytes32("investorB");
    bytes32 constant INVESTOR_C = bytes32("investorC");
    uint128 TOTAL_ISSUANCE = 1000 * DENO_POOL;

    function setUp() public override {
        ShareClassManagerBaseTest.setUp();

        // Mock total issuance such that we can redeem
        vm.store(
            address(shareClass),
            keccak256(abi.encode(scId, uint256(STORAGE_INDEX_METRICS))),
            bytes32(uint256(TOTAL_ISSUANCE))
        );
    }

    function _approveAllRedeemsAndRevoke(uint128 approvedShareAmount, uint128 expectedAssetPayout, D18 navPerShare)
        private
    {
        shareClass.approveRedeems(poolId, scId, approvedShareAmount, USDC);
        (uint128 assetPayout,) = shareClass.revokeShares(poolId, scId, USDC, navPerShare, oracleMock);
        assertEq(totalIssuance(scId), TOTAL_ISSUANCE - approvedShareAmount, "Mismatch in expected shares");
        assertEq(shareClass.pendingRedeem(scId, USDC), 0, "Pending redeem should have decreased");
        assertEq(assetPayout, expectedAssetPayout, "Mismatch in expected asset payout");
    }

    /// @dev Investors cannot claim anything despite non-zero pending amounts
    function testClaimRedeemSingleAssetAtom() public  {
        uint128 approvedShareAmount = DENO_POOL / DENO_USDC;
        uint128 assetPayout = 1;
        uint128 poolPayout = usdcToPool(assetPayout);
        D18 navPerShare = d18(poolPayout, approvedShareAmount); // = 1e18

        shareClass.requestRedeem(poolId, scId, 1, INVESTOR_A, USDC);
        shareClass.requestRedeem(poolId, scId, approvedShareAmount - 1, INVESTOR_B, USDC);
        _approveAllRedeemsAndRevoke(approvedShareAmount, assetPayout, navPerShare);

        (uint128 claimedA, uint128 paymentA,) = shareClass.claimRedeem(poolId, scId, INVESTOR_A, USDC);
        (uint128 claimedB, uint128 paymentB,) = shareClass.claimRedeem(poolId, scId, INVESTOR_B, USDC);

        assertEq(claimedA, claimedB, "Both investors should have claimed same amount");
        assertEq(claimedA + claimedB, 0, "Claimed amount should be zero for both investors");
        assertEq(paymentA + paymentB, 0, "Payment should be zero since neither investor could claim anything");
        assertEq(shareClass.pendingRedeem(scId, USDC), 0, "Pending redeem should be zero");

        _assertRedeemRequestEq(scId, USDC, INVESTOR_A, UserOrder(1, 2));
        _assertRedeemRequestEq(scId, USDC, INVESTOR_B, UserOrder(approvedShareAmount - 1, 2));
    }

    /// @dev Investors can claim 50% rounded down of an uneven number of asset amount => 1 asset amount surplus in
    /// system
    function testClaimRedeemEvenInvestorsUnevenClaimable() public  {
        uint128 approvedShareAmount = DENO_POOL / DENO_USDC;
        uint128 assetPayout = 11;
        uint128 poolPayout = usdcToPool(assetPayout);
        D18 navPerShare = d18(poolPayout, approvedShareAmount);

        shareClass.requestRedeem(poolId, scId, 49 * approvedShareAmount / 100, INVESTOR_A, USDC);
        shareClass.requestRedeem(poolId, scId, 51 * approvedShareAmount / 100, INVESTOR_B, USDC);
        _approveAllRedeemsAndRevoke(approvedShareAmount, assetPayout, navPerShare);

        (uint128 claimedA, uint128 paymentA, uint128 cancelledA) =
            shareClass.claimRedeem(poolId, scId, INVESTOR_A, USDC);
        (uint128 claimedB, uint128 paymentB, uint128 cancelledB) =
            shareClass.claimRedeem(poolId, scId, INVESTOR_B, USDC);

        assertEq(claimedA, claimedB, "Claimed asset amount should be equal");
        assertEq(claimedA + claimedB + 1, assetPayout, "System should have 1 asset amount atom surplus");
        assert(paymentA != paymentB);
        assertEq(shareClass.pendingRedeem(scId, USDC), 0, "Pending redeem should not have reset");
        assertEq(cancelledA + cancelledB, 0, "No queued cancellation");

        _assertRedeemRequestEq(scId, USDC, INVESTOR_A, UserOrder(0, 2));
        _assertRedeemRequestEq(scId, USDC, INVESTOR_B, UserOrder(0, 2));
    }

    /// @dev Investors can claim 50% rounded down of an uneven number of asset amount => 1 asset amount surplus in
    /// system
    function testClaimRedeemUnevenInvestorsEvenClaimable() public  {
        uint128 approvedShareAmount = DENO_POOL / DENO_USDC;
        uint128 assetPayout = 10;
        uint128 poolPayout = usdcToPool(assetPayout);
        D18 navPerShare = d18(poolPayout, approvedShareAmount);

        shareClass.requestRedeem(poolId, scId, 30 * approvedShareAmount / 100, INVESTOR_A, USDC);
        shareClass.requestRedeem(poolId, scId, 31 * approvedShareAmount / 100, INVESTOR_B, USDC);
        shareClass.requestRedeem(poolId, scId, 39 * approvedShareAmount / 100, INVESTOR_C, USDC);
        _approveAllRedeemsAndRevoke(approvedShareAmount, assetPayout, navPerShare);

        (uint128 claimedA, uint128 paymentA, uint128 cancelledA) =
            shareClass.claimRedeem(poolId, scId, INVESTOR_A, USDC);
        (uint128 claimedB, uint128 paymentB, uint128 cancelledB) =
            shareClass.claimRedeem(poolId, scId, INVESTOR_B, USDC);
        (uint128 claimedC, uint128 paymentC, uint128 cancelledC) =
            shareClass.claimRedeem(poolId, scId, INVESTOR_C, USDC);

        assertEq(claimedA, claimedB, "Claimed asset amount should be equal");
        assertEq(claimedB, claimedC, "Claimed asset amount should be equal");
        assertEq(claimedA + claimedB + claimedC + 1, assetPayout, "System should have 1 asset amount atom surplus");
        assert(paymentA != paymentB && paymentB != paymentC && paymentC != paymentA);
        assertEq(shareClass.pendingRedeem(scId, USDC), 0, "Pending redeem should not have reset");
        assertEq(cancelledA + cancelledB + cancelledC, 0, "No queued cancellation");

        _assertRedeemRequestEq(scId, USDC, INVESTOR_A, UserOrder(0, 2));
        _assertRedeemRequestEq(scId, USDC, INVESTOR_B, UserOrder(0, 2));
        _assertRedeemRequestEq(scId, USDC, INVESTOR_C, UserOrder(0, 2));
    }
}

///@dev Contains all tests which are expected to revert
contract ShareClassManagerRevertsTest is ShareClassManagerBaseTest {
    using MathLib for uint128;

    ShareClassId wrongShareClassId = ShareClassId.wrap(bytes16((uint128(POOL_ID) << 64) + 42));
    address unauthorized = makeAddr("unauthorizedAddress");

    function testFile(bytes32 what) public {
        vm.assume(what != "hubRegistry");
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.UnrecognizedFileParam.selector));
        shareClass.file(what, address(0));
    }

    function testRequestDepositWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassNotFound.selector));
        shareClass.requestDeposit(poolId, wrongShareClassId, 1, investor, USDC);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        shareClass.requestDeposit(poolId, wrongShareClassId, 1, investor, USDC);
    }

    function testCancelRequestDepositWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassNotFound.selector));
        shareClass.cancelDepositRequest(poolId, wrongShareClassId, investor, USDC);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        shareClass.cancelDepositRequest(poolId, wrongShareClassId, investor, USDC);
    }

    function testRequestRedeemWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassNotFound.selector));
        shareClass.requestRedeem(poolId, wrongShareClassId, 1, investor, USDC);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        shareClass.requestRedeem(poolId, wrongShareClassId, 1, investor, USDC);
    }

    function testCancelRedeemRequestWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassNotFound.selector));
        shareClass.cancelRedeemRequest(poolId, wrongShareClassId, investor, USDC);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        shareClass.cancelRedeemRequest(poolId, wrongShareClassId, investor, USDC);
    }

    function testApproveDepositsWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassNotFound.selector));
        shareClass.approveDeposits(poolId, wrongShareClassId, 1, USDC, IERC7726(address(this)));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        shareClass.approveDeposits(poolId, wrongShareClassId, 1, USDC, IERC7726(address(this)));
    }

    function testApproveRedeemsWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassNotFound.selector));
        shareClass.approveRedeems(poolId, wrongShareClassId, 1, USDC);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        shareClass.approveRedeems(poolId, wrongShareClassId, 1, USDC);
    }

    function testIssueSharesWrongShareClassId() public {
        // Mock latestDepositApproval to epoch 1
        vm.store(
            address(shareClass),
keccak256(abi.encode(USDC, keccak256(abi.encode(wrongShareClassId, uint256(STORAGE_INDEX_EPOCH_POINTERS))))),
            bytes32(
                (uint256(1)) // latestDepositApproval
                    | (uint256(0) << 32) // latestRedeemApproval
                    | (uint256(0) << 64) // latestIssuance
                    | (uint256(0) << 96) // latestRevocation
            )
        );

        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassNotFound.selector));
        shareClass.issueShares(poolId, wrongShareClassId, USDC, d18(1));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        shareClass.issueShares(poolId, wrongShareClassId, USDC, d18(1));
    }

    function testIssueSharesUntilEpochWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassNotFound.selector));
        shareClass.issueSharesUntilEpoch(poolId, wrongShareClassId, USDC, d18(1), 0);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        shareClass.issueSharesUntilEpoch(poolId, wrongShareClassId, USDC, d18(1), 0);
    }

    function testRevokeSharesWrongShareClassId() public {
        // Mock latestRedeemApproval to epoch 1
        vm.store(
            address(shareClass),
            keccak256(abi.encode(USDC, keccak256(abi.encode(wrongShareClassId, STORAGE_INDEX_EPOCH_POINTERS)))),
            bytes32(
                (uint256(0)) // latestDepositApproval
                    | (uint256(1) << 32) // latestRedeemApproval
                    | (uint256(0) << 64) // latestIssuance
                    | (uint256(0) << 96) // latestRevocation
            )
        );

        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassNotFound.selector));
        shareClass.revokeShares(poolId, wrongShareClassId, USDC, d18(1), oracleMock);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        shareClass.revokeShares(poolId, wrongShareClassId, USDC, d18(1), oracleMock);
    }

    function testRevokeSharesUntilEpochWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassNotFound.selector));
        shareClass.revokeSharesUntilEpoch(poolId, wrongShareClassId, USDC, d18(1), oracleMock, 0);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        shareClass.revokeSharesUntilEpoch(poolId, wrongShareClassId, USDC, d18(1), oracleMock, 0);
    }

    function testClaimDepositWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassNotFound.selector));
        shareClass.claimDeposit(poolId, wrongShareClassId, investor, USDC);
    }

    function testClaimDepositUntilEpochWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassNotFound.selector));
        shareClass.claimDepositUntilEpoch(poolId, wrongShareClassId, investor, USDC, 0);
    }

    function testClaimRedeemWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassNotFound.selector));
        shareClass.claimRedeem(poolId, wrongShareClassId, investor, USDC);
    }

    function testClaimRedeemUntilEpochWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassNotFound.selector));
        shareClass.claimRedeemUntilEpoch(poolId, wrongShareClassId, investor, USDC, 0);
    }

    function testUpdateShareClassWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassNotFound.selector));
        shareClass.updateShareClass(poolId, wrongShareClassId, d18(1), "");
    }

    function testUpdateMetadataWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassNotFound.selector));
        shareClass.updateMetadata(poolId, wrongShareClassId, "", "", SC_SALT, bytes(""));
    }

    function testIncreaseIssuanceWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassNotFound.selector));
        shareClass.increaseShareClassIssuance(poolId, wrongShareClassId, d18(0), 0);
    }

    function testDecreaseIssuanceWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassNotFound.selector));
        shareClass.decreaseShareClassIssuance(poolId, wrongShareClassId, d18(0), 0);
    }

    function testDecreaseOverFlow() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.DecreaseMoreThanIssued.selector));
        shareClass.decreaseShareClassIssuance(poolId, scId, d18(0), 1);
    }

    function testIssueSharesBeforeApproval() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ApprovalRequired.selector));
        shareClass.issueShares(poolId, scId, USDC, d18(1));
    }

    function testRevokeSharesBeforeApproval() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ApprovalRequired.selector));
        shareClass.revokeShares(poolId, scId, USDC, d18(1), oracleMock);
    }

    function testIssueSharesUntilEpochNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.EpochNotFound.selector));
        shareClass.issueSharesUntilEpoch(poolId, scId, USDC, d18(1), 2);
    }

    function testRevokeSharesUntilEpochNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.EpochNotFound.selector));
        shareClass.revokeSharesUntilEpoch(poolId, scId, USDC, d18(1), oracleMock, 2);
    }

    function testClaimDepositUntilEpochNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.EpochNotFound.selector));
        shareClass.claimDepositUntilEpoch(poolId, scId, investor, USDC, 2);
    }

    function testClaimRedeemUntilEpochNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.EpochNotFound.selector));
        shareClass.claimRedeemUntilEpoch(poolId, scId, investor, USDC, 2);
    }

    function testRequestDepositRequiresClaim() public {
        shareClass.requestDeposit(poolId, scId, 1, investor, USDC);
        shareClass.approveDeposits(poolId, scId, 1, USDC, oracleMock);
        shareClass.cancelDepositRequest(poolId, scId, investor, USDC);

        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.CancellationQueued.selector));
        shareClass.requestDeposit(poolId, scId, 1, investor, USDC);
    }

    function testRequestRedeemCancellationQueued() public {
        shareClass.requestRedeem(poolId, scId, 1, investor, USDC);
        shareClass.approveRedeems(poolId, scId, 1, USDC);
        shareClass.cancelRedeemRequest(poolId, scId, investor, USDC);

        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.CancellationQueued.selector));
        shareClass.requestRedeem(poolId, scId, 1, investor, USDC);
    }

    function testApproveDepositsAlreadyApproved() public {
        shareClass.requestDeposit(poolId, scId, 1, investor, USDC);
        shareClass.approveDeposits(poolId, scId, 1, USDC, oracleMock);

        vm.expectRevert(IShareClassManager.AlreadyApproved.selector);
        shareClass.approveDeposits(poolId, scId, 1, USDC, oracleMock);
    }

    function testApproveRedeemsAlreadyApproved() public {
        shareClass.requestRedeem(poolId, scId, 1, investor, USDC);
        shareClass.approveRedeems(poolId, scId, 1, USDC);

        vm.expectRevert(IShareClassManager.AlreadyApproved.selector);
        shareClass.approveRedeems(poolId, scId, 1, USDC);
    }

    function testApproveDepositsZeroApproval() public {
        vm.expectRevert(IShareClassManager.ZeroApprovalAmount.selector);
        shareClass.approveDeposits(poolId, scId, 0, USDC, oracleMock);
    }

    function testApproveDepositsZeroPending() public {
        vm.expectRevert(IShareClassManager.ZeroApprovalAmount.selector);
        shareClass.approveDeposits(poolId, scId, 1, USDC, oracleMock);
    }

    function testApproveRedeemsZeroApproval() public {
        vm.expectRevert(IShareClassManager.ZeroApprovalAmount.selector);
        shareClass.approveRedeems(poolId, scId, 0, USDC);
    }

    function testApproveRedeemsZeroPending() public {
        vm.expectRevert(IShareClassManager.ZeroApprovalAmount.selector);
        shareClass.approveRedeems(poolId, scId, 1, USDC);
    }

    function testAddShareClassInvalidNameEmpty() public {
        vm.expectRevert(IShareClassManager.InvalidMetadataName.selector);
        shareClass.addShareClass(PoolId.wrap(POOL_ID + 1), "", SC_SYMBOL, SC_SALT, bytes(""));
    }

    function testAddShareClassInvalidNameExcess() public {
        vm.expectRevert(IShareClassManager.InvalidMetadataName.selector);
        shareClass.addShareClass(PoolId.wrap(POOL_ID + 1), string(new bytes(129)), SC_SYMBOL, SC_SALT, bytes(""));
    }

    function testAddShareClassInvalidSymbolEmpty() public {
        vm.expectRevert(IShareClassManager.InvalidMetadataSymbol.selector);
        shareClass.addShareClass(PoolId.wrap(POOL_ID + 1), SC_NAME, "", SC_SALT, bytes(""));
    }

    function testAddShareClassInvalidSymbolExcess() public {
        vm.expectRevert(IShareClassManager.InvalidMetadataSymbol.selector);
        shareClass.addShareClass(PoolId.wrap(POOL_ID + 1), SC_NAME, string(new bytes(33)), SC_SALT, bytes(""));
    }

    function testAddShareClassEmptySalt() public {
        vm.expectRevert(IShareClassManager.InvalidSalt.selector);
        shareClass.addShareClass(PoolId.wrap(POOL_ID + 1), SC_NAME, SC_SYMBOL, bytes32(0), bytes(""));
    }

    function testAddShareClassSaltAlreadyUsed() public {
        vm.expectRevert(IShareClassManager.AlreadyUsedSalt.selector);
        shareClass.addShareClass(poolId, SC_NAME, SC_SYMBOL, SC_SALT, bytes(""));
    }

    function testUpdateMetadataClassInvalidNameEmpty() public {
        vm.expectRevert(IShareClassManager.InvalidMetadataName.selector);
        shareClass.updateMetadata(poolId, scId, "", SC_SYMBOL, SC_SALT, bytes(""));
    }

    function testUpdateMetadataClassInvalidNameExcess() public {
        vm.expectRevert(IShareClassManager.InvalidMetadataName.selector);
        shareClass.updateMetadata(poolId, scId, string(new bytes(129)), SC_SYMBOL, SC_SALT, bytes(""));
    }

    function testUpdateMetadataClassInvalidSymbolEmpty() public {
        vm.expectRevert(IShareClassManager.InvalidMetadataSymbol.selector);
        shareClass.updateMetadata(poolId, scId, SC_NAME, "", bytes32(0), bytes(""));
    }

    function testUpdateMetadataClassInvalidSymbolExcess() public {
        vm.expectRevert(IShareClassManager.InvalidMetadataSymbol.selector);
        shareClass.updateMetadata(poolId, scId, SC_NAME, string(new bytes(33)), bytes32(0), bytes(""));
    }

    function testUpdateMetadataInvalidSalt() public {
        vm.expectRevert(IShareClassManager.InvalidSalt.selector);
        shareClass.updateMetadata(poolId, scId, SC_NAME, SC_SYMBOL, bytes32(0), bytes(""));
    }

    function testUpdateMetadataSaltAlreadyUsed() public {
        shareClass.addShareClass(poolId, SC_NAME, SC_SYMBOL, SC_SECOND_SALT, bytes(""));
        vm.expectRevert(IShareClassManager.AlreadyUsedSalt.selector);
        shareClass.updateMetadata(poolId, scId, SC_NAME, SC_SYMBOL, SC_SECOND_SALT, bytes(""));
    }
}
*/
