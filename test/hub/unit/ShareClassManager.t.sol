// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {MathLib} from "src/misc/libraries/MathLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {PricingLib} from "src/common/libraries/PricingLib.sol";
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
    using PricingLib for *;

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
        shareClass.addShareClass(poolId, SC_NAME, SC_SYMBOL, SC_SALT);

        assertEq(IHubRegistry(hubRegistryMock).currency(poolId).addr(), POOL_CURRENCY);
        assertEq(IHubRegistry(hubRegistryMock).decimals(poolId), DECIMALS_POOL);
        assertEq(IHubRegistry(hubRegistryMock).decimals(USDC), DECIMALS_USDC);
        assertEq(IHubRegistry(hubRegistryMock).decimals(OTHER_STABLE), DECIMALS_OTHER_STABLE);
    }

    function _intoPoolAmount(AssetId assetId, uint128 amount) internal view returns (uint128) {
        return PricingLib.convertWithPrice(
            amount,
            IHubRegistry(hubRegistryMock).decimals(assetId),
            IHubRegistry(hubRegistryMock).decimals(poolId),
            _pricePoolPerAsset(assetId)
        ).toUint128();
    }

    function _intoAssetAmount(AssetId assetId, uint128 amount) internal view returns (uint128) {
        return PricingLib.convertWithPrice(
            amount,
            IHubRegistry(hubRegistryMock).decimals(poolId),
            IHubRegistry(hubRegistryMock).decimals(assetId),
            _pricePoolPerAsset(assetId).reciprocal()
        ).toUint128();
    }

    function _calcSharesIssued(AssetId assetId, uint128 depositAmountAsset, D18 pricePoolPerShare)
        internal
        view
        returns (uint128)
    {
        return pricePoolPerShare.reciprocalMulUint256(
            PricingLib.convertWithPrice(
                depositAmountAsset,
                IHubRegistry(hubRegistryMock).decimals(assetId),
                IHubRegistry(hubRegistryMock).decimals(poolId),
                _pricePoolPerAsset(assetId)
            ),
            MathLib.Rounding.Down
        ).toUint128();
    }

    function _pricePoolPerAsset(AssetId assetId) internal pure returns (D18) {
        if (assetId.eq(USDC)) {
            return d18(1, 1);
        } else if (assetId.eq(OTHER_STABLE)) {
            return d18(1, OTHER_STABLE_PER_POOL);
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
    {
        (
            uint128 pendingShareAmount,
            uint128 approvedShareAmount,
            uint128 payoutAssetAmount,
            D18 pricePoolPerAsset,
            D18 navPoolPerShare,
            uint64 revokedAt
        ) = shareClass.epochRedeemAmounts(scId, assetId, epochId);

        assertEq(pendingShareAmount, expected.pendingShareAmount, "Mismatch: EpochRedeemAmount.pendingShareAmount");
        assertEq(approvedShareAmount, expected.approvedShareAmount, "Mismatch: EpochRedeemAmount.approvedShareAmount");
        assertEq(payoutAssetAmount, expected.payoutAssetAmount, "Mismatch: EpochRedeemAmount.payoutAssetAmount");
        assertEq(
            pricePoolPerAsset.raw(), expected.pricePoolPerAsset.raw(), "Mismatch: EpochRedeemAmount.pricePoolPerAsset"
        );
        assertEq(navPoolPerShare.raw(), expected.navPoolPerShare.raw(), "Mismatch: EpochRedeemAmount.navPoolPerShare");
        assertEq(revokedAt, expected.revokedAt, "Mismatch: EpochRedeemAmount.issuedAt");
    }

    function _mockTotalIssuance(uint128 amount) internal {
        vm.store(
            address(shareClass), keccak256(abi.encode(scId, uint256(STORAGE_INDEX_METRICS))), bytes32(uint256(amount))
        );
        assertEq(_totalIssuance(), amount);
    }

    function _totalIssuance() internal view returns (uint128 totalIssuance_) {
        (totalIssuance_,) = shareClass.metrics(scId);
    }

    function _nowDeposit(AssetId assetId) internal view returns (uint32) {
        return shareClass.nowDepositEpoch(scId, assetId);
    }

    function _nowIssue(AssetId assetId) internal view returns (uint32) {
        return shareClass.nowIssueEpoch(scId, assetId);
    }

    function _nowRedeem(AssetId assetId) internal view returns (uint32) {
        return shareClass.nowRedeemEpoch(scId, assetId);
    }

    function _nowRevoke(AssetId assetId) internal view returns (uint32) {
        return shareClass.nowRevokeEpoch(scId, assetId);
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

    function testUpdatePricePerShare() public {
        vm.expectEmit();
        emit IShareClassManager.UpdateShareClass(poolId, scId, d18(2, 1));
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

    function testMaxDepositClaims() public {
        assertEq(shareClass.maxDepositClaims(scId, investor, USDC), 0);

        shareClass.requestDeposit(poolId, scId, 1, investor, USDC);
        assertEq(shareClass.maxDepositClaims(scId, investor, USDC), 0);
    }

    function testMaxRedeemClaims() public {
        assertEq(shareClass.maxRedeemClaims(scId, investor, USDC), 0);

        shareClass.requestRedeem(poolId, scId, 1, investor, USDC);
        assertEq(shareClass.maxRedeemClaims(scId, investor, USDC), 0);
    }
}

///@dev Contains all deposit related tests which are expected to succeed and don't make use of transient storage
contract ShareClassManagerDepositsNonTransientTest is ShareClassManagerBaseTest {
    using MathLib for *;

    function _deposit(uint128 depositAmountUsdc_, uint128 approvedAmountUsdc_)
        internal
        returns (uint128 depositAmountUsdc, uint128 approvedAmountUsdc, uint128 approvedPool)
    {
        depositAmountUsdc = uint128(bound(depositAmountUsdc_, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC));
        approvedAmountUsdc = uint128(bound(approvedAmountUsdc_, MIN_REQUEST_AMOUNT_USDC - 1, depositAmountUsdc));
        approvedPool = _intoPoolAmount(USDC, approvedAmountUsdc);

        shareClass.requestDeposit(poolId, scId, depositAmountUsdc, investor, USDC);
        shareClass.approveDeposits(poolId, scId, USDC, _nowDeposit(USDC), approvedAmountUsdc, _pricePoolPerAsset(USDC));
    }

    function testRequestDeposit(uint128 amount) public {
        amount = uint128(bound(amount, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC));

        assertEq(shareClass.pendingDeposit(scId, USDC), 0);
        _assertDepositRequestEq(USDC, investor, UserOrder(0, 0));

        vm.expectEmit();
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

        vm.expectEmit();
        emit IShareClassManager.UpdateDepositRequest(
            poolId, scId, USDC, shareClass.nowDepositEpoch(scId, USDC), investor, 0, 0, 0, false
        );
        (uint128 cancelledShares) = shareClass.cancelDepositRequest(poolId, scId, investor, USDC);

        assertEq(cancelledShares, amount);
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
        (uint128 depositAmountUsdc, uint128 approvedAmountUsdc, uint128 approvedPool) =
            _deposit(fuzzDepositAmountUsdc, fuzzApprovedAmountUsdc);

        uint128 shares = _calcSharesIssued(USDC, approvedAmountUsdc, navPoolPerShare);

        assertEq(_totalIssuance(), 0, "Mismatch: totalIssuance");

        (uint128 issuedShareAmount, uint128 depositAssetAmount, uint128 depositPoolAmount) =
            shareClass.issueShares(poolId, scId, USDC, _nowIssue(USDC), navPoolPerShare);
        assertEq(issuedShareAmount, shares, "Mismatch: return issuedShareAmount");
        assertEq(depositAssetAmount, approvedAmountUsdc, "Mismatch: return depositAssetAmount");
        assertEq(depositPoolAmount, approvedPool, "Mismatch: return depositPoolAmount");

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

    function testClaimDepositZeroApproved() public {
        shareClass.requestDeposit(poolId, scId, 1, investor, USDC);
        shareClass.requestDeposit(poolId, scId, 10, bytes32("investorOther"), USDC);
        shareClass.approveDeposits(poolId, scId, USDC, _nowDeposit(USDC), 1, d18(1));

        shareClass.issueShares(poolId, scId, USDC, _nowIssue(USDC), d18(1));

        vm.expectEmit();
        emit IShareClassManager.ClaimDeposit(poolId, scId, 1, investor, USDC, 0, 1, 0, block.timestamp.toUint64());
        shareClass.claimDeposit(poolId, scId, investor, USDC);
    }

    function testFullClaimDepositSingleEpoch() public {
        uint128 approvedAmountUsdc = 100 * DENO_USDC;
        uint128 depositAmountUsdc = approvedAmountUsdc;
        uint128 approvedPool = _intoPoolAmount(USDC, approvedAmountUsdc);
        assertEq(approvedPool, 100 * DENO_POOL);

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
        D18 navPoolPerShare = d18(uint128(bound(navPoolPerShare_, 1e14, type(uint128).max / 1e18)));
        (uint128 depositAmountUsdc, uint128 approvedAmountUsdc,) =
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

    function testClaimDepositSkippedEpochsNoPayout(uint8 skippedEpochs) public {
        vm.assume(skippedEpochs > 0);

        D18 navPoolPerShare = d18(1e18);
        uint128 approvedAmountUsdc = 1;
        uint32 lastUpdate = _nowDeposit(USDC);

        // Other investor should eat up the single approved asset amount
        shareClass.requestDeposit(poolId, scId, 1, investor, USDC);
        shareClass.requestDeposit(poolId, scId, MAX_REQUEST_AMOUNT_USDC, bytes32("bigPockets"), USDC);

        // Approve a few epochs without payout
        for (uint256 i = 0; i < skippedEpochs; i++) {
            shareClass.approveDeposits(
                poolId, scId, USDC, _nowDeposit(USDC), approvedAmountUsdc, _pricePoolPerAsset(USDC)
            );
            shareClass.issueShares(poolId, scId, USDC, _nowIssue(USDC), navPoolPerShare);
        }

        // Claim all epochs without expected payout due to low deposit amount
        for (uint256 i = 0; i < skippedEpochs; i++) {
            vm.expectEmit();
            emit IShareClassManager.ClaimDeposit(
                poolId, scId, lastUpdate, investor, USDC, 0, 1, 0, block.timestamp.toUint64()
            );
            (uint128 payout, uint128 payment, uint128 cancelled, bool canClaimAgain) =
                shareClass.claimDeposit(poolId, scId, investor, USDC);

            assertEq(payout, 0, "Mismatch: payout");
            assertEq(payment, 0, "Mismatch: payment");
            assertEq(cancelled, 0, "Mismatch: cancelled");
            assertEq(canClaimAgain, i < skippedEpochs - 1, "Mismatch: canClaimAgain");
            lastUpdate += 1;
            _assertDepositRequestEq(USDC, investor, UserOrder(1, lastUpdate));
        }
    }

    function testClaimDepositSkippedEpochsNothingRemaining(uint128 depositAmountUsdc_, uint8 skippedEpochs) public {
        vm.assume(skippedEpochs > 0);

        D18 nonZeroPrice = d18(1e18);
        uint128 depositAmountUsdc = uint128(bound(depositAmountUsdc_, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC));

        // Approve one epoch with full payout and a few subsequent ones without payout
        shareClass.requestDeposit(poolId, scId, depositAmountUsdc, investor, USDC);
        shareClass.approveDeposits(poolId, scId, USDC, _nowDeposit(USDC), depositAmountUsdc, nonZeroPrice);
        shareClass.issueShares(poolId, scId, USDC, _nowIssue(USDC), nonZeroPrice);

        // Request deposit with another investors to enable approvals after first epoch
        shareClass.requestDeposit(poolId, scId, MAX_REQUEST_AMOUNT_USDC, bytes32("bigPockets"), USDC);

        // Approve more epochs which should all be skipped when investor claims first epoch
        for (uint256 i = 0; i < skippedEpochs; i++) {
            shareClass.approveDeposits(poolId, scId, USDC, _nowDeposit(USDC), 1, nonZeroPrice);
            shareClass.issueShares(poolId, scId, USDC, _nowIssue(USDC), nonZeroPrice);
        }

        // Expect only single claim to be required
        (uint128 payout, uint128 payment, uint128 cancelled, bool canClaimAgain) =
            shareClass.claimDeposit(poolId, scId, investor, USDC);

        assertNotEq(payout, 0, "Mismatch: payout");
        assertEq(payment, depositAmountUsdc, "Mismatch: payment");
        assertEq(cancelled, 0, "Mismatch: cancelled");
        assertEq(canClaimAgain, false, "Mismatch: canClaimAgain - all claimed");
        _assertDepositRequestEq(USDC, investor, UserOrder(0, 2 + uint32(skippedEpochs)));

        vm.expectRevert(IShareClassManager.NoOrderFound.selector);
        shareClass.claimDeposit(poolId, scId, investor, USDC);
    }

    function testClaimDepositManyEpochs(uint128 navPoolPerShare_, uint128 depositAmountUsdc_, uint8 epochs) public {
        D18 poolPerShare = d18(uint128(bound(navPoolPerShare_, 1e10, type(uint128).max / 1e18)));
        epochs = uint8(bound(epochs, 3, 50));
        uint128 depositAmountUsdc = uint128(bound(depositAmountUsdc_, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC));
        vm.assume(depositAmountUsdc % epochs == 0);

        uint128 epochApprovedAmountUsdc = depositAmountUsdc / epochs;
        uint128 totalShares = 0;
        uint128 totalPayment = 0;
        uint128 totalPayout = 0;

        shareClass.requestDeposit(poolId, scId, depositAmountUsdc, investor, USDC);

        // Approve + issue shares for each epoch
        for (uint256 i = 0; i < epochs; i++) {
            shareClass.approveDeposits(
                poolId, scId, USDC, _nowDeposit(USDC), epochApprovedAmountUsdc, _pricePoolPerAsset(USDC)
            );

            (uint128 issuedShares, uint128 issuedDepositAmountUsdc,) =
                shareClass.issueShares(poolId, scId, USDC, _nowIssue(USDC), poolPerShare);
            totalShares += issuedShares;

            assertEq(issuedDepositAmountUsdc, epochApprovedAmountUsdc, "Mismatch: issued deposit amount");
        }

        assertEq(shareClass.maxDepositClaims(scId, investor, USDC), epochs);

        for (uint256 i = 0; i < epochs; i++) {
            (uint128 payout, uint128 payment, uint128 cancelled, bool canClaimAgain) =
                shareClass.claimDeposit(poolId, scId, investor, USDC);

            totalPayout += payout;
            totalPayment += payment;
            assertEq(cancelled, 0, "Mismatch: cancelled");
            assertEq(payment, epochApprovedAmountUsdc, "Mismatch: payment");
            assertEq(canClaimAgain, i < epochs - 1, "Mismatch: canClaimAgain - all claimed");
        }

        assertEq(totalPayment, depositAmountUsdc, "Mismatch: Total payment");
        assertEq(totalPayout, totalShares, "Mismatch: Total payout");

        _assertDepositRequestEq(USDC, investor, UserOrder(0, epochs + 1));
    }

    function testQueuedDepositWithoutCancellation(uint128 depositAmountUsdc) public {
        depositAmountUsdc = uint128(bound(depositAmountUsdc, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC / 3));
        uint32 epochId = 1;
        D18 poolPerShare = d18(1, 1);
        uint128 claimedShares = _calcSharesIssued(USDC, depositAmountUsdc, poolPerShare);
        uint128 queuedAmount = 0;

        // Initial deposit request
        _assertQueuedDepositRequestEq(USDC, investor, QueuedOrder(false, queuedAmount));
        shareClass.requestDeposit(poolId, scId, depositAmountUsdc, investor, USDC);
        _assertDepositRequestEq(USDC, investor, UserOrder(depositAmountUsdc, epochId));
        assertEq(shareClass.pendingDeposit(scId, USDC), depositAmountUsdc);
        shareClass.approveDeposits(poolId, scId, USDC, _nowDeposit(USDC), depositAmountUsdc, _pricePoolPerAsset(USDC));
        epochId = 2;

        // Expect queued increment due to approval
        queuedAmount += depositAmountUsdc;
        vm.expectEmit();
        emit IShareClassManager.UpdateDepositRequest(
            poolId, scId, USDC, epochId, investor, depositAmountUsdc, 0, queuedAmount, false
        );
        shareClass.requestDeposit(poolId, scId, depositAmountUsdc, investor, USDC);
        _assertDepositRequestEq(USDC, investor, UserOrder(queuedAmount, epochId - 1));
        assertEq(shareClass.pendingDeposit(scId, USDC), 0);
        _assertQueuedDepositRequestEq(USDC, investor, QueuedOrder(false, queuedAmount));
        _assertQueuedRedeemRequestEq(USDC, investor, QueuedOrder(false, 0));

        // Expect queued increment due to approval
        queuedAmount += depositAmountUsdc;
        vm.expectEmit();
        emit IShareClassManager.UpdateDepositRequest(
            poolId, scId, USDC, epochId, investor, depositAmountUsdc, 0, queuedAmount, false
        );
        shareClass.requestDeposit(poolId, scId, depositAmountUsdc, investor, USDC);
        _assertQueuedDepositRequestEq(USDC, investor, QueuedOrder(false, queuedAmount));

        // Issue shares + claim -> expect queued to move to pending
        shareClass.issueShares(poolId, scId, USDC, _nowIssue(USDC), poolPerShare);
        vm.expectEmit();
        emit IShareClassManager.ClaimDeposit(
            poolId, scId, 1, investor, USDC, depositAmountUsdc, 0, claimedShares, block.timestamp.toUint64()
        );
        emit IShareClassManager.UpdateDepositRequest(
            poolId, scId, USDC, epochId, investor, queuedAmount, queuedAmount, 0, false
        );
        shareClass.claimDeposit(poolId, scId, investor, USDC);

        _assertDepositRequestEq(USDC, investor, UserOrder(queuedAmount, epochId));
        assertEq(shareClass.pendingDeposit(scId, USDC), queuedAmount);
        _assertQueuedDepositRequestEq(USDC, investor, QueuedOrder(false, 0));
        _assertQueuedRedeemRequestEq(USDC, investor, QueuedOrder(false, 0));
    }

    function testQueuedDepositWithNonEmptyQueuedCancellation(uint128 depositAmountUsdc) public {
        vm.assume(depositAmountUsdc % 2 == 0);
        depositAmountUsdc = uint128(bound(depositAmountUsdc, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC));
        D18 poolPerShare = d18(1, 1);
        uint128 approvedAssetAmount = depositAmountUsdc / 4;
        uint128 pendingAssetAmount = depositAmountUsdc - approvedAssetAmount;
        uint128 issuedShares = _calcSharesIssued(USDC, approvedAssetAmount, poolPerShare);
        uint128 queuedAmount = 0;
        uint32 epochId = 1;

        // Initial deposit request
        shareClass.requestDeposit(poolId, scId, depositAmountUsdc, investor, USDC);
        shareClass.approveDeposits(poolId, scId, USDC, _nowDeposit(USDC), approvedAssetAmount, _pricePoolPerAsset(USDC));

        // Expect queued increment due to approval
        epochId = 2;
        queuedAmount += depositAmountUsdc;
        shareClass.requestDeposit(poolId, scId, depositAmountUsdc, investor, USDC);
        vm.expectEmit();
        emit IShareClassManager.UpdateDepositRequest(
            poolId, scId, USDC, epochId, investor, depositAmountUsdc, pendingAssetAmount, queuedAmount, true
        );
        (uint128 cancelledPending) = shareClass.cancelDepositRequest(poolId, scId, investor, USDC);
        assertEq(cancelledPending, 0, "Cancellation queued");

        // Expect revert due to queued cancellation
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.CancellationQueued.selector));
        shareClass.requestDeposit(poolId, scId, 1, investor, USDC);
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.CancellationQueued.selector));
        shareClass.cancelDepositRequest(poolId, scId, investor, USDC);

        // Issue shares + claim -> expect cancel fulfillment
        shareClass.issueShares(poolId, scId, USDC, _nowIssue(USDC), poolPerShare);
        vm.expectEmit();
        emit IShareClassManager.ClaimDeposit(
            poolId,
            scId,
            1,
            investor,
            USDC,
            approvedAssetAmount,
            pendingAssetAmount,
            issuedShares,
            block.timestamp.toUint64()
        );
        emit IShareClassManager.UpdateDepositRequest(poolId, scId, USDC, epochId, investor, 0, 0, 0, false);
        (uint128 claimedShareAmount, uint128 claimedAssetAmount, uint128 cancelledTotal, bool canClaimAgain) =
            shareClass.claimDeposit(poolId, scId, investor, USDC);
        assertEq(claimedShareAmount, issuedShares, "Claimed share amount mismatch");
        assertEq(claimedAssetAmount, approvedAssetAmount, "Claimed asset amount mismatch");
        assertEq(cancelledTotal, pendingAssetAmount + queuedAmount, "Cancelled amount mismatch");
        assertEq(canClaimAgain, false, "Can claim again mismatch");

        _assertDepositRequestEq(USDC, investor, UserOrder(0, epochId));
        assertEq(shareClass.pendingDeposit(scId, USDC), 0, "Pending deposit mismatch");
        _assertQueuedDepositRequestEq(USDC, investor, QueuedOrder(false, 0));
        _assertQueuedRedeemRequestEq(USDC, investor, QueuedOrder(false, 0));
    }

    function testQueuedDepositWithEmptyQueuedCancellation(uint128 depositAmountUsdc) public {
        vm.assume(depositAmountUsdc % 2 == 0);
        depositAmountUsdc = uint128(bound(depositAmountUsdc, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC));
        D18 poolPerShare = d18(1, 1);
        uint128 approvedAssetAmount = depositAmountUsdc / 4;
        uint128 pendingAssetAmount = depositAmountUsdc - approvedAssetAmount;
        uint128 issuedShares = _calcSharesIssued(USDC, approvedAssetAmount, poolPerShare);
        uint32 epochId = 1;

        // Initial deposit request
        shareClass.requestDeposit(poolId, scId, depositAmountUsdc, investor, USDC);
        shareClass.approveDeposits(poolId, scId, USDC, _nowDeposit(USDC), approvedAssetAmount, _pricePoolPerAsset(USDC));
        epochId = 2;

        // Expect queued increment due to approval
        vm.expectEmit();
        emit IShareClassManager.UpdateDepositRequest(
            poolId, scId, USDC, epochId, investor, depositAmountUsdc, pendingAssetAmount, 0, true
        );
        (uint128 cancelledPending) = shareClass.cancelDepositRequest(poolId, scId, investor, USDC);
        assertEq(cancelledPending, 0, "Cancellation queued");

        // Issue shares + claim -> expect cancel fulfillment
        shareClass.issueShares(poolId, scId, USDC, _nowIssue(USDC), poolPerShare);
        vm.expectEmit();
        emit IShareClassManager.ClaimDeposit(
            poolId,
            scId,
            1,
            investor,
            USDC,
            approvedAssetAmount,
            pendingAssetAmount,
            issuedShares,
            block.timestamp.toUint64()
        );
        emit IShareClassManager.UpdateDepositRequest(poolId, scId, USDC, epochId, investor, 0, 0, 0, false);
        (uint128 claimedShareAmount, uint128 claimedAssetAmount, uint128 cancelledTotal, bool canClaimAgain) =
            shareClass.claimDeposit(poolId, scId, investor, USDC);
        assertEq(claimedShareAmount, issuedShares, "Claimed share amount mismatch");
        assertEq(claimedAssetAmount, approvedAssetAmount, "Claimed asset amount mismatch");
        assertEq(cancelledTotal, pendingAssetAmount, "Cancelled amount mismatch");
        assertEq(canClaimAgain, false, "Can claim again mismatch");

        _assertDepositRequestEq(USDC, investor, UserOrder(0, epochId));
        assertEq(shareClass.pendingDeposit(scId, USDC), 0, "Pending deposit mismatch");
        _assertQueuedDepositRequestEq(USDC, investor, QueuedOrder(false, 0));
        _assertQueuedRedeemRequestEq(USDC, investor, QueuedOrder(false, 0));
    }
}

///@dev Contains all redeem related tests which are expected to succeed and don't make use of transient storage
contract ShareClassManagerRedeemsNonTransientTest is ShareClassManagerBaseTest {
    using MathLib for *;

    function _redeem(uint128 redeemShares_, uint128 approvedShares_, uint128 navPerShare)
        internal
        returns (uint128 redeemShares, uint128 approvedShares, uint128 approvedPool, D18 poolPerShare)
    {
        redeemShares = uint128(bound(redeemShares_, MIN_REQUEST_AMOUNT_SHARES, MAX_REQUEST_AMOUNT_SHARES));
        approvedShares = uint128(bound(approvedShares_, MIN_REQUEST_AMOUNT_SHARES, redeemShares));
        poolPerShare = d18(uint128(bound(navPerShare, 1e15, type(uint128).max / 1e18)));
        approvedPool = poolPerShare.mulUint128(approvedShares, MathLib.Rounding.Down);

        shareClass.requestRedeem(poolId, scId, redeemShares, investor, USDC);
        shareClass.approveRedeems(poolId, scId, USDC, _nowRedeem(USDC), approvedShares, _pricePoolPerAsset(USDC));
    }

    function testRequestRedeem(uint128 amount) public {
        amount = uint128(bound(amount, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC));

        assertEq(shareClass.pendingRedeem(scId, USDC), 0);
        _assertRedeemRequestEq(USDC, investor, UserOrder(0, 0));

        vm.expectEmit();
        emit IShareClassManager.UpdateRedeemRequest(poolId, scId, USDC, 1, investor, amount, amount, 0, false);
        shareClass.requestRedeem(poolId, scId, amount, investor, USDC);

        assertEq(shareClass.pendingRedeem(scId, USDC), amount);
        _assertRedeemRequestEq(USDC, investor, UserOrder(amount, 1));
    }

    function testCancelRedeemRequest(uint128 amount) public {
        amount = uint128(bound(amount, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC));
        shareClass.requestRedeem(poolId, scId, amount, investor, USDC);

        vm.expectEmit();
        emit IShareClassManager.UpdateRedeemRequest(poolId, scId, USDC, 1, investor, 0, 0, 0, false);
        (uint128 cancelledShares) = shareClass.cancelRedeemRequest(poolId, scId, investor, USDC);

        assertEq(cancelledShares, amount);
        assertEq(shareClass.pendingRedeem(scId, USDC), 0);
        _assertRedeemRequestEq(USDC, investor, UserOrder(0, 1));
    }

    function testApproveRedeemsSingleAssetManyInvestors(
        uint8 numInvestors,
        uint128 redeemShares,
        uint128 approvedShares
    ) public {
        numInvestors = uint8(bound(numInvestors, 1, 100));
        redeemShares = uint128(bound(redeemShares, MIN_REQUEST_AMOUNT_SHARES, MAX_REQUEST_AMOUNT_SHARES));
        approvedShares = uint128(bound(approvedShares, MIN_REQUEST_AMOUNT_SHARES, redeemShares));

        uint128 totalRedeem = 0;
        for (uint16 i = 0; i < numInvestors; i++) {
            bytes32 investor = bytes32(uint256(keccak256(abi.encodePacked("investor_", i))));
            uint128 investorRedeem = redeemShares + i;
            totalRedeem += investorRedeem;
            shareClass.requestRedeem(poolId, scId, investorRedeem, investor, USDC);

            assertEq(shareClass.pendingRedeem(scId, USDC), totalRedeem);
        }
        assertEq(_nowRedeem(USDC), 1);

        uint128 pendingRedeem = totalRedeem - approvedShares;

        vm.expectEmit();
        emit IShareClassManager.ApproveRedeems(poolId, scId, USDC, 1, approvedShares, pendingRedeem);
        shareClass.approveRedeems(poolId, scId, USDC, _nowRedeem(USDC), approvedShares, _pricePoolPerAsset(USDC));

        assertEq(shareClass.pendingRedeem(scId, USDC), pendingRedeem);

        // Only one epoch should have passed
        assertEq(_nowRedeem(USDC), 2);

        _assertEpochRedeemAmountsEq(
            USDC, 1, EpochRedeemAmounts(totalRedeem, approvedShares, 0, _pricePoolPerAsset(USDC), d18(0), 0)
        );
    }

    function testApproveRedeemsTwoAssetsSameEpoch(uint128 redeemShares, uint128 approvedShares) public {
        uint128 redeemSharesUsdc = uint128(bound(redeemShares, MIN_REQUEST_AMOUNT_SHARES, MAX_REQUEST_AMOUNT_SHARES));
        uint128 redeemSharesOther =
            uint128(bound(redeemShares, MIN_REQUEST_AMOUNT_SHARES - 1, MAX_REQUEST_AMOUNT_SHARES - 1));
        uint128 approvedSharesUsdc = uint128(bound(approvedShares, MIN_REQUEST_AMOUNT_SHARES, redeemSharesUsdc));
        uint128 approvedSharesOther = uint128(bound(approvedShares, DENO_OTHER_STABLE, redeemSharesOther));
        bytes32 investorUsdc = bytes32("investorUsdc");
        bytes32 investorOther = bytes32("investorOther");
        uint128 pendingUsdc = redeemSharesUsdc - approvedSharesUsdc;
        uint128 pendingOther = redeemSharesOther - approvedSharesOther;

        shareClass.requestRedeem(poolId, scId, redeemSharesUsdc, investorUsdc, USDC);
        shareClass.requestRedeem(poolId, scId, redeemSharesOther, investorOther, OTHER_STABLE);

        assertEq(_nowRedeem(USDC), 1);
        assertEq(_nowRedeem(OTHER_STABLE), 1);

        uint128 pendingUsdc_ = shareClass.approveRedeems(
            poolId, scId, USDC, _nowRedeem(USDC), approvedSharesUsdc, _pricePoolPerAsset(USDC)
        );
        uint128 pendingOther_ = shareClass.approveRedeems(
            poolId, scId, OTHER_STABLE, _nowRedeem(OTHER_STABLE), approvedSharesOther, _pricePoolPerAsset(OTHER_STABLE)
        );

        assertEq(_nowRedeem(USDC), 2);
        assertEq(_nowRedeem(OTHER_STABLE), 2);

        assertEq(pendingUsdc_, pendingUsdc, "pending shares USDC mismatch");
        assertEq(pendingOther_, pendingOther, "pending shares OtherCurrency mismatch");

        _assertEpochRedeemAmountsEq(
            USDC, 1, EpochRedeemAmounts(redeemSharesUsdc, approvedSharesUsdc, 0, _pricePoolPerAsset(USDC), d18(0), 0)
        );
        _assertEpochRedeemAmountsEq(
            OTHER_STABLE,
            1,
            EpochRedeemAmounts(redeemSharesOther, approvedSharesOther, 0, _pricePoolPerAsset(OTHER_STABLE), d18(0), 0)
        );
    }

    function testRevokeSharesSingleEpoch(uint128 navPerShare, uint128 redeemShares, uint128 approvedShares) public {
        redeemShares = uint128(bound(redeemShares, MIN_REQUEST_AMOUNT_SHARES, MAX_REQUEST_AMOUNT_SHARES));
        approvedShares = uint128(bound(approvedShares, MIN_REQUEST_AMOUNT_SHARES, redeemShares));
        D18 poolPerShare = d18(uint128(bound(navPerShare, 1e15, type(uint128).max / 1e18)));
        uint128 poolAmount = poolPerShare.mulUint128(approvedShares, MathLib.Rounding.Down);
        uint128 assetAmount = _intoAssetAmount(USDC, poolAmount);

        // Mock total issuance to equal redeemShares
        _mockTotalIssuance(redeemShares);

        shareClass.requestRedeem(poolId, scId, redeemShares, investor, USDC);
        shareClass.approveRedeems(poolId, scId, USDC, _nowRedeem(USDC), approvedShares, _pricePoolPerAsset(USDC));

        assertEq(_totalIssuance(), redeemShares);
        assertEq(_nowRevoke(USDC), 1);

        (uint128 revokedShares, uint128 revokedAssets, uint128 revokedPool) =
            shareClass.revokeShares(poolId, scId, USDC, _nowRevoke(USDC), poolPerShare);
        assertEq(approvedShares, revokedShares, "revoked share amount mismatch");
        assertEq(assetAmount, revokedAssets, "revoked asset amount mismatch");
        assertEq(poolAmount, revokedPool, "revoked pool amount mismatch");

        assertEq(_totalIssuance(), redeemShares - approvedShares);
        assertEq(_nowRevoke(USDC), 2);
    }

    function testRevokeShareExceedsIssuance() public {
        shareClass.requestRedeem(poolId, scId, 1, investor, USDC);
        shareClass.approveRedeems(poolId, scId, USDC, _nowRedeem(USDC), 1, _pricePoolPerAsset(USDC));

        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.RevokeMoreThanIssued.selector));
        shareClass.revokeShares(poolId, scId, USDC, 1, d18(1));
    }

    function testClaimRedeemZeroApproved() public {
        _mockTotalIssuance(11);

        shareClass.requestRedeem(poolId, scId, 1, investor, USDC);
        shareClass.requestRedeem(poolId, scId, 10, bytes32("investorOther"), USDC);
        shareClass.approveRedeems(poolId, scId, USDC, _nowRedeem(USDC), 1, _pricePoolPerAsset(USDC));
        shareClass.revokeShares(poolId, scId, USDC, _nowRevoke(USDC), d18(1));

        vm.expectEmit();
        emit IShareClassManager.ClaimRedeem(poolId, scId, 1, investor, USDC, 0, 1, 0, block.timestamp.toUint64());
        shareClass.claimRedeem(poolId, scId, investor, USDC);
    }

    function testClaimRedeemSingleEpoch(uint128 redeemShares_, uint128 approvedShares_, uint128 navPoolPerShare_)
        public
    {
        (uint128 redeemShares, uint128 approvedShares,, D18 poolPerShare) =
            _redeem(redeemShares_, approvedShares_, navPoolPerShare_);
        uint128 pendingShares = redeemShares - approvedShares;

        // Mock total issuance to equal redeemShares
        _mockTotalIssuance(redeemShares);

        (, uint128 revokedAssets,) = shareClass.revokeShares(poolId, scId, USDC, _nowRevoke(USDC), poolPerShare);
        assertEq(_totalIssuance(), pendingShares);
        _assertRedeemRequestEq(USDC, investor, UserOrder(redeemShares, 1));

        vm.expectEmit();
        emit IShareClassManager.ClaimRedeem(
            poolId, scId, 1, investor, USDC, approvedShares, pendingShares, revokedAssets, block.timestamp.toUint64()
        );
        (uint128 claimedAssets, uint128 redeemedShares, uint128 cancelledShares, bool canClaimAgain) =
            shareClass.claimRedeem(poolId, scId, investor, USDC);

        assertEq(claimedAssets, revokedAssets, "payout asset amount mismatch");
        assertEq(redeemedShares, revokedAssets > 0 ? approvedShares : 0, "payment shares mismatch");
        pendingShares = revokedAssets > 0 ? redeemShares - approvedShares : redeemShares;
        _assertRedeemRequestEq(USDC, investor, UserOrder(pendingShares, 2));
        assertEq(cancelledShares, 0, "no queued cancellation");
        assertEq(canClaimAgain, false, "already claimed up to latest revoked epoch");
    }

    function testClaimRedeemSkippedEpochsNoPayout(uint8 skippedEpochs) public {
        vm.assume(skippedEpochs > 0);

        D18 navPoolPerShare = d18(1e18);
        uint128 approvedShares = 1;
        uint32 lastUpdate = _nowRedeem(USDC);

        // Other investor should eat up the single approved asset amount
        shareClass.requestRedeem(poolId, scId, 1, investor, USDC);
        shareClass.requestRedeem(poolId, scId, MAX_REQUEST_AMOUNT_SHARES, bytes32("bigPockets"), USDC);
        _mockTotalIssuance(MAX_REQUEST_AMOUNT_SHARES + 1);

        // Approve a few epochs without payout
        for (uint256 i = 0; i < skippedEpochs; i++) {
            shareClass.approveRedeems(poolId, scId, USDC, _nowRedeem(USDC), approvedShares, _pricePoolPerAsset(USDC));
            shareClass.revokeShares(poolId, scId, USDC, _nowRevoke(USDC), navPoolPerShare);
        }

        // Claim all epochs without expected payout due to low redeem amount
        for (uint256 i = 0; i < skippedEpochs; i++) {
            vm.expectEmit();
            emit IShareClassManager.ClaimRedeem(
                poolId, scId, lastUpdate, investor, USDC, 0, 1, 0, block.timestamp.toUint64()
            );
            (uint128 payout, uint128 payment, uint128 cancelled, bool canClaimAgain) =
                shareClass.claimRedeem(poolId, scId, investor, USDC);

            assertEq(payout, 0, "Mismatch: payout");
            assertEq(payment, 0, "Mismatch: payment");
            assertEq(cancelled, 0, "Mismatch: cancelled");
            assertEq(canClaimAgain, i < skippedEpochs - 1, "Mismatch: canClaimAgain");
            lastUpdate += 1;
            _assertRedeemRequestEq(USDC, investor, UserOrder(1, lastUpdate));
        }
    }

    function testClaimRedeemSkippedEpochsNothingRemaining(uint128 amount, uint8 skippedEpochs) public {
        vm.assume(skippedEpochs > 0);

        D18 nonZeroPrice = d18(1e18);
        uint128 redeemShares = uint128(bound(amount, MIN_REQUEST_AMOUNT_SHARES, MAX_REQUEST_AMOUNT_SHARES));
        _mockTotalIssuance(redeemShares + MAX_REQUEST_AMOUNT_USDC);

        // Other investor should eat up the single approved asset amount
        shareClass.requestRedeem(poolId, scId, redeemShares, investor, USDC);
        shareClass.approveRedeems(poolId, scId, USDC, _nowRedeem(USDC), redeemShares, nonZeroPrice);
        shareClass.revokeShares(poolId, scId, USDC, _nowRevoke(USDC), nonZeroPrice);

        // Request redeem with another investors to enable approvals after first epoch
        shareClass.requestRedeem(poolId, scId, MAX_REQUEST_AMOUNT_USDC, bytes32("bigPockets"), USDC);

        // Approve more epochs which should all be skipped when investor claims first epoch
        for (uint256 i = 0; i < skippedEpochs; i++) {
            shareClass.approveRedeems(poolId, scId, USDC, _nowRedeem(USDC), 1, nonZeroPrice);
            shareClass.revokeShares(poolId, scId, USDC, _nowRevoke(USDC), nonZeroPrice);
        }

        // Expect only single claim to be required
        (uint128 payout, uint128 payment, uint128 cancelled, bool canClaimAgain) =
            shareClass.claimRedeem(poolId, scId, investor, USDC);

        assertNotEq(payout, 0, "Mismatch: payout");
        assertEq(payment, redeemShares, "Mismatch: payment");
        assertEq(cancelled, 0, "Mismatch: cancelled");
        assertEq(canClaimAgain, false, "Mismatch: canClaimAgain");
        _assertRedeemRequestEq(USDC, investor, UserOrder(0, 2 + uint32(skippedEpochs)));
    }

    function testClaimRedeemManyEpochs(uint128 navPoolPerShare_, uint128 totalRedeemShares_, uint8 epochs) public {
        D18 poolPerShare = d18(uint128(bound(navPoolPerShare_, 1e15, type(uint128).max / 1e18)));
        epochs = uint8(bound(epochs, 3, 50));
        uint128 totalRedeemShares =
            uint128(bound(totalRedeemShares_, MIN_REQUEST_AMOUNT_SHARES, MAX_REQUEST_AMOUNT_SHARES));
        vm.assume(totalRedeemShares % epochs == 0);

        uint128 epochApprovedShares = totalRedeemShares / epochs;
        uint128 totalAssets = 0;
        uint128 totalPayment = 0;
        uint128 totalPayout = 0;

        _mockTotalIssuance(totalRedeemShares);

        shareClass.requestRedeem(poolId, scId, totalRedeemShares, investor, USDC);

        // Approve + revoke shares for each epoch
        for (uint256 i = 0; i < epochs; i++) {
            shareClass.approveRedeems(
                poolId, scId, USDC, _nowRedeem(USDC), epochApprovedShares, _pricePoolPerAsset(USDC)
            );

            (uint128 revokedShares, uint128 revokedAssetAmount,) =
                shareClass.revokeShares(poolId, scId, USDC, _nowRevoke(USDC), poolPerShare);
            totalAssets += revokedAssetAmount;
            assertEq(revokedShares, epochApprovedShares, "Mismatch: revoked shares");
        }

        assertEq(shareClass.maxRedeemClaims(scId, investor, USDC), epochs);

        for (uint256 i = 0; i < epochs; i++) {
            (uint128 payout, uint128 payment, uint128 cancelled, bool canClaimAgain) =
                shareClass.claimRedeem(poolId, scId, investor, USDC);

            totalPayout += payout;
            totalPayment += payment;
            assertEq(cancelled, 0, "Mismatch: cancelled");
            assertEq(payment, epochApprovedShares, "Mismatch: payment");
            assertEq(canClaimAgain, i < epochs - 1, "Mismatch: canClaimAgain - all claimed");
        }

        assertEq(totalPayment, totalRedeemShares, "Mismatch: Total payment");
        assertEq(totalPayout, totalAssets, "Mismatch: Total payout");

        _assertRedeemRequestEq(USDC, investor, UserOrder(0, epochs + 1));
    }

    function testQueuedRedeemWithoutCancellation(uint128 redeemShares) public {
        redeemShares = uint128(bound(redeemShares, MIN_REQUEST_AMOUNT_SHARES, MAX_REQUEST_AMOUNT_SHARES / 3));
        D18 poolPerShare = d18(1, 1);
        uint128 poolAmount = poolPerShare.mulUint128(redeemShares, MathLib.Rounding.Down);
        uint128 claimedAssetAmount = _intoAssetAmount(USDC, poolAmount);
        uint128 approvedShares = redeemShares;
        uint128 pendingShareAmount = 0;
        uint128 queuedAmount = 0;
        uint32 epochId = 1;

        // Mock total issuance to equal total approved redeem redeemShares
        _mockTotalIssuance(redeemShares);

        // Initial deposit request
        _assertQueuedRedeemRequestEq(USDC, investor, QueuedOrder(false, queuedAmount));
        shareClass.requestRedeem(poolId, scId, redeemShares, investor, USDC);
        _assertRedeemRequestEq(USDC, investor, UserOrder(redeemShares, epochId));
        assertEq(shareClass.pendingRedeem(scId, USDC), redeemShares);
        shareClass.approveRedeems(poolId, scId, USDC, _nowRedeem(USDC), redeemShares, _pricePoolPerAsset(USDC));
        assertEq(shareClass.pendingRedeem(scId, USDC), 0);
        epochId = 2;

        // Expect queued increment due to approval
        queuedAmount += redeemShares;
        vm.expectEmit();
        emit IShareClassManager.UpdateRedeemRequest(
            poolId, scId, USDC, epochId, investor, approvedShares, pendingShareAmount, queuedAmount, false
        );
        shareClass.requestRedeem(poolId, scId, redeemShares, investor, USDC);
        _assertRedeemRequestEq(USDC, investor, UserOrder(queuedAmount, epochId - 1));
        assertEq(shareClass.pendingRedeem(scId, USDC), 0);
        _assertQueuedRedeemRequestEq(USDC, investor, QueuedOrder(false, queuedAmount));
        _assertQueuedDepositRequestEq(USDC, investor, QueuedOrder(false, 0));

        // Expect queued increment due to approval
        queuedAmount += redeemShares;
        vm.expectEmit();
        emit IShareClassManager.UpdateRedeemRequest(
            poolId, scId, USDC, epochId, investor, redeemShares, 0, queuedAmount, false
        );
        shareClass.requestRedeem(poolId, scId, redeemShares, investor, USDC);
        _assertQueuedRedeemRequestEq(USDC, investor, QueuedOrder(false, queuedAmount));

        // Issue shares + claim -> expect queued to move to pending
        shareClass.revokeShares(poolId, scId, USDC, _nowRevoke(USDC), poolPerShare);
        pendingShareAmount = queuedAmount;
        vm.expectEmit();
        emit IShareClassManager.ClaimRedeem(
            poolId, scId, 1, investor, USDC, redeemShares, 0, claimedAssetAmount, block.timestamp.toUint64()
        );
        emit IShareClassManager.UpdateRedeemRequest(
            poolId, scId, USDC, epochId, investor, pendingShareAmount, pendingShareAmount, 0, false
        );
        shareClass.claimRedeem(poolId, scId, investor, USDC);

        _assertRedeemRequestEq(USDC, investor, UserOrder(pendingShareAmount, epochId));
        assertEq(shareClass.pendingRedeem(scId, USDC), pendingShareAmount, "pending redeem mismatch");
        _assertQueuedRedeemRequestEq(USDC, investor, QueuedOrder(false, 0));
        _assertQueuedDepositRequestEq(USDC, investor, QueuedOrder(false, 0));
    }

    function testQueuedRedeemWithNonEmptyQueuedCancellation(uint128 redeemShares) public {
        vm.assume(redeemShares % 2 == 0);
        redeemShares = uint128(bound(redeemShares, MIN_REQUEST_AMOUNT_SHARES, MAX_REQUEST_AMOUNT_SHARES / 2));
        D18 poolPerShare = d18(1, 1);
        uint128 approvedShares = redeemShares / 4;
        uint128 pendingShareAmount = redeemShares - approvedShares;
        uint128 poolAmount = poolPerShare.mulUint128(approvedShares, MathLib.Rounding.Down);
        uint128 revokedAssetAmount = _intoAssetAmount(USDC, poolAmount);
        uint128 queuedAmount = 0;
        uint32 epochId = 1;

        // Mock total issuance to equal total approved redeem redeemShares
        _mockTotalIssuance(approvedShares);

        // Initial deposit request
        shareClass.requestRedeem(poolId, scId, redeemShares, investor, USDC);
        shareClass.approveRedeems(poolId, scId, USDC, _nowRedeem(USDC), approvedShares, _pricePoolPerAsset(USDC));
        epochId = 2;

        // Expect queued increment due to approval
        queuedAmount += redeemShares;
        shareClass.requestRedeem(poolId, scId, redeemShares, investor, USDC);
        vm.expectEmit();
        emit IShareClassManager.UpdateRedeemRequest(
            poolId, scId, USDC, epochId, investor, redeemShares, pendingShareAmount, queuedAmount, true
        );
        (uint128 cancelledPending) = shareClass.cancelRedeemRequest(poolId, scId, investor, USDC);
        assertEq(cancelledPending, 0, "Cancellation queued");

        // Expect revert due to queued cancellation
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.CancellationQueued.selector));
        shareClass.requestRedeem(poolId, scId, 1, investor, USDC);
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.CancellationQueued.selector));
        shareClass.cancelRedeemRequest(poolId, scId, investor, USDC);

        // Issue shares + claim -> expect cancel fulfillment
        shareClass.revokeShares(poolId, scId, USDC, _nowRevoke(USDC), poolPerShare);
        vm.expectEmit();
        emit IShareClassManager.ClaimRedeem(
            poolId,
            scId,
            1,
            investor,
            USDC,
            approvedShares,
            pendingShareAmount,
            revokedAssetAmount,
            block.timestamp.toUint64()
        );
        emit IShareClassManager.UpdateRedeemRequest(poolId, scId, USDC, epochId, investor, 0, 0, 0, false);
        (uint128 claimedAssetAmount, uint128 claimedShareAmount, uint128 cancelledTotal, bool canClaimAgain) =
            shareClass.claimRedeem(poolId, scId, investor, USDC);
        assertEq(claimedAssetAmount, revokedAssetAmount, "Claimed asset amount mismatch");
        assertEq(claimedShareAmount, approvedShares, "Claimed share amount mismatch");
        assertEq(cancelledTotal, pendingShareAmount + queuedAmount, "Cancelled amount mismatch");
        assertEq(canClaimAgain, false, "Can claim again mismatch");

        _assertRedeemRequestEq(USDC, investor, UserOrder(0, epochId));
        assertEq(shareClass.pendingRedeem(scId, USDC), 0, "Pending deposit mismatch");
        _assertQueuedRedeemRequestEq(USDC, investor, QueuedOrder(false, 0));
    }

    function testQueuedRedeemWithEmptyQueuedCancellation(uint128 redeemShares) public {
        vm.assume(redeemShares % 2 == 0);
        redeemShares = uint128(bound(redeemShares, MIN_REQUEST_AMOUNT_SHARES, MAX_REQUEST_AMOUNT_SHARES / 2));
        D18 poolPerShare = d18(1, 1);
        uint128 approvedShares = redeemShares / 4;
        uint128 pendingShareAmount = redeemShares - approvedShares;
        uint128 poolAmount = poolPerShare.mulUint128(approvedShares, MathLib.Rounding.Down);
        uint128 revokedAssetAmount = _intoAssetAmount(USDC, poolAmount);
        uint32 epochId = 1;

        // Mock total issuance to equal total approved redeem redeemShares
        _mockTotalIssuance(approvedShares);

        // Initial redeem request
        shareClass.requestRedeem(poolId, scId, redeemShares, investor, USDC);
        shareClass.approveRedeems(poolId, scId, USDC, _nowRedeem(USDC), approvedShares, _pricePoolPerAsset(USDC));
        epochId = 2;

        // Expect queued increment due to approval
        vm.expectEmit();
        emit IShareClassManager.UpdateRedeemRequest(
            poolId, scId, USDC, epochId, investor, redeemShares, pendingShareAmount, 0, true
        );
        (uint128 cancelledPending) = shareClass.cancelRedeemRequest(poolId, scId, investor, USDC);
        assertEq(cancelledPending, 0, "Cancellation queued");

        // Issue shares + claim -> expect cancel fulfillment
        shareClass.revokeShares(poolId, scId, USDC, _nowRevoke(USDC), poolPerShare);
        vm.expectEmit();
        emit IShareClassManager.ClaimRedeem(
            poolId,
            scId,
            1,
            investor,
            USDC,
            approvedShares,
            pendingShareAmount,
            revokedAssetAmount,
            block.timestamp.toUint64()
        );
        emit IShareClassManager.UpdateRedeemRequest(poolId, scId, USDC, epochId, investor, 0, 0, 0, false);
        (uint128 claimedAssetAmount, uint128 claimedShareAmount, uint128 cancelledTotal, bool canClaimAgain) =
            shareClass.claimRedeem(poolId, scId, investor, USDC);
        assertEq(claimedAssetAmount, revokedAssetAmount, "Claimed share amount mismatch");
        assertEq(claimedShareAmount, approvedShares, "Claimed asset amount mismatch");
        assertEq(cancelledTotal, pendingShareAmount, "Cancelled amount mismatch");
        assertEq(canClaimAgain, false, "Can claim again mismatch");

        _assertRedeemRequestEq(USDC, investor, UserOrder(0, epochId));
        assertEq(shareClass.pendingRedeem(scId, USDC), 0, "Pending redeem mismatch");
        _assertQueuedRedeemRequestEq(USDC, investor, QueuedOrder(false, 0));
    }
}

///@dev Contains all tests which require transient storage to reset between calls
contract ShareClassManagerDepositRedeem is ShareClassManagerBaseTest {
    using MathLib for *;

    function testDepositsWithRedeemsFullFlow(
        uint128 navPerShare_,
        uint128 depositRequestUsdc,
        uint128 redeemRequestShares,
        uint128 depositApprovedUsdc,
        uint128 redeemApprovedShares
    ) public {
        D18 navPerShareDeposit = d18(uint128(bound(navPerShare_, 1e10, type(uint128).max / 1e18)));
        D18 navPerShareRedeem = d18(uint128(bound(navPerShare_, 1e10, navPerShareDeposit.inner())));
        uint128 shares = navPerShareDeposit.reciprocalMulUint128(
            _intoPoolAmount(USDC, MAX_REQUEST_AMOUNT_USDC), MathLib.Rounding.Down
        );
        depositRequestUsdc = uint128(bound(depositRequestUsdc, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC));
        redeemRequestShares = uint128(bound(redeemRequestShares, MIN_REQUEST_AMOUNT_SHARES, shares));
        depositApprovedUsdc = uint128(bound(depositRequestUsdc, MIN_REQUEST_AMOUNT_USDC, depositRequestUsdc));
        redeemApprovedShares = uint128(bound(redeemRequestShares, MIN_REQUEST_AMOUNT_SHARES, redeemRequestShares));

        // Step 1: Do initial deposit flow with 100% deposit approval rate to add sufficient shares for later redemption
        uint32 epochId = 1;
        shareClass.requestDeposit(poolId, scId, MAX_REQUEST_AMOUNT_USDC, investor, USDC);
        shareClass.approveDeposits(poolId, scId, USDC, epochId, MAX_REQUEST_AMOUNT_USDC, _pricePoolPerAsset(USDC));
        shareClass.issueShares(poolId, scId, USDC, epochId, navPerShareDeposit);
        _assertEpochInvestAmountsEq(
            USDC,
            epochId,
            EpochInvestAmounts(
                MAX_REQUEST_AMOUNT_USDC,
                MAX_REQUEST_AMOUNT_USDC,
                _intoPoolAmount(USDC, MAX_REQUEST_AMOUNT_USDC),
                _pricePoolPerAsset(USDC),
                navPerShareDeposit,
                block.timestamp.toUint64()
            )
        );
        shareClass.claimDeposit(poolId, scId, investor, USDC);
        assertEq(_totalIssuance(), shares, "1Mismatch in issuance");

        epochId += 1;
        _assertDepositRequestEq(USDC, investor, UserOrder(0, epochId));

        // Step 2a: Deposit + redeem at same
        shareClass.requestDeposit(poolId, scId, depositRequestUsdc, investor, USDC);
        shareClass.requestRedeem(poolId, scId, redeemRequestShares, investor, USDC);
        _assertDepositRequestEq(USDC, investor, UserOrder(depositRequestUsdc, epochId));
        _assertRedeemRequestEq(USDC, investor, UserOrder(redeemRequestShares, epochId - 1));

        // Step 2b: Approve deposits
        shareClass.approveDeposits(poolId, scId, USDC, epochId, depositApprovedUsdc, _pricePoolPerAsset(USDC));

        // Step 2c: Approve redeems
        shareClass.approveRedeems(poolId, scId, USDC, epochId - 1, redeemApprovedShares, _pricePoolPerAsset(USDC));
        _assertDepositRequestEq(USDC, investor, UserOrder(depositRequestUsdc, epochId));
        _assertRedeemRequestEq(USDC, investor, UserOrder(redeemRequestShares, epochId - 1));

        // Step 2d: Issue shares
        shareClass.issueShares(poolId, scId, USDC, epochId, navPerShareDeposit);
        uint128 depositIssuedShares =
            navPerShareDeposit.reciprocalMulUint128(_intoPoolAmount(USDC, depositRequestUsdc), MathLib.Rounding.Down);
        shares += depositIssuedShares;
        assertEq(_totalIssuance(), shares, "2Mismatch in issuance");

        // Step 2e: Revoke shares
        shareClass.revokeShares(poolId, scId, USDC, epochId - 1, navPerShareRedeem);
        shares -= redeemApprovedShares;
        (uint128 issuance, D18 navPerShare) = shareClass.metrics(scId);
        assertEq(issuance, shares, "Mismatch in metrics issuance");
        assertEq(navPerShare.inner(), 0, "Metrics nav should only be set in updateShareClass");

        // Step 2f: Claim deposit and redeem
        epochId += 1;
        (uint128 depositPayout, uint128 depositPayment,,) = shareClass.claimDeposit(poolId, scId, investor, USDC);
        (, uint128 redeemPayment,,) = shareClass.claimRedeem(poolId, scId, investor, USDC);

        uint128 pendingDeposit = depositRequestUsdc - depositApprovedUsdc;
        assertEq(depositPayment, depositApprovedUsdc, "Mismatch in deposit payment");
        assertEq(depositPayout, depositIssuedShares, "Mismatch in deposit payout");
        _assertDepositRequestEq(USDC, investor, UserOrder(pendingDeposit, epochId));

        uint128 pendingRedeem = redeemRequestShares - redeemApprovedShares;
        assertEq(redeemPayment, redeemApprovedShares, "Mismatch in redeem payment");
        _assertRedeemRequestEq(USDC, investor, UserOrder(pendingRedeem, epochId - 1));
    }
}

///@dev Contains all deposit tests which deal with rounding edge cases
contract ShareClassManagerRoundingEdgeCasesDeposit is ShareClassManagerBaseTest {
    using MathLib for uint128;

    uint128 constant MIN_REQUEST_AMOUNT_OTHER_STABLE = DENO_OTHER_STABLE;
    uint128 constant MAX_REQUEST_AMOUNT_OTHER_STABLE = 1e24;
    bytes32 constant INVESTOR_A = bytes32("investorA");
    bytes32 constant INVESTOR_B = bytes32("investorB");
    bytes32 constant INVESTOR_C = bytes32("investorC");

    function _approveAllDepositsAndIssue(uint128 approvedAssetAmount, uint128 expectedShareIssuance, D18 navPerShare)
        private
    {
        shareClass.approveDeposits(
            poolId, scId, OTHER_STABLE, _nowDeposit(OTHER_STABLE), approvedAssetAmount, _pricePoolPerAsset(OTHER_STABLE)
        );
        shareClass.issueShares(poolId, scId, OTHER_STABLE, _nowIssue(OTHER_STABLE), navPerShare);
        assertEq(_totalIssuance(), expectedShareIssuance, "Mismatch in expected shares");
    }

    /// @dev Investors cannot claim the single issued share atom (one of smallest denomination of share) but still pay
    function testClaimDepositSingleShareAtom() public {
        uint128 approvedAssetAmount = DENO_OTHER_STABLE;
        uint128 issuedShares = 1;
        uint128 depositAmountA = 1;
        uint128 depositAmountB = approvedAssetAmount - depositAmountA;
        D18 navPerShare = d18(_intoPoolAmount(OTHER_STABLE, approvedAssetAmount), issuedShares);

        shareClass.requestDeposit(poolId, scId, depositAmountA, INVESTOR_A, OTHER_STABLE);
        shareClass.requestDeposit(poolId, scId, depositAmountB, INVESTOR_B, OTHER_STABLE);
        _approveAllDepositsAndIssue(approvedAssetAmount, issuedShares, navPerShare);

        (uint128 claimedA, uint128 paymentA, uint128 cancelledA,) =
            shareClass.claimDeposit(poolId, scId, INVESTOR_A, OTHER_STABLE);
        (uint128 claimedB, uint128 paymentB, uint128 cancelledB,) =
            shareClass.claimDeposit(poolId, scId, INVESTOR_B, OTHER_STABLE);

        assertEq(claimedA, claimedB, "Claimed shares should be equal");
        assertEq(claimedA + claimedB + 1, issuedShares, "System should have 1 share class token atom surplus");
        assertEq(paymentA, depositAmountA, "Payment A should never be zero");
        assertEq(paymentB, depositAmountB, "Payment B should never be zero");
        assertEq(cancelledA + cancelledB, 0, "No queued cancellation");
        assertEq(shareClass.pendingDeposit(scId, OTHER_STABLE), 0, "Pending deposit should be zero");

        _assertDepositRequestEq(OTHER_STABLE, INVESTOR_A, UserOrder(0, 2));
        _assertDepositRequestEq(OTHER_STABLE, INVESTOR_B, UserOrder(0, 2));
    }

    /// @dev Investors can claim 50% rounded down of an uneven number of shares => 1 share atom surplus in system
    function testClaimDepositEvenInvestorsUnevenClaimable() public {
        uint128 approvedAssetAmount = 100 * DENO_OTHER_STABLE;
        uint128 issuedShares = 11;
        uint128 depositAmountA = 49 * approvedAssetAmount / 100;
        uint128 depositAmountB = 51 * approvedAssetAmount / 100;
        D18 navPerShare = d18(_intoPoolAmount(OTHER_STABLE, approvedAssetAmount), issuedShares);

        shareClass.requestDeposit(poolId, scId, depositAmountA, INVESTOR_A, OTHER_STABLE);
        shareClass.requestDeposit(poolId, scId, depositAmountB, INVESTOR_B, OTHER_STABLE);
        _approveAllDepositsAndIssue(approvedAssetAmount, issuedShares, navPerShare);

        (uint128 claimedA, uint128 paymentA, uint128 cancelledA,) =
            shareClass.claimDeposit(poolId, scId, INVESTOR_A, OTHER_STABLE);
        (uint128 claimedB, uint128 paymentB, uint128 cancelledB,) =
            shareClass.claimDeposit(poolId, scId, INVESTOR_B, OTHER_STABLE);

        assertEq(claimedA, claimedB, "Claimed shares should be equal");
        assertEq(claimedA + claimedB + 1, issuedShares, "System should have 1 share class token atom surplus");
        assertEq(paymentA, depositAmountA, "Payment A should never be zero");
        assertEq(paymentB, depositAmountB, "Payment B should never be zero");
        assertEq(cancelledA + cancelledB, 0, "No queued cancellation");
    }

    /// @dev Investors can claim 1/3 of an even number of shares => 1 share atom surplus in system
    function testClaimDepositUnevenInvestorsEvenClaimable() public {
        uint128 approvedAssetAmount = 100 * DENO_OTHER_STABLE;
        uint128 issuedShares = 10;
        uint128 depositAmountA = 30 * approvedAssetAmount / 100;
        uint128 depositAmountB = 31 * approvedAssetAmount / 100;
        uint128 depositAmountC = 39 * approvedAssetAmount / 100;
        D18 navPerShare = d18(_intoPoolAmount(OTHER_STABLE, approvedAssetAmount), issuedShares);

        shareClass.requestDeposit(poolId, scId, depositAmountA, INVESTOR_A, OTHER_STABLE);
        shareClass.requestDeposit(poolId, scId, depositAmountB, INVESTOR_B, OTHER_STABLE);
        shareClass.requestDeposit(poolId, scId, depositAmountC, INVESTOR_C, OTHER_STABLE);
        _approveAllDepositsAndIssue(approvedAssetAmount, issuedShares, navPerShare);

        (uint128 claimedA, uint128 paymentA, uint128 cancelledA,) =
            shareClass.claimDeposit(poolId, scId, INVESTOR_A, OTHER_STABLE);
        (uint128 claimedB, uint128 paymentB, uint128 cancelledB,) =
            shareClass.claimDeposit(poolId, scId, INVESTOR_B, OTHER_STABLE);
        (uint128 claimedC, uint128 paymentC, uint128 cancelledC,) =
            shareClass.claimDeposit(poolId, scId, INVESTOR_C, OTHER_STABLE);

        assertEq(claimedA, claimedB, "Claimed shares should be equal");
        assertEq(claimedB, claimedC, "Claimed shares should be equal");
        assertEq(
            claimedA + claimedB + claimedC + 1, issuedShares, "System should have 1 share class token atom surplus"
        );
        assertEq(paymentA, depositAmountA, "Payment A should never be zero");
        assertEq(paymentB, depositAmountB, "Payment B should never be zero");
        assertEq(paymentC, depositAmountC, "Payment C should never be zero");
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

    uint128 constant TOTAL_ISSUANCE = 1000 * DENO_POOL;

    // 100 OTHER_STABLE = 1 POOL leads to max OTHER_STABLE precision of 100
    // NOTE: If 1 OTHER_STABLE equalled 100 POOL, max OTHER_STABLE precision would be 1
    // This originates from the price conversion which does base * exponentQuote / exponentBase
    uint128 constant MAX_OTHER_STABLE_PRECISION = OTHER_STABLE_PER_POOL;

    function setUp() public override {
        ShareClassManagerBaseTest.setUp();

        _mockTotalIssuance(TOTAL_ISSUANCE);
    }

    function _approveAllRedeemsAndRevoke(uint128 approvedShares, uint128 expectedAssetPayout, D18 navPerShare)
        private
    {
        shareClass.approveRedeems(
            poolId, scId, OTHER_STABLE, _nowRedeem(OTHER_STABLE), approvedShares, _pricePoolPerAsset(OTHER_STABLE)
        );
        (, uint128 assetPayout,) =
            shareClass.revokeShares(poolId, scId, OTHER_STABLE, _nowRevoke(OTHER_STABLE), navPerShare);
        assertEq(_totalIssuance(), TOTAL_ISSUANCE - approvedShares, "Mismatch in expected shares");
        assertEq(shareClass.pendingRedeem(scId, OTHER_STABLE), 0, "Pending redeem should have decreased");
        assertEq(assetPayout, expectedAssetPayout, "Mismatch in expected asset payout");
    }

    /// @dev Investors cannot claim anything despite non-zero pending amounts
    function testClaimRedeemSingleAssetAtom() public {
        uint128 approvedShares = DENO_POOL / DENO_OTHER_STABLE; // 1e6
        uint128 assetPayout = MAX_OTHER_STABLE_PRECISION; // 100
        uint128 redeemAmountA = 1;
        uint128 redeemAmountB = approvedShares - redeemAmountA;
        uint128 poolPayout = _intoPoolAmount(OTHER_STABLE, assetPayout); // 1
        D18 navPerShare = d18(poolPayout, approvedShares); // = 1e18

        shareClass.requestRedeem(poolId, scId, redeemAmountA, INVESTOR_A, OTHER_STABLE);
        shareClass.requestRedeem(poolId, scId, redeemAmountB, INVESTOR_B, OTHER_STABLE);
        _approveAllRedeemsAndRevoke(approvedShares, assetPayout, navPerShare);

        (uint128 claimedA, uint128 paymentA,,) = shareClass.claimRedeem(poolId, scId, INVESTOR_A, OTHER_STABLE);
        (uint128 claimedB, uint128 paymentB,,) = shareClass.claimRedeem(poolId, scId, INVESTOR_B, OTHER_STABLE);

        assertEq(claimedA, claimedB, "Both investors should have claimed same amount");
        assertEq(claimedA + claimedB, 0, "Claimed amount should be zero for both investors");
        assertEq(paymentA, redeemAmountA, "Payment A should never be zero");
        assertEq(paymentB, redeemAmountB, "Payment B should never be zero");
        assertEq(shareClass.pendingRedeem(scId, OTHER_STABLE), 0, "Pending redeem should be zero");

        _assertRedeemRequestEq(OTHER_STABLE, INVESTOR_A, UserOrder(0, 2));
        _assertRedeemRequestEq(OTHER_STABLE, INVESTOR_B, UserOrder(0, 2));
    }

    /// @dev Investors can claim 50% rounded down of an uneven number of asset amount => asset amount surplus in
    /// system
    function testClaimRedeemEvenInvestorsUnevenClaimable() public {
        uint128 approvedShares = DENO_POOL / DENO_OTHER_STABLE;
        uint128 assetPayout = 11 * MAX_OTHER_STABLE_PRECISION; // 1100
        uint128 redeemAmountA = 49 * approvedShares / 100;
        uint128 redeemAmountB = 51 * approvedShares / 100;
        uint128 poolPayout = _intoPoolAmount(OTHER_STABLE, assetPayout); // 11
        D18 navPerShare = d18(poolPayout, approvedShares);

        shareClass.requestRedeem(poolId, scId, redeemAmountA, INVESTOR_A, OTHER_STABLE);
        shareClass.requestRedeem(poolId, scId, redeemAmountB, INVESTOR_B, OTHER_STABLE);
        _approveAllRedeemsAndRevoke(approvedShares, assetPayout, navPerShare);

        (uint128 claimedA, uint128 paymentA, uint128 cancelledA,) =
            shareClass.claimRedeem(poolId, scId, INVESTOR_A, OTHER_STABLE);
        (uint128 claimedB, uint128 paymentB, uint128 cancelledB,) =
            shareClass.claimRedeem(poolId, scId, INVESTOR_B, OTHER_STABLE);

        assertEq(claimedA, claimedB, "Claimed asset amount should be equal");
        assertEq(
            claimedA + claimedB + 1 * MAX_OTHER_STABLE_PRECISION,
            assetPayout,
            "System should have 1 max asset precision amount surplus"
        );
        assertEq(paymentA, redeemAmountA, "Payment A should never be zero");
        assertEq(paymentB, redeemAmountB, "Payment B should never be zero");
        assertEq(shareClass.pendingRedeem(scId, OTHER_STABLE), 0, "Pending redeem should not have reset");
        assertEq(cancelledA + cancelledB, 0, "No queued cancellation");

        _assertRedeemRequestEq(OTHER_STABLE, INVESTOR_A, UserOrder(0, 2));
        _assertRedeemRequestEq(OTHER_STABLE, INVESTOR_B, UserOrder(0, 2));
    }

    /// @dev Investors can claim 50% rounded down of an uneven number of asset amount =>  asset amount surplus in
    /// system
    function testClaimRedeemUnevenInvestorsEvenClaimable() public {
        uint128 approvedShares = DENO_POOL / DENO_OTHER_STABLE;
        uint128 assetPayout = 10 * MAX_OTHER_STABLE_PRECISION; // 1000
        uint128 redeemAmountA = 30 * approvedShares / 100;
        uint128 redeemAmountB = 31 * approvedShares / 100;
        uint128 redeemAmountC = 39 * approvedShares / 100;
        uint128 poolPayout = _intoPoolAmount(OTHER_STABLE, assetPayout); // 10
        D18 navPerShare = d18(poolPayout, approvedShares);

        shareClass.requestRedeem(poolId, scId, redeemAmountA, INVESTOR_A, OTHER_STABLE);
        shareClass.requestRedeem(poolId, scId, redeemAmountB, INVESTOR_B, OTHER_STABLE);
        shareClass.requestRedeem(poolId, scId, redeemAmountC, INVESTOR_C, OTHER_STABLE);
        _approveAllRedeemsAndRevoke(approvedShares, assetPayout, navPerShare);

        (uint128 claimedA, uint128 paymentA,,) = shareClass.claimRedeem(poolId, scId, INVESTOR_A, OTHER_STABLE);
        (uint128 claimedB, uint128 paymentB,,) = shareClass.claimRedeem(poolId, scId, INVESTOR_B, OTHER_STABLE);
        (uint128 claimedC, uint128 paymentC,,) = shareClass.claimRedeem(poolId, scId, INVESTOR_C, OTHER_STABLE);

        assertEq(claimedA, claimedB, "Claimed asset amount should be equal");
        assertEq(claimedB, claimedC, "Claimed asset amount should be equal");
        assertEq(
            claimedA + claimedB + claimedC + 1 * MAX_OTHER_STABLE_PRECISION,
            assetPayout,
            "System should have 1 max asset precision amount surplus"
        );
        assertEq(paymentA, redeemAmountA, "Payment A should never be zero");
        assertEq(paymentB, redeemAmountB, "Payment B should never be zero");
        assertEq(paymentC, redeemAmountC, "Payment C should never be zero");
        assertEq(shareClass.pendingRedeem(scId, OTHER_STABLE), 0, "Pending redeem should not have reset");

        _assertRedeemRequestEq(OTHER_STABLE, INVESTOR_A, UserOrder(0, 2));
        _assertRedeemRequestEq(OTHER_STABLE, INVESTOR_B, UserOrder(0, 2));
        _assertRedeemRequestEq(OTHER_STABLE, INVESTOR_C, UserOrder(0, 2));
    }
}

///@dev Contains all tests which are expected to revert
contract ShareClassManagerRevertsTest is ShareClassManagerBaseTest {
    using MathLib for uint128;

    ShareClassId wrongShareClassId = ShareClassId.wrap(bytes16((uint128(POOL_ID) << 64) + 42));
    address unauthorized = makeAddr("unauthorizedAddress");
    uint32 epochId = 1;

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
        shareClass.approveDeposits(poolId, wrongShareClassId, USDC, epochId, 1, d18(1, 1));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        shareClass.approveDeposits(poolId, wrongShareClassId, USDC, epochId, 1, d18(1, 1));
    }

    function testApproveRedeemsWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassNotFound.selector));
        shareClass.approveRedeems(poolId, wrongShareClassId, USDC, epochId, 1, _pricePoolPerAsset(USDC));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        shareClass.approveRedeems(poolId, wrongShareClassId, USDC, epochId, 1, _pricePoolPerAsset(USDC));
    }

    function testIssueSharesWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassNotFound.selector));
        shareClass.issueShares(poolId, wrongShareClassId, USDC, epochId, d18(1));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        shareClass.issueShares(poolId, wrongShareClassId, USDC, epochId, d18(1));
    }

    function testRevokeSharesWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassNotFound.selector));
        shareClass.revokeShares(poolId, wrongShareClassId, USDC, epochId, d18(1));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        shareClass.revokeShares(poolId, wrongShareClassId, USDC, epochId, d18(1));
    }

    function testClaimDepositWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassNotFound.selector));
        shareClass.claimDeposit(poolId, wrongShareClassId, investor, USDC);
    }

    function testClaimRedeemWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassNotFound.selector));
        shareClass.claimRedeem(poolId, wrongShareClassId, investor, USDC);
    }

    function testUpdatePricePerShareWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassNotFound.selector));
        shareClass.updatePricePerShare(poolId, wrongShareClassId, d18(1));
    }

    function testUpdateMetadataWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassNotFound.selector));
        shareClass.updateMetadata(poolId, wrongShareClassId, "", "");
    }

    function testIncreaseIssuanceWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassNotFound.selector));
        shareClass.increaseShareClassIssuance(poolId, wrongShareClassId, 0);
    }

    function testDecreaseIssuanceWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassNotFound.selector));
        shareClass.decreaseShareClassIssuance(poolId, wrongShareClassId, 0);
    }

    function testDecreaseOverFlow() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.DecreaseMoreThanIssued.selector));
        shareClass.decreaseShareClassIssuance(poolId, scId, 1);
    }

    function testIssueSharesBeforeApproval() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.EpochNotFound.selector));
        shareClass.issueShares(poolId, scId, USDC, epochId + 1, d18(1));
    }

    function testRevokeSharesBeforeApproval() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.EpochNotFound.selector));
        shareClass.revokeShares(poolId, scId, USDC, epochId + 1, d18(1));
    }

    function testRequestDepositRequiresClaim() public {
        shareClass.requestDeposit(poolId, scId, 1, investor, USDC);
        shareClass.approveDeposits(poolId, scId, USDC, epochId, 1, d18(1, 1));
        shareClass.cancelDepositRequest(poolId, scId, investor, USDC);

        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.CancellationQueued.selector));
        shareClass.requestDeposit(poolId, scId, 1, investor, USDC);
    }

    function testRequestRedeemCancellationQueued() public {
        shareClass.requestRedeem(poolId, scId, 1, investor, USDC);
        shareClass.approveRedeems(poolId, scId, USDC, epochId, 1, _pricePoolPerAsset(USDC));
        shareClass.cancelRedeemRequest(poolId, scId, investor, USDC);

        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.CancellationQueued.selector));
        shareClass.requestRedeem(poolId, scId, 1, investor, USDC);
    }

    function testApproveDepositsZeroPending() public {
        vm.expectRevert(IShareClassManager.InsufficientPending.selector);
        shareClass.approveDeposits(poolId, scId, USDC, epochId, 1, d18(1, 1));
    }

    function testApproveDepositsZeroApproval() public {
        shareClass.requestDeposit(poolId, scId, 1, investor, USDC);

        vm.expectRevert(IShareClassManager.ZeroApprovalAmount.selector);
        shareClass.approveDeposits(poolId, scId, USDC, epochId, 0, d18(0));
    }

    function testApproveRedeemsZeroApproval() public {
        shareClass.requestRedeem(poolId, scId, 1, investor, USDC);

        vm.expectRevert(IShareClassManager.ZeroApprovalAmount.selector);
        shareClass.approveRedeems(poolId, scId, USDC, epochId, 0, _pricePoolPerAsset(USDC));
    }

    function testApproveRedeemsZeroPending() public {
        vm.expectRevert(IShareClassManager.InsufficientPending.selector);
        shareClass.approveRedeems(poolId, scId, USDC, epochId, 1, _pricePoolPerAsset(USDC));
    }

    function testAddShareClassInvalidNameEmpty() public {
        vm.expectRevert(IShareClassManager.InvalidMetadataName.selector);
        shareClass.addShareClass(PoolId.wrap(POOL_ID + 1), "", SC_SYMBOL, SC_SALT);
    }

    function testAddShareClassInvalidNameExcess() public {
        vm.expectRevert(IShareClassManager.InvalidMetadataName.selector);
        shareClass.addShareClass(PoolId.wrap(POOL_ID + 1), string(new bytes(129)), SC_SYMBOL, SC_SALT);
    }

    function testAddShareClassInvalidSymbolEmpty() public {
        vm.expectRevert(IShareClassManager.InvalidMetadataSymbol.selector);
        shareClass.addShareClass(PoolId.wrap(POOL_ID + 1), SC_NAME, "", SC_SALT);
    }

    function testAddShareClassInvalidSymbolExcess() public {
        vm.expectRevert(IShareClassManager.InvalidMetadataSymbol.selector);
        shareClass.addShareClass(PoolId.wrap(POOL_ID + 1), SC_NAME, string(new bytes(33)), SC_SALT);
    }

    function testAddShareClassEmptySalt() public {
        vm.expectRevert(IShareClassManager.InvalidSalt.selector);
        shareClass.addShareClass(PoolId.wrap(POOL_ID + 1), SC_NAME, SC_SYMBOL, bytes32(0));
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
        shareClass.updateMetadata(poolId, scId, string(new bytes(129)), SC_SYMBOL);
    }

    function testUpdateMetadataClassInvalidSymbolEmpty() public {
        vm.expectRevert(IShareClassManager.InvalidMetadataSymbol.selector);
        shareClass.updateMetadata(poolId, scId, SC_NAME, "");
    }

    function testUpdateMetadataClassInvalidSymbolExcess() public {
        vm.expectRevert(IShareClassManager.InvalidMetadataSymbol.selector);
        shareClass.updateMetadata(poolId, scId, SC_NAME, string(new bytes(33)));
    }

    function testApproveDepositEpochNotInSequence() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.EpochNotInSequence.selector, 3, 1));
        shareClass.approveDeposits(poolId, scId, USDC, 3, 0, d18(0));
    }

    function testApproveRedeemEpochNotInSequence() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.EpochNotInSequence.selector, 3, 1));
        shareClass.approveRedeems(poolId, scId, USDC, 3, 0, d18(0));
    }

    function testIssueSharesEpochNotInSequence() public {
        shareClass.requestDeposit(poolId, scId, 1000, investor, USDC);
        shareClass.approveDeposits(poolId, scId, USDC, 1, 500, d18(1e18));
        shareClass.approveDeposits(poolId, scId, USDC, 2, 500, d18(1e18));

        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.EpochNotInSequence.selector, 2, 1));
        shareClass.issueShares(poolId, scId, USDC, 2, d18(0));
    }

    function testRevokeSharesEpochNotInSequence() public {
        _mockTotalIssuance(1000);
        shareClass.requestRedeem(poolId, scId, 1000, investor, USDC);
        shareClass.approveRedeems(poolId, scId, USDC, 1, 500, d18(1e18));
        shareClass.approveRedeems(poolId, scId, USDC, 2, 500, d18(1e18));

        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.EpochNotInSequence.selector, 2, 1));
        shareClass.revokeShares(poolId, scId, USDC, 2, d18(0));
    }

    function testClaimDepositEpochNotFound() public {
        vm.expectRevert(IShareClassManager.NoOrderFound.selector);
        shareClass.claimDeposit(poolId, scId, investor, USDC);
    }

    function testClaimRedeemEpochNotFound() public {
        vm.expectRevert(IShareClassManager.NoOrderFound.selector);
        shareClass.claimRedeem(poolId, scId, investor, USDC);
    }

    function testClaimDepositIssuanceRequired() public {
        _mockTotalIssuance(1000);
        shareClass.requestDeposit(poolId, scId, 1000, investor, USDC);
        shareClass.approveDeposits(poolId, scId, USDC, 1, 500, d18(1e18));
        shareClass.issueShares(poolId, scId, USDC, 1, d18(1e18));

        bytes32 investor2 = bytes32("investor2");
        shareClass.requestDeposit(poolId, scId, 1000, investor2, USDC);

        vm.expectRevert(IShareClassManager.IssuanceRequired.selector);
        shareClass.claimDeposit(poolId, scId, investor2, USDC);
    }

    function testClaimRedeemRevocationRequired() public {
        _mockTotalIssuance(1000);
        shareClass.requestRedeem(poolId, scId, 1000, investor, USDC);
        shareClass.approveRedeems(poolId, scId, USDC, 1, 500, d18(1e18));
        shareClass.revokeShares(poolId, scId, USDC, 1, d18(1e18));

        bytes32 investor2 = bytes32("investor2");
        shareClass.requestRedeem(poolId, scId, 1000, investor2, USDC);

        vm.expectRevert(IShareClassManager.RevocationRequired.selector);
        shareClass.claimRedeem(poolId, scId, investor2, USDC);
    }
}
