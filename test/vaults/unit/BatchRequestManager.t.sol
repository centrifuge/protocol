// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {D18, d18} from "../../../src/misc/types/D18.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";
import {MathLib} from "../../../src/misc/libraries/MathLib.sol";

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {AssetId} from "../../../src/common/types/AssetId.sol";
import {PricingLib} from "../../../src/common/libraries/PricingLib.sol";
import {ShareClassId} from "../../../src/common/types/ShareClassId.sol";
import {IHubGatewayHandler} from "../../../src/common/interfaces/IGatewayHandlers.sol";

import {IHubRegistry} from "../../../src/hub/interfaces/IHubRegistry.sol";
import {IHubRequestManagerCallback} from "../../../src/hub/interfaces/IHubRequestManagerCallback.sol";

import {BatchRequestManager} from "../../../src/vaults/BatchRequestManager.sol";
import {
    IBatchRequestManager,
    EpochInvestAmounts,
    EpochRedeemAmounts,
    UserOrder,
    QueuedOrder,
    RequestType,
    EpochId
} from "../../../src/vaults/interfaces/IBatchRequestManager.sol";

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
uint128 constant SHARE_HOOK_GAS = 100000;

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

    function hubRequestManager(PoolId, uint16) external pure returns (address) {
        return address(0);
    }
}

contract HubMock is IHubGatewayHandler, IHubRequestManagerCallback {
    uint256 public totalCost;

    function requestCallback(PoolId, ShareClassId, AssetId, bytes calldata, uint128) external returns (uint256) {
        uint256 cost = 1000; // Mock cost
        totalCost += cost;
        return cost;
    }

    // Required implementations for IHubGatewayHandler
    function registerAsset(AssetId, uint8) external override {}

    function request(PoolId, ShareClassId, AssetId, bytes calldata) external override {}

    function updateHoldingAmount(uint16, PoolId, ShareClassId, AssetId, uint128, D18, bool, bool, uint64)
        external
        override
    {}

    function initiateTransferShares(uint16, uint16, PoolId, ShareClassId, bytes32, uint128, uint128)
        external
        override
        returns (uint256)
    {}

    function updateShares(uint16, PoolId, ShareClassId, uint128, bool, bool, uint64) external override {}
}

contract BatchRequestManagerHarness is BatchRequestManager {
    constructor(IHubRegistry hubRegistry_, address deployer) BatchRequestManager(hubRegistry_, deployer) {}

    function claimDeposit(PoolId poolId, ShareClassId scId_, bytes32 investor, AssetId depositAssetId)
        public
        returns (
            uint128 payoutShareAmount,
            uint128 paymentAssetAmount,
            uint128 cancelledAssetAmount,
            bool canClaimAgain
        )
    {
        return _claimDeposit(poolId, scId_, investor, depositAssetId);
    }

    function claimRedeem(PoolId poolId, ShareClassId scId_, bytes32 investor, AssetId payoutAssetId)
        public
        returns (
            uint128 payoutAssetAmount,
            uint128 paymentShareAmount,
            uint128 cancelledShareAmount,
            bool canClaimAgain
        )
    {
        return _claimRedeem(poolId, scId_, investor, payoutAssetId);
    }
}

abstract contract BatchRequestManagerBaseTest is Test {
    using MathLib for uint128;
    using MathLib for uint256;
    using CastLib for string;
    using PricingLib for *;

    BatchRequestManagerHarness public batchRequestManager;
    HubRegistryMock public hubRegistryMock;
    HubMock public hubMock;

    uint16 centrifugeId = 1;
    PoolId poolId = PoolId.wrap(POOL_ID);
    ShareClassId scId = SC_ID;
    bytes32 investor = bytes32("investor");

    modifier notThisContract(address addr) {
        vm.assume(address(this) != addr);
        _;
    }

    function setUp() public virtual {
        hubRegistryMock = new HubRegistryMock();
        hubMock = new HubMock();
        batchRequestManager = new BatchRequestManagerHarness(IHubRegistry(address(hubRegistryMock)), address(this));

        // Set the hub address
        batchRequestManager.file("hub", address(hubMock));

        assertEq(IHubRegistry(address(hubRegistryMock)).decimals(poolId), DECIMALS_POOL);
        assertEq(IHubRegistry(address(hubRegistryMock)).decimals(USDC), DECIMALS_USDC);
        assertEq(IHubRegistry(address(hubRegistryMock)).decimals(OTHER_STABLE), DECIMALS_OTHER_STABLE);
    }

    function _intoPoolAmount(AssetId assetId, uint128 amount) internal view returns (uint128) {
        return PricingLib.convertWithPrice(
            amount,
            IHubRegistry(address(hubRegistryMock)).decimals(assetId),
            IHubRegistry(address(hubRegistryMock)).decimals(poolId),
            _pricePoolPerAsset(assetId)
        );
    }

    function _intoAssetAmount(AssetId assetId, uint128 amount) internal view returns (uint128) {
        return PricingLib.convertWithPrice(
            amount,
            IHubRegistry(address(hubRegistryMock)).decimals(poolId),
            IHubRegistry(address(hubRegistryMock)).decimals(assetId),
            _pricePoolPerAsset(assetId).reciprocal()
        );
    }

    function _calcSharesIssued(AssetId assetId, uint128 depositAmountAsset, D18 pricePoolPerShare)
        internal
        view
        returns (uint128)
    {
        return pricePoolPerShare.reciprocalMulUint256(
                PricingLib.convertWithPrice(
                    depositAmountAsset,
                    IHubRegistry(address(hubRegistryMock)).decimals(assetId),
                    IHubRegistry(address(hubRegistryMock)).decimals(poolId),
                    _pricePoolPerAsset(assetId)
                ),
                MathLib.Rounding.Down
            ).toUint128();
    }

    function _pricePoolPerAsset(AssetId assetId) internal pure returns (D18) {
        if (assetId == USDC) {
            return d18(1, 1);
        } else if (assetId == OTHER_STABLE) {
            return d18(1, OTHER_STABLE_PER_POOL);
        } else {
            revert("BatchRequestManagerBaseTest._priceAssetPerPool() - Unknown assetId");
        }
    }

    function _assertDepositRequestEq(AssetId asset, bytes32 investor_, UserOrder memory expected) internal view {
        (uint128 pending, uint32 lastUpdate) = batchRequestManager.depositRequest(scId, asset, investor_);

        assertEq(pending, expected.pending, "Mismatch: Deposit UserOrder.pending");
        assertEq(lastUpdate, expected.lastUpdate, "Mismatch: Deposit UserOrder.lastUpdate");
    }

    function _assertQueuedDepositRequestEq(AssetId asset, bytes32 investor_, QueuedOrder memory expected)
        internal
        view
    {
        (bool isCancelling, uint128 amount) = batchRequestManager.queuedDepositRequest(scId, asset, investor_);

        assertEq(isCancelling, expected.isCancelling, "isCancelling deposit mismatch");
        assertEq(amount, expected.amount, "amount deposit mismatch");
    }

    function _assertRedeemRequestEq(AssetId asset, bytes32 investor_, UserOrder memory expected) internal view {
        (uint128 pending, uint32 lastUpdate) = batchRequestManager.redeemRequest(scId, asset, investor_);

        assertEq(pending, expected.pending, "Mismatch: Redeem UserOrder.pending");
        assertEq(lastUpdate, expected.lastUpdate, "Mismatch: Redeem UserOrder.lastUpdate");
    }

    function _assertQueuedRedeemRequestEq(AssetId asset, bytes32 investor_, QueuedOrder memory expected) internal view {
        (bool isCancelling, uint128 amount) = batchRequestManager.queuedRedeemRequest(scId, asset, investor_);

        assertEq(isCancelling, expected.isCancelling, "isCancelling redeem mismatch");
        assertEq(amount, expected.amount, "amount redeem mismatch");
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
        ) = batchRequestManager.epochInvestAmounts(scId, assetId, epochId);

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
            uint128 approvedShareAmount,
            uint128 pendingShareAmount,
            D18 pricePoolPerAsset,
            D18 navPoolPerShare,
            uint128 payoutAssetAmount,
            uint64 revokedAt
        ) = batchRequestManager.epochRedeemAmounts(scId, assetId, epochId);

        assertEq(approvedShareAmount, expected.approvedShareAmount, "Mismatch: EpochRedeemAmount.approvedShareAmount");
        assertEq(pendingShareAmount, expected.pendingShareAmount, "Mismatch: EpochRedeemAmount.pendingShareAmount");
        assertEq(payoutAssetAmount, expected.payoutAssetAmount, "Mismatch: EpochRedeemAmount.payoutAssetAmount");
        assertEq(
            pricePoolPerAsset.raw(), expected.pricePoolPerAsset.raw(), "Mismatch: EpochRedeemAmount.pricePoolPerAsset"
        );
        assertEq(navPoolPerShare.raw(), expected.navPoolPerShare.raw(), "Mismatch: EpochRedeemAmount.navPoolPerShare");
        assertEq(revokedAt, expected.revokedAt, "Mismatch: EpochRedeemAmount.revokedAt");
    }

    function _nowDeposit(AssetId assetId) internal view returns (uint32) {
        return batchRequestManager.nowDepositEpoch(scId, assetId);
    }

    function _nowIssue(AssetId assetId) internal view returns (uint32) {
        return batchRequestManager.nowIssueEpoch(scId, assetId);
    }

    function _nowRedeem(AssetId assetId) internal view returns (uint32) {
        return batchRequestManager.nowRedeemEpoch(scId, assetId);
    }

    function _nowRevoke(AssetId assetId) internal view returns (uint32) {
        return batchRequestManager.nowRevokeEpoch(scId, assetId);
    }
}

///@dev Contains all simple tests which are expected to succeed
contract BatchRequestManagerSimpleTest is BatchRequestManagerBaseTest {
    using MathLib for uint128;
    using CastLib for string;

    function testInitialValues() public view {
        assertEq(batchRequestManager.nowDepositEpoch(scId, USDC), 1);
        assertEq(batchRequestManager.nowRedeemEpoch(scId, USDC), 1);
        assertEq(batchRequestManager.nowIssueEpoch(scId, USDC), 1);
        assertEq(batchRequestManager.nowRevokeEpoch(scId, USDC), 1);
    }

    function testMaxDepositClaims() public {
        assertEq(batchRequestManager.maxDepositClaims(scId, investor, USDC), 0);

        batchRequestManager.requestDeposit(poolId, scId, 1, investor, USDC);
        assertEq(batchRequestManager.maxDepositClaims(scId, investor, USDC), 0);
    }

    function testMaxRedeemClaims() public {
        assertEq(batchRequestManager.maxRedeemClaims(scId, investor, USDC), 0);

        batchRequestManager.requestRedeem(poolId, scId, 1, investor, USDC);
        assertEq(batchRequestManager.maxRedeemClaims(scId, investor, USDC), 0);
    }

    function testEpochViews() public view {
        // Test that epoch view functions return expected initial values
        assertEq(_nowDeposit(USDC), 1);
        assertEq(_nowIssue(USDC), 1);
        assertEq(_nowRedeem(USDC), 1);
        assertEq(_nowRevoke(USDC), 1);
    }

    function testMaxClaims() public view {
        // Test that max claims start at zero
        assertEq(batchRequestManager.maxDepositClaims(scId, investor, USDC), 0);
        assertEq(batchRequestManager.maxRedeemClaims(scId, investor, USDC), 0);
    }
}

///@dev Contains all deposit related tests which are expected to succeed and don't make use of transient storage
contract BatchRequestManagerDepositsNonTransientTest is BatchRequestManagerBaseTest {
    using MathLib for *;

    function _deposit(uint128 depositAmountUsdc_, uint128 approvedAmountUsdc_)
        internal
        returns (uint128 depositAmountUsdc, uint128 approvedAmountUsdc, uint128 approvedPool)
    {
        depositAmountUsdc = uint128(bound(depositAmountUsdc_, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC));
        approvedAmountUsdc = uint128(bound(approvedAmountUsdc_, MIN_REQUEST_AMOUNT_USDC - 1, depositAmountUsdc));
        approvedPool = _intoPoolAmount(USDC, approvedAmountUsdc);

        batchRequestManager.requestDeposit(poolId, scId, depositAmountUsdc, investor, USDC);
        batchRequestManager.approveDeposits(
            poolId, scId, USDC, _nowDeposit(USDC), approvedAmountUsdc, _pricePoolPerAsset(USDC)
        );
    }

    function testRequestDeposit(uint128 amount) public {
        amount = uint128(bound(amount, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC));

        assertEq(batchRequestManager.pendingDeposit(scId, USDC), 0);
        _assertDepositRequestEq(USDC, investor, UserOrder(0, 0));

        vm.expectEmit();
        emit IBatchRequestManager.UpdateDepositRequest(
            poolId, scId, USDC, batchRequestManager.nowDepositEpoch(scId, USDC), investor, amount, amount, 0, false
        );
        batchRequestManager.requestDeposit(poolId, scId, amount, investor, USDC);

        assertEq(batchRequestManager.pendingDeposit(scId, USDC), amount);
        _assertDepositRequestEq(USDC, investor, UserOrder(amount, 1));
    }

    function testCancelDepositRequest(uint128 amount) public {
        amount = uint128(bound(amount, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC));
        batchRequestManager.requestDeposit(poolId, scId, amount, investor, USDC);

        vm.expectEmit();
        emit IBatchRequestManager.UpdateDepositRequest(
            poolId, scId, USDC, batchRequestManager.nowDepositEpoch(scId, USDC), investor, 0, 0, 0, false
        );
        (uint128 cancelledShares) = batchRequestManager.cancelDepositRequest(poolId, scId, investor, USDC);

        assertEq(cancelledShares, amount);
        assertEq(batchRequestManager.pendingDeposit(scId, USDC), 0);
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
            batchRequestManager.requestDeposit(poolId, scId, investorDeposit, investor, USDC);

            assertEq(batchRequestManager.pendingDeposit(scId, USDC), deposits);
        }

        assertEq(_nowDeposit(USDC), 1);

        vm.expectEmit();
        emit IBatchRequestManager.ApproveDeposits(
            poolId,
            scId,
            USDC,
            _nowDeposit(USDC),
            _intoPoolAmount(USDC, approvedUsdc),
            approvedUsdc,
            deposits - approvedUsdc
        );
        uint256 cost = batchRequestManager.approveDeposits(
            poolId, scId, USDC, _nowDeposit(USDC), approvedUsdc, _pricePoolPerAsset(USDC)
        );
        assertEq(cost, 1000, "Should return callback cost");

        assertEq(batchRequestManager.pendingDeposit(scId, USDC), deposits - approvedUsdc);

        // Only one epoch should have passed
        assertEq(_nowDeposit(USDC), 2);

        // Note: Epoch state is tracked internally and tested through other assertions
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

        batchRequestManager.requestDeposit(poolId, scId, depositAmountUsdc, investorUsdc, USDC);
        batchRequestManager.requestDeposit(poolId, scId, depositAmountOther, investorOther, OTHER_STABLE);

        assertEq(_nowDeposit(USDC), 1);
        assertEq(_nowDeposit(OTHER_STABLE), 1);

        batchRequestManager.approveDeposits(
            poolId, scId, USDC, _nowDeposit(USDC), approvedUsdc, _pricePoolPerAsset(USDC)
        );
        batchRequestManager.approveDeposits(
            poolId, scId, OTHER_STABLE, _nowDeposit(OTHER_STABLE), approvedOtherStable, _pricePoolPerAsset(OTHER_STABLE)
        );

        assertEq(_nowDeposit(USDC), 2);
        assertEq(_nowDeposit(OTHER_STABLE), 2);

        // Note: Epoch state is tracked internally and tested through other assertions
    }

    function testIssueSharesSingleEpoch(
        uint128 navPoolPerShare_,
        uint128 fuzzDepositAmountUsdc,
        uint128 fuzzApprovedAmountUsdc
    ) public {
        D18 navPoolPerShare = d18(uint128(bound(navPoolPerShare_, 1e14, type(uint128).max / 1e18)));
        _deposit(fuzzDepositAmountUsdc, fuzzApprovedAmountUsdc);

        uint256 cost =
            batchRequestManager.issueShares(poolId, scId, USDC, _nowIssue(USDC), navPoolPerShare, SHARE_HOOK_GAS);
        assertEq(cost, 1000, "Should return callback cost");

        // Note: Epoch state is tracked internally and tested through other assertions
    }

    function testClaimDepositZeroApproved() public {
        batchRequestManager.requestDeposit(poolId, scId, 1, investor, USDC);
        batchRequestManager.requestDeposit(poolId, scId, 10, bytes32("investorOther"), USDC);
        batchRequestManager.approveDeposits(poolId, scId, USDC, _nowDeposit(USDC), 1, d18(1));

        batchRequestManager.issueShares(poolId, scId, USDC, _nowIssue(USDC), d18(1), SHARE_HOOK_GAS);

        vm.expectEmit();
        emit IBatchRequestManager.ClaimDeposit(poolId, scId, 1, investor, USDC, 0, 1, 0, block.timestamp.toUint64());
        batchRequestManager.claimDeposit(poolId, scId, investor, USDC);
    }

    function testFullClaimDepositSingleEpoch() public {
        uint128 approvedAmountUsdc = 100 * DENO_USDC;
        uint128 depositAmountUsdc = approvedAmountUsdc;
        uint128 approvedPool = _intoPoolAmount(USDC, approvedAmountUsdc);
        assertEq(approvedPool, 100 * DENO_POOL);

        batchRequestManager.requestDeposit(poolId, scId, depositAmountUsdc, investor, USDC);
        batchRequestManager.approveDeposits(
            poolId, scId, USDC, _nowDeposit(USDC), approvedAmountUsdc, _pricePoolPerAsset(USDC)
        );

        vm.expectRevert(IBatchRequestManager.IssuanceRequired.selector);
        batchRequestManager.claimDeposit(poolId, scId, investor, USDC);

        D18 navPoolPerShare = d18(11, 10);
        batchRequestManager.issueShares(poolId, scId, USDC, _nowIssue(USDC), navPoolPerShare, SHARE_HOOK_GAS);

        uint128 expectedShares = _calcSharesIssued(USDC, approvedAmountUsdc, navPoolPerShare);

        vm.expectEmit();
        emit IBatchRequestManager.ClaimDeposit(
            poolId,
            scId,
            1,
            investor,
            USDC,
            approvedAmountUsdc,
            depositAmountUsdc - approvedAmountUsdc,
            expectedShares,
            block.timestamp.toUint64()
        );
        (uint128 payoutShareAmount, uint128 depositAssetAmount, uint128 cancelledAssetAmount, bool canClaimAgain) =
            batchRequestManager.claimDeposit(poolId, scId, investor, USDC);

        assertEq(expectedShares, payoutShareAmount, "Mismatch: payoutShareAmount");
        assertEq(approvedAmountUsdc, depositAssetAmount, "Mismatch: depositAssetAmount");
        assertEq(0, cancelledAssetAmount, "Mismatch: cancelledAssetAmount");
        assertEq(false, canClaimAgain, "Mismatch: canClaimAgain");

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

        vm.expectRevert(IBatchRequestManager.IssuanceRequired.selector);
        batchRequestManager.claimDeposit(poolId, scId, investor, USDC);

        batchRequestManager.issueShares(poolId, scId, USDC, _nowIssue(USDC), navPoolPerShare, SHARE_HOOK_GAS);

        uint128 expectedShares = _calcSharesIssued(USDC, approvedAmountUsdc, navPoolPerShare);

        vm.expectEmit();
        emit IBatchRequestManager.ClaimDeposit(
            poolId,
            scId,
            1,
            investor,
            USDC,
            approvedAmountUsdc,
            depositAmountUsdc - approvedAmountUsdc,
            expectedShares,
            block.timestamp.toUint64()
        );
        (uint128 payoutShareAmount, uint128 depositAssetAmount, uint128 cancelledAssetAmount, bool canClaimAgain) =
            batchRequestManager.claimDeposit(poolId, scId, investor, USDC);

        assertEq(expectedShares, payoutShareAmount, "Mismatch: payoutShareAmount");
        assertEq(approvedAmountUsdc, depositAssetAmount, "Mismatch: depositAssetAmount");
        assertEq(0, cancelledAssetAmount, "Mismatch: cancelledAssetAmount");
        assertEq(false, canClaimAgain, "Mismatch: canClaimAgain");

        _assertDepositRequestEq(USDC, investor, UserOrder(depositAmountUsdc - approvedAmountUsdc, 2));
    }

    function testForceCancelDepositRequestZeroPending() public {
        batchRequestManager.cancelDepositRequest(poolId, scId, investor, USDC);

        vm.expectEmit();
        emit IBatchRequestManager.UpdateDepositRequest(poolId, scId, USDC, 1, investor, 0, 0, 0, false);
        uint256 cancelledAmount = batchRequestManager.forceCancelDepositRequest(poolId, scId, investor, USDC);

        assertEq(cancelledAmount, 0, "Cancelled amount should be zero");
        assertEq(
            batchRequestManager.allowForceDepositCancel(scId, USDC, investor),
            true,
            "Cancellation flag should not be reset"
        );

        // Verify the investor can make new requests after force cancellation
        batchRequestManager.requestDeposit(poolId, scId, 1, investor, USDC);
        assertEq(
            batchRequestManager.pendingDeposit(scId, USDC), 1, "Should be able to make new deposits after force cancel"
        );
    }

    function testForceCancelDepositRequestImmediate(uint128 depositAmount) public {
        depositAmount = uint128(bound(depositAmount, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC));

        // Set allowForceDepositCancel to true (initialize cancellation)
        batchRequestManager.cancelDepositRequest(poolId, scId, investor, USDC);

        // Submit a deposit request, which will be applied since pending is zero
        batchRequestManager.requestDeposit(poolId, scId, depositAmount, investor, USDC);

        // Force cancel before approval -> expect instant cancellation
        vm.expectEmit();
        emit IBatchRequestManager.UpdateDepositRequest(poolId, scId, USDC, _nowDeposit(USDC), investor, 0, 0, 0, false);
        uint256 cancelledAmount = batchRequestManager.forceCancelDepositRequest(poolId, scId, investor, USDC);

        // Verify cancellation was immediate and not queued
        // Note: forceCancelDepositRequest returns callback cost, not cancelled amount
        assertEq(cancelledAmount, 1000, "Should return callback cost");
        assertEq(
            batchRequestManager.allowForceDepositCancel(scId, USDC, investor),
            true,
            "Cancellation flag should not be reset"
        );
        assertEq(batchRequestManager.pendingDeposit(scId, USDC), 0, "Pending deposit should be zero after force cancel");
        _assertDepositRequestEq(USDC, investor, UserOrder(0, 1));

        // Verify the investor can make new requests after force cancellation
        batchRequestManager.requestDeposit(poolId, scId, depositAmount, investor, USDC);
        _assertDepositRequestEq(USDC, investor, UserOrder(depositAmount, 1));
    }
}

///@dev Contains all redeem related tests which are expected to succeed and don't make use of transient storage
contract BatchRequestManagerRedeemsNonTransientTest is BatchRequestManagerBaseTest {
    using MathLib for *;

    function _redeem(uint128 redeemShares_, uint128 approvedShares_, uint128 navPerShare)
        internal
        returns (uint128 redeemShares, uint128 approvedShares, uint128 approvedPool, D18 poolPerShare)
    {
        redeemShares = uint128(bound(redeemShares_, MIN_REQUEST_AMOUNT_SHARES, MAX_REQUEST_AMOUNT_SHARES));
        approvedShares = uint128(bound(approvedShares_, MIN_REQUEST_AMOUNT_SHARES, redeemShares));
        poolPerShare = d18(uint128(bound(navPerShare, 1e15, type(uint128).max / 1e18)));
        approvedPool = poolPerShare.mulUint128(approvedShares, MathLib.Rounding.Down);

        batchRequestManager.requestRedeem(poolId, scId, redeemShares, investor, USDC);
        batchRequestManager.approveRedeems(
            poolId, scId, USDC, _nowRedeem(USDC), approvedShares, _pricePoolPerAsset(USDC)
        );
    }

    function testRequestRedeem(uint128 amount) public {
        amount = uint128(bound(amount, MIN_REQUEST_AMOUNT_SHARES, MAX_REQUEST_AMOUNT_SHARES));

        assertEq(batchRequestManager.pendingRedeem(scId, USDC), 0);
        _assertRedeemRequestEq(USDC, investor, UserOrder(0, 0));

        vm.expectEmit();
        emit IBatchRequestManager.UpdateRedeemRequest(
            poolId, scId, USDC, batchRequestManager.nowRedeemEpoch(scId, USDC), investor, amount, amount, 0, false
        );
        batchRequestManager.requestRedeem(poolId, scId, amount, investor, USDC);

        assertEq(batchRequestManager.pendingRedeem(scId, USDC), amount);
        _assertRedeemRequestEq(USDC, investor, UserOrder(amount, 1));
    }

    function testCancelRedeemRequest(uint128 amount) public {
        amount = uint128(bound(amount, MIN_REQUEST_AMOUNT_SHARES, MAX_REQUEST_AMOUNT_SHARES));
        batchRequestManager.requestRedeem(poolId, scId, amount, investor, USDC);

        vm.expectEmit();
        emit IBatchRequestManager.UpdateRedeemRequest(
            poolId, scId, USDC, batchRequestManager.nowRedeemEpoch(scId, USDC), investor, 0, 0, 0, false
        );
        (uint128 cancelledShares) = batchRequestManager.cancelRedeemRequest(poolId, scId, investor, USDC);

        assertEq(cancelledShares, amount);
        assertEq(batchRequestManager.pendingRedeem(scId, USDC), 0);
        _assertRedeemRequestEq(USDC, investor, UserOrder(0, 1));
    }

    function testApproveRedeemsSingleAssetManyInvestors(
        uint8 numInvestors,
        uint128 redeemAmount,
        uint128 approvedShares
    ) public {
        numInvestors = uint8(bound(numInvestors, 1, 100));
        redeemAmount = uint128(bound(redeemAmount, MIN_REQUEST_AMOUNT_SHARES, MAX_REQUEST_AMOUNT_SHARES));
        approvedShares = uint128(bound(approvedShares, 1, numInvestors * redeemAmount));

        uint128 redeems = 0;
        for (uint16 i = 0; i < numInvestors; i++) {
            bytes32 investor = bytes32(uint256(keccak256(abi.encodePacked("investor_", i))));
            uint128 investorRedeem = redeemAmount + i;
            redeems += investorRedeem;
            batchRequestManager.requestRedeem(poolId, scId, investorRedeem, investor, USDC);

            assertEq(batchRequestManager.pendingRedeem(scId, USDC), redeems);
        }

        assertEq(_nowRedeem(USDC), 1);

        vm.expectEmit();
        emit IBatchRequestManager.ApproveRedeems(
            poolId, scId, USDC, _nowRedeem(USDC), approvedShares, redeems - approvedShares
        );
        batchRequestManager.approveRedeems(
            poolId, scId, USDC, _nowRedeem(USDC), approvedShares, _pricePoolPerAsset(USDC)
        );

        assertEq(batchRequestManager.pendingRedeem(scId, USDC), redeems - approvedShares);

        // Only one epoch should have passed
        assertEq(_nowRedeem(USDC), 2);

        // Note: Epoch state is tracked internally and tested through other assertions
    }

    function testRevokeSharesSingleEpoch(
        uint128 navPoolPerShare_,
        uint128 fuzzRedeemShares,
        uint128 fuzzApprovedShares
    ) public {
        D18 navPoolPerShare = d18(uint128(bound(navPoolPerShare_, 1e14, type(uint128).max / 1e18)));
        _redeem(fuzzRedeemShares, fuzzApprovedShares, navPoolPerShare.raw());

        uint256 cost =
            batchRequestManager.revokeShares(poolId, scId, USDC, _nowRevoke(USDC), navPoolPerShare, SHARE_HOOK_GAS);
        assertEq(cost, 1000, "Should return callback cost");

        // Note: Epoch state is tracked internally and tested through other assertions
    }

    function testClaimRedeemZeroApproved() public {
        batchRequestManager.requestRedeem(poolId, scId, 1, investor, USDC);
        batchRequestManager.requestRedeem(poolId, scId, 10, bytes32("investorOther"), USDC);
        batchRequestManager.approveRedeems(poolId, scId, USDC, _nowRedeem(USDC), 1, d18(1));

        batchRequestManager.revokeShares(poolId, scId, USDC, _nowRevoke(USDC), d18(1), SHARE_HOOK_GAS);

        vm.expectEmit();
        emit IBatchRequestManager.ClaimRedeem(poolId, scId, 1, investor, USDC, 0, 1, 0, block.timestamp.toUint64());
        batchRequestManager.claimRedeem(poolId, scId, investor, USDC);
    }

    function testFullClaimRedeemSingleEpoch() public {
        uint128 approvedShares = 100 * DENO_POOL;
        uint128 redeemShares = approvedShares;
        D18 navPoolPerShare = d18(11, 10);

        batchRequestManager.requestRedeem(poolId, scId, redeemShares, investor, USDC);
        batchRequestManager.approveRedeems(
            poolId, scId, USDC, _nowRedeem(USDC), approvedShares, _pricePoolPerAsset(USDC)
        );

        vm.expectRevert(IBatchRequestManager.RevocationRequired.selector);
        batchRequestManager.claimRedeem(poolId, scId, investor, USDC);

        batchRequestManager.revokeShares(poolId, scId, USDC, _nowRevoke(USDC), navPoolPerShare, SHARE_HOOK_GAS);

        uint128 expectedAssetAmount =
            _intoAssetAmount(USDC, navPoolPerShare.mulUint128(approvedShares, MathLib.Rounding.Down));

        vm.expectEmit();
        emit IBatchRequestManager.ClaimRedeem(
            poolId,
            scId,
            1,
            investor,
            USDC,
            approvedShares,
            redeemShares - approvedShares,
            expectedAssetAmount,
            block.timestamp.toUint64()
        );
        (uint128 payoutAssetAmount, uint128 redeemShareAmount, uint128 cancelledShareAmount, bool canClaimAgain) =
            batchRequestManager.claimRedeem(poolId, scId, investor, USDC);

        assertEq(expectedAssetAmount, payoutAssetAmount, "Mismatch: payoutAssetAmount");
        assertEq(approvedShares, redeemShareAmount, "Mismatch: redeemShareAmount");
        assertEq(0, cancelledShareAmount, "Mismatch: cancelledShareAmount");
        assertEq(false, canClaimAgain, "Mismatch: canClaimAgain");

        _assertRedeemRequestEq(USDC, investor, UserOrder(redeemShares - approvedShares, 2));
    }

    function testForceCancelRedeemRequestZeroPending() public {
        batchRequestManager.cancelRedeemRequest(poolId, scId, investor, USDC);

        vm.expectEmit();
        emit IBatchRequestManager.UpdateRedeemRequest(poolId, scId, USDC, 1, investor, 0, 0, 0, false);
        uint256 cancelledAmount = batchRequestManager.forceCancelRedeemRequest(poolId, scId, investor, USDC);

        assertEq(cancelledAmount, 0, "Cancelled amount should be zero");
        assertEq(
            batchRequestManager.allowForceRedeemCancel(scId, USDC, investor),
            true,
            "Cancellation flag should not be reset"
        );

        // Verify the investor can make new requests after force cancellation
        batchRequestManager.requestRedeem(poolId, scId, 1, investor, USDC);
        assertEq(
            batchRequestManager.pendingRedeem(scId, USDC), 1, "Should be able to make new redeems after force cancel"
        );
    }

    function testForceCancelRedeemRequestImmediate(uint128 redeemAmount) public {
        redeemAmount = uint128(bound(redeemAmount, MIN_REQUEST_AMOUNT_SHARES, MAX_REQUEST_AMOUNT_SHARES));

        // Set allowForceRedeemCancel to true (initialize cancellation)
        batchRequestManager.cancelRedeemRequest(poolId, scId, investor, USDC);

        // Submit a redeem request, which will be applied since pending is zero
        batchRequestManager.requestRedeem(poolId, scId, redeemAmount, investor, USDC);

        // Force cancel before approval -> expect instant cancellation
        vm.expectEmit();
        emit IBatchRequestManager.UpdateRedeemRequest(poolId, scId, USDC, _nowRedeem(USDC), investor, 0, 0, 0, false);
        uint256 cancelledAmount = batchRequestManager.forceCancelRedeemRequest(poolId, scId, investor, USDC);

        // Verify cancellation was immediate and not queued
        // Note: forceCancelRedeemRequest returns callback cost, not cancelled amount
        assertEq(cancelledAmount, 1000, "Should return callback cost");
        assertEq(
            batchRequestManager.allowForceRedeemCancel(scId, USDC, investor),
            true,
            "Cancellation flag should not be reset"
        );
        assertEq(batchRequestManager.pendingRedeem(scId, USDC), 0, "Pending redeem should be zero after force cancel");
        _assertRedeemRequestEq(USDC, investor, UserOrder(0, 1));

        // Verify the investor can make new requests after force cancellation
        batchRequestManager.requestRedeem(poolId, scId, redeemAmount, investor, USDC);
        _assertRedeemRequestEq(USDC, investor, UserOrder(redeemAmount, 1));
    }
}

///@dev Contains all deposit tests dealing with queued requests and complex epoch management
contract BatchRequestManagerQueuedDepositsTest is BatchRequestManagerBaseTest {
    using MathLib for *;

    function testQueuedDepositWithoutCancellation(uint128 depositAmountUsdc) public {
        depositAmountUsdc = uint128(bound(depositAmountUsdc, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC / 3));
        uint32 epochId = 1;
        D18 poolPerShare = d18(1, 1);
        uint128 claimedShares = _calcSharesIssued(USDC, depositAmountUsdc, poolPerShare);
        uint128 queuedAmount = 0;

        // Initial deposit request
        _assertQueuedDepositRequestEq(USDC, investor, QueuedOrder(false, queuedAmount));
        batchRequestManager.requestDeposit(poolId, scId, depositAmountUsdc, investor, USDC);
        _assertDepositRequestEq(USDC, investor, UserOrder(depositAmountUsdc, epochId));
        assertEq(batchRequestManager.pendingDeposit(scId, USDC), depositAmountUsdc);
        batchRequestManager.approveDeposits(
            poolId, scId, USDC, _nowDeposit(USDC), depositAmountUsdc, _pricePoolPerAsset(USDC)
        );
        epochId = 2;

        // Expect queued increment due to approval
        queuedAmount += depositAmountUsdc;
        vm.expectEmit();
        emit IBatchRequestManager.UpdateDepositRequest(
            poolId, scId, USDC, epochId, investor, depositAmountUsdc, 0, queuedAmount, false
        );
        batchRequestManager.requestDeposit(poolId, scId, depositAmountUsdc, investor, USDC);
        _assertDepositRequestEq(USDC, investor, UserOrder(queuedAmount, epochId - 1));
        assertEq(batchRequestManager.pendingDeposit(scId, USDC), 0);
        _assertQueuedDepositRequestEq(USDC, investor, QueuedOrder(false, queuedAmount));
        _assertQueuedRedeemRequestEq(USDC, investor, QueuedOrder(false, 0));

        // Expect queued increment due to approval
        queuedAmount += depositAmountUsdc;
        vm.expectEmit();
        emit IBatchRequestManager.UpdateDepositRequest(
            poolId, scId, USDC, epochId, investor, depositAmountUsdc, 0, queuedAmount, false
        );
        batchRequestManager.requestDeposit(poolId, scId, depositAmountUsdc, investor, USDC);
        _assertQueuedDepositRequestEq(USDC, investor, QueuedOrder(false, queuedAmount));

        // Issue shares + claim -> expect queued to move to pending
        batchRequestManager.issueShares(poolId, scId, USDC, _nowIssue(USDC), poolPerShare, SHARE_HOOK_GAS);
        vm.expectEmit();
        emit IBatchRequestManager.ClaimDeposit(
            poolId, scId, 1, investor, USDC, depositAmountUsdc, 0, claimedShares, block.timestamp.toUint64()
        );
        emit IBatchRequestManager.UpdateDepositRequest(
            poolId, scId, USDC, epochId, investor, queuedAmount, queuedAmount, 0, false
        );
        batchRequestManager.claimDeposit(poolId, scId, investor, USDC);

        _assertDepositRequestEq(USDC, investor, UserOrder(queuedAmount, epochId));
        assertEq(batchRequestManager.pendingDeposit(scId, USDC), queuedAmount);
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
        batchRequestManager.requestDeposit(poolId, scId, depositAmountUsdc, investor, USDC);
        batchRequestManager.approveDeposits(
            poolId, scId, USDC, _nowDeposit(USDC), approvedAssetAmount, _pricePoolPerAsset(USDC)
        );

        // Expect queued increment due to approval
        epochId = 2;
        queuedAmount += depositAmountUsdc;
        batchRequestManager.requestDeposit(poolId, scId, depositAmountUsdc, investor, USDC);
        vm.expectEmit();
        emit IBatchRequestManager.UpdateDepositRequest(
            poolId, scId, USDC, epochId, investor, depositAmountUsdc, pendingAssetAmount, queuedAmount, true
        );
        (uint128 cancelledPending) = batchRequestManager.cancelDepositRequest(poolId, scId, investor, USDC);
        assertEq(cancelledPending, 0, "Cancellation queued (returns cancelled amount, 0 when queued)");

        // Expect revert due to queued cancellation
        vm.expectRevert(abi.encodeWithSelector(IBatchRequestManager.CancellationQueued.selector));
        batchRequestManager.requestDeposit(poolId, scId, 1, investor, USDC);
        vm.expectRevert(abi.encodeWithSelector(IBatchRequestManager.CancellationQueued.selector));
        batchRequestManager.cancelDepositRequest(poolId, scId, investor, USDC);

        // Issue shares + claim -> expect cancel fulfillment
        batchRequestManager.issueShares(poolId, scId, USDC, _nowIssue(USDC), poolPerShare, SHARE_HOOK_GAS);
        vm.expectEmit();
        emit IBatchRequestManager.ClaimDeposit(
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
        emit IBatchRequestManager.UpdateDepositRequest(poolId, scId, USDC, epochId, investor, 0, 0, 0, false);
        (uint128 claimedShareAmount, uint128 claimedAssetAmount, uint128 cancelledTotal, bool canClaimAgain) =
            batchRequestManager.claimDeposit(poolId, scId, investor, USDC);
        assertEq(claimedShareAmount, issuedShares, "Claimed share amount mismatch");
        assertEq(claimedAssetAmount, approvedAssetAmount, "Claimed asset amount mismatch");
        assertEq(cancelledTotal, pendingAssetAmount + queuedAmount, "Cancelled amount mismatch");
        assertEq(canClaimAgain, false, "Can claim again mismatch");

        _assertDepositRequestEq(USDC, investor, UserOrder(0, epochId));
        assertEq(batchRequestManager.pendingDeposit(scId, USDC), 0, "Pending deposit mismatch");
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
        batchRequestManager.requestDeposit(poolId, scId, depositAmountUsdc, investor, USDC);
        batchRequestManager.approveDeposits(
            poolId, scId, USDC, _nowDeposit(USDC), approvedAssetAmount, _pricePoolPerAsset(USDC)
        );
        epochId = 2;

        // Expect queued increment due to approval
        vm.expectEmit();
        emit IBatchRequestManager.UpdateDepositRequest(
            poolId, scId, USDC, epochId, investor, depositAmountUsdc, pendingAssetAmount, 0, true
        );
        (uint128 cancelledPending) = batchRequestManager.cancelDepositRequest(poolId, scId, investor, USDC);
        assertEq(cancelledPending, 0, "Cancellation queued (returns cancelled amount, 0 when queued)");

        // Issue shares + claim -> expect cancel fulfillment
        batchRequestManager.issueShares(poolId, scId, USDC, _nowIssue(USDC), poolPerShare, SHARE_HOOK_GAS);
        vm.expectEmit();
        emit IBatchRequestManager.ClaimDeposit(
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
        emit IBatchRequestManager.UpdateDepositRequest(poolId, scId, USDC, epochId, investor, 0, 0, 0, false);
        (uint128 claimedShareAmount, uint128 claimedAssetAmount, uint128 cancelledTotal, bool canClaimAgain) =
            batchRequestManager.claimDeposit(poolId, scId, investor, USDC);
        assertEq(claimedShareAmount, issuedShares, "Claimed share amount mismatch");
        assertEq(claimedAssetAmount, approvedAssetAmount, "Claimed asset amount mismatch");
        assertEq(cancelledTotal, pendingAssetAmount, "Cancelled amount mismatch");
        assertEq(canClaimAgain, false, "Can claim again mismatch");

        _assertDepositRequestEq(USDC, investor, UserOrder(0, epochId));
        assertEq(batchRequestManager.pendingDeposit(scId, USDC), 0, "Pending deposit mismatch");
        _assertQueuedDepositRequestEq(USDC, investor, QueuedOrder(false, 0));
        _assertQueuedRedeemRequestEq(USDC, investor, QueuedOrder(false, 0));
    }

    function testForceCancelDepositRequestQueued(uint128 depositAmount, uint128 approvedAmount) public {
        depositAmount = uint128(bound(depositAmount, MIN_REQUEST_AMOUNT_USDC + 1, MAX_REQUEST_AMOUNT_USDC));
        approvedAmount = uint128(bound(approvedAmount, MIN_REQUEST_AMOUNT_USDC, depositAmount - 1));
        uint128 queuedCancelAmount = depositAmount - approvedAmount;

        // Set allowForceDepositCancel to true
        batchRequestManager.cancelDepositRequest(poolId, scId, investor, USDC);

        // Submit a deposit request, which will be applied since pending is zero
        batchRequestManager.requestDeposit(poolId, scId, depositAmount, investor, USDC);
        batchRequestManager.approveDeposits(
            poolId, scId, USDC, _nowDeposit(USDC), approvedAmount, _pricePoolPerAsset(USDC)
        );
        batchRequestManager.issueShares(poolId, scId, USDC, _nowIssue(USDC), d18(1, 1), SHARE_HOOK_GAS);

        vm.expectEmit();
        emit IBatchRequestManager.UpdateDepositRequest(
            poolId, scId, USDC, _nowDeposit(USDC), investor, depositAmount, queuedCancelAmount, 0, true
        );
        uint256 forceCancelAmount = batchRequestManager.forceCancelDepositRequest(poolId, scId, investor, USDC);

        // Verify post force cancel cleanup pre claiming
        assertEq(forceCancelAmount, 0, "Cancellation was queued (returns 0 when queued, callback only when immediate)");
        assertEq(
            batchRequestManager.allowForceDepositCancel(scId, USDC, investor),
            true,
            "Cancellation flag should not be reset"
        );

        // Claim to trigger cancellation
        (uint128 depositPayout, uint128 depositPayment, uint128 cancelledDeposit, bool canClaimAgain) =
            batchRequestManager.claimDeposit(poolId, scId, investor, USDC);
        assertNotEq(depositPayout, 0, "Deposit payout mismatch");
        assertEq(depositPayment, approvedAmount, "Deposit payment mismatch");
        assertEq(cancelledDeposit, queuedCancelAmount, "Cancelled deposit mismatch");
        assertEq(canClaimAgain, false, "Can claim again mismatch");

        // Verify post claiming cleanup
        assertEq(batchRequestManager.pendingDeposit(scId, USDC), 0, "Pending deposit should be zero after force cancel");
        _assertDepositRequestEq(USDC, investor, UserOrder(0, 2));

        // Verify the investor can make new requests after force cancellation
        batchRequestManager.requestDeposit(poolId, scId, depositAmount, investor, USDC);
        _assertDepositRequestEq(USDC, investor, UserOrder(depositAmount, 2));
    }
}

///@dev Contains all redeem tests dealing with queued requests and complex epoch management
contract BatchRequestManagerQueuedRedeemsTest is BatchRequestManagerBaseTest {
    using MathLib for *;

    function testQueuedRedeemWithoutCancellation(uint128 redeemShares) public {
        redeemShares = uint128(bound(redeemShares, MIN_REQUEST_AMOUNT_SHARES, MAX_REQUEST_AMOUNT_SHARES / 3));
        D18 poolPerShare = d18(1, 1);
        uint128 poolAmount = poolPerShare.mulUint128(redeemShares, MathLib.Rounding.Down);
        uint128 claimedAssetAmount = _intoAssetAmount(USDC, poolAmount);
        uint128 approvedShares = redeemShares;
        uint128 pendingShareAmount = 0;
        uint128 queuedAmount = 0;
        uint32 epochId = 1;

        // Initial redeem request
        _assertQueuedRedeemRequestEq(USDC, investor, QueuedOrder(false, queuedAmount));
        batchRequestManager.requestRedeem(poolId, scId, redeemShares, investor, USDC);
        _assertRedeemRequestEq(USDC, investor, UserOrder(redeemShares, epochId));
        assertEq(batchRequestManager.pendingRedeem(scId, USDC), redeemShares);
        batchRequestManager.approveRedeems(poolId, scId, USDC, _nowRedeem(USDC), redeemShares, _pricePoolPerAsset(USDC));
        assertEq(batchRequestManager.pendingRedeem(scId, USDC), 0);
        epochId = 2;

        // Expect queued increment due to approval
        queuedAmount += redeemShares;
        vm.expectEmit();
        emit IBatchRequestManager.UpdateRedeemRequest(
            poolId, scId, USDC, epochId, investor, approvedShares, pendingShareAmount, queuedAmount, false
        );
        batchRequestManager.requestRedeem(poolId, scId, redeemShares, investor, USDC);
        _assertRedeemRequestEq(USDC, investor, UserOrder(queuedAmount, epochId - 1));
        assertEq(batchRequestManager.pendingRedeem(scId, USDC), 0);
        _assertQueuedRedeemRequestEq(USDC, investor, QueuedOrder(false, queuedAmount));
        _assertQueuedDepositRequestEq(USDC, investor, QueuedOrder(false, 0));

        // Expect queued increment due to approval
        queuedAmount += redeemShares;
        vm.expectEmit();
        emit IBatchRequestManager.UpdateRedeemRequest(
            poolId, scId, USDC, epochId, investor, redeemShares, 0, queuedAmount, false
        );
        batchRequestManager.requestRedeem(poolId, scId, redeemShares, investor, USDC);
        _assertQueuedRedeemRequestEq(USDC, investor, QueuedOrder(false, queuedAmount));

        // Revoke shares + claim -> expect queued to move to pending
        batchRequestManager.revokeShares(poolId, scId, USDC, _nowRevoke(USDC), poolPerShare, SHARE_HOOK_GAS);
        pendingShareAmount = queuedAmount;
        vm.expectEmit();
        emit IBatchRequestManager.ClaimRedeem(
            poolId, scId, 1, investor, USDC, redeemShares, 0, claimedAssetAmount, block.timestamp.toUint64()
        );
        emit IBatchRequestManager.UpdateRedeemRequest(
            poolId, scId, USDC, epochId, investor, pendingShareAmount, pendingShareAmount, 0, false
        );
        batchRequestManager.claimRedeem(poolId, scId, investor, USDC);

        _assertRedeemRequestEq(USDC, investor, UserOrder(pendingShareAmount, epochId));
        assertEq(batchRequestManager.pendingRedeem(scId, USDC), pendingShareAmount, "pending redeem mismatch");
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

        // Initial redeem request
        batchRequestManager.requestRedeem(poolId, scId, redeemShares, investor, USDC);
        batchRequestManager.approveRedeems(
            poolId, scId, USDC, _nowRedeem(USDC), approvedShares, _pricePoolPerAsset(USDC)
        );
        epochId = 2;

        // Expect queued increment due to approval
        queuedAmount += redeemShares;
        batchRequestManager.requestRedeem(poolId, scId, redeemShares, investor, USDC);
        vm.expectEmit();
        emit IBatchRequestManager.UpdateRedeemRequest(
            poolId, scId, USDC, epochId, investor, redeemShares, pendingShareAmount, queuedAmount, true
        );
        (uint128 cancelledPending) = batchRequestManager.cancelRedeemRequest(poolId, scId, investor, USDC);
        assertEq(cancelledPending, 0, "Cancellation queued (returns cancelled amount, 0 when queued)");

        // Expect revert due to queued cancellation
        vm.expectRevert(abi.encodeWithSelector(IBatchRequestManager.CancellationQueued.selector));
        batchRequestManager.requestRedeem(poolId, scId, 1, investor, USDC);
        vm.expectRevert(abi.encodeWithSelector(IBatchRequestManager.CancellationQueued.selector));
        batchRequestManager.cancelRedeemRequest(poolId, scId, investor, USDC);

        // Revoke shares + claim -> expect cancel fulfillment
        batchRequestManager.revokeShares(poolId, scId, USDC, _nowRevoke(USDC), poolPerShare, SHARE_HOOK_GAS);
        vm.expectEmit();
        emit IBatchRequestManager.ClaimRedeem(
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
        emit IBatchRequestManager.UpdateRedeemRequest(poolId, scId, USDC, epochId, investor, 0, 0, 0, false);
        (uint128 claimedAssetAmount, uint128 claimedShareAmount, uint128 cancelledTotal, bool canClaimAgain) =
            batchRequestManager.claimRedeem(poolId, scId, investor, USDC);
        assertEq(claimedAssetAmount, revokedAssetAmount, "Claimed asset amount mismatch");
        assertEq(claimedShareAmount, approvedShares, "Claimed share amount mismatch");
        assertEq(cancelledTotal, pendingShareAmount + queuedAmount, "Cancelled amount mismatch");
        assertEq(canClaimAgain, false, "Can claim again mismatch");

        _assertRedeemRequestEq(USDC, investor, UserOrder(0, epochId));
        assertEq(batchRequestManager.pendingRedeem(scId, USDC), 0, "Pending redeem mismatch");
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

        // Initial redeem request
        batchRequestManager.requestRedeem(poolId, scId, redeemShares, investor, USDC);
        batchRequestManager.approveRedeems(
            poolId, scId, USDC, _nowRedeem(USDC), approvedShares, _pricePoolPerAsset(USDC)
        );
        epochId = 2;

        // Expect queued increment due to approval
        vm.expectEmit();
        emit IBatchRequestManager.UpdateRedeemRequest(
            poolId, scId, USDC, epochId, investor, redeemShares, pendingShareAmount, 0, true
        );
        (uint128 cancelledPending) = batchRequestManager.cancelRedeemRequest(poolId, scId, investor, USDC);
        assertEq(cancelledPending, 0, "Cancellation queued (returns cancelled amount, 0 when queued)");

        // Revoke shares + claim -> expect cancel fulfillment
        batchRequestManager.revokeShares(poolId, scId, USDC, _nowRevoke(USDC), poolPerShare, SHARE_HOOK_GAS);
        vm.expectEmit();
        emit IBatchRequestManager.ClaimRedeem(
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
        emit IBatchRequestManager.UpdateRedeemRequest(poolId, scId, USDC, epochId, investor, 0, 0, 0, false);
        (uint128 claimedAssetAmount, uint128 claimedShareAmount, uint128 cancelledTotal, bool canClaimAgain) =
            batchRequestManager.claimRedeem(poolId, scId, investor, USDC);
        assertEq(claimedAssetAmount, revokedAssetAmount, "Claimed asset amount mismatch");
        assertEq(claimedShareAmount, approvedShares, "Claimed share amount mismatch");
        assertEq(cancelledTotal, pendingShareAmount, "Cancelled amount mismatch");
        assertEq(canClaimAgain, false, "Can claim again mismatch");

        _assertRedeemRequestEq(USDC, investor, UserOrder(0, epochId));
        assertEq(batchRequestManager.pendingRedeem(scId, USDC), 0, "Pending redeem mismatch");
        _assertQueuedRedeemRequestEq(USDC, investor, QueuedOrder(false, 0));
    }

    function testForceCancelRedeemRequestQueued(uint128 redeemAmount, uint128 approvedAmount) public {
        redeemAmount = uint128(bound(redeemAmount, MIN_REQUEST_AMOUNT_SHARES + 1, MAX_REQUEST_AMOUNT_SHARES));
        approvedAmount = uint128(bound(approvedAmount, MIN_REQUEST_AMOUNT_SHARES, redeemAmount - 1));
        uint128 queuedCancelAmount = redeemAmount - approvedAmount;

        // Set allowForceRedeemCancel to true
        batchRequestManager.cancelRedeemRequest(poolId, scId, investor, USDC);

        // Submit a redeem request, which will be applied since pending is zero
        batchRequestManager.requestRedeem(poolId, scId, redeemAmount, investor, USDC);
        batchRequestManager.approveRedeems(
            poolId, scId, USDC, _nowRedeem(USDC), approvedAmount, _pricePoolPerAsset(USDC)
        );
        batchRequestManager.revokeShares(poolId, scId, USDC, _nowRevoke(USDC), d18(1, 1), SHARE_HOOK_GAS);

        vm.expectEmit();
        emit IBatchRequestManager.UpdateRedeemRequest(
            poolId, scId, USDC, _nowRedeem(USDC), investor, redeemAmount, queuedCancelAmount, 0, true
        );
        uint256 forceCancelAmount = batchRequestManager.forceCancelRedeemRequest(poolId, scId, investor, USDC);

        // Verify post force cancel cleanup pre claiming
        assertEq(forceCancelAmount, 0, "Cancellation was queued (returns 0 when queued, callback only when immediate)");
        assertEq(
            batchRequestManager.allowForceRedeemCancel(scId, USDC, investor),
            true,
            "Cancellation flag should not be reset"
        );

        // Claim to trigger cancellation
        (uint128 redeemPayout, uint128 redeemPayment, uint128 cancelledRedeem, bool canClaimAgain) =
            batchRequestManager.claimRedeem(poolId, scId, investor, USDC);
        assertNotEq(redeemPayout, 0, "Redeem payout mismatch");
        assertEq(redeemPayment, approvedAmount, "Redeem payment mismatch");
        assertEq(cancelledRedeem, queuedCancelAmount, "Cancelled redeem mismatch");
        assertEq(canClaimAgain, false, "Can claim again mismatch");

        // Verify post claiming cleanup
        assertEq(batchRequestManager.pendingRedeem(scId, USDC), 0, "Pending redeem should be zero after force cancel");
        _assertRedeemRequestEq(USDC, investor, UserOrder(0, 2));

        // Verify the investor can make new requests after force cancellation
        batchRequestManager.requestRedeem(poolId, scId, redeemAmount, investor, USDC);
        _assertRedeemRequestEq(USDC, investor, UserOrder(redeemAmount, 2));
    }
}

///@dev Contains tests for skip claim behavior and multi-epoch claims
contract BatchRequestManagerMultiEpochTest is BatchRequestManagerBaseTest {
    using MathLib for *;

    function testClaimDepositSkippedEpochsNoPayout(uint8 skippedEpochs) public {
        vm.assume(skippedEpochs > 0);

        D18 navPoolPerShare = d18(1e18);
        uint128 approvedAmountUsdc = 1;
        uint32 lastUpdate = _nowDeposit(USDC);

        // Other investor should eat up the single approved asset amount
        batchRequestManager.requestDeposit(poolId, scId, 1, investor, USDC);
        batchRequestManager.requestDeposit(poolId, scId, MAX_REQUEST_AMOUNT_USDC, bytes32("bigPockets"), USDC);

        // Approve a few epochs without payout
        for (uint256 i = 0; i < skippedEpochs; i++) {
            batchRequestManager.approveDeposits(
                poolId, scId, USDC, _nowDeposit(USDC), approvedAmountUsdc, _pricePoolPerAsset(USDC)
            );
            batchRequestManager.issueShares(poolId, scId, USDC, _nowIssue(USDC), navPoolPerShare, SHARE_HOOK_GAS);
        }

        // Claim all epochs without expected payout due to low deposit amount
        for (uint256 i = 0; i < skippedEpochs; i++) {
            vm.expectEmit();
            emit IBatchRequestManager.ClaimDeposit(
                poolId, scId, lastUpdate, investor, USDC, 0, 1, 0, block.timestamp.toUint64()
            );
            (uint128 payout, uint128 payment, uint128 cancelled, bool canClaimAgain) =
                batchRequestManager.claimDeposit(poolId, scId, investor, USDC);

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
        batchRequestManager.requestDeposit(poolId, scId, depositAmountUsdc, investor, USDC);
        batchRequestManager.approveDeposits(poolId, scId, USDC, _nowDeposit(USDC), depositAmountUsdc, nonZeroPrice);
        batchRequestManager.issueShares(poolId, scId, USDC, _nowIssue(USDC), nonZeroPrice, SHARE_HOOK_GAS);

        // Request deposit with another investors to enable approvals after first epoch
        batchRequestManager.requestDeposit(poolId, scId, MAX_REQUEST_AMOUNT_USDC, bytes32("bigPockets"), USDC);

        // Approve more epochs which should all be skipped when investor claims first epoch
        for (uint256 i = 0; i < skippedEpochs; i++) {
            batchRequestManager.approveDeposits(poolId, scId, USDC, _nowDeposit(USDC), 1, nonZeroPrice);
            batchRequestManager.issueShares(poolId, scId, USDC, _nowIssue(USDC), nonZeroPrice, SHARE_HOOK_GAS);
        }

        // Expect only single claim to be required
        (uint128 payout, uint128 payment, uint128 cancelled, bool canClaimAgain) =
            batchRequestManager.claimDeposit(poolId, scId, investor, USDC);

        assertNotEq(payout, 0, "Mismatch: payout");
        assertEq(payment, depositAmountUsdc, "Mismatch: payment");
        assertEq(cancelled, 0, "Mismatch: cancelled");
        assertEq(canClaimAgain, false, "Mismatch: canClaimAgain - all claimed");
        _assertDepositRequestEq(USDC, investor, UserOrder(0, 2 + uint32(skippedEpochs)));

        vm.expectRevert(IBatchRequestManager.NoOrderFound.selector);
        batchRequestManager.claimDeposit(poolId, scId, investor, USDC);
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

        batchRequestManager.requestDeposit(poolId, scId, depositAmountUsdc, investor, USDC);

        // Approve + issue shares for each epoch
        for (uint256 i = 0; i < epochs; i++) {
            batchRequestManager.approveDeposits(
                poolId, scId, USDC, _nowDeposit(USDC), epochApprovedAmountUsdc, _pricePoolPerAsset(USDC)
            );

            uint128 issuedShares = _calcSharesIssued(USDC, epochApprovedAmountUsdc, poolPerShare);
            batchRequestManager.issueShares(poolId, scId, USDC, _nowIssue(USDC), poolPerShare, SHARE_HOOK_GAS);
            totalShares += issuedShares;
        }

        assertEq(batchRequestManager.maxDepositClaims(scId, investor, USDC), epochs);

        for (uint256 i = 0; i < epochs; i++) {
            (uint128 payout, uint128 payment, uint128 cancelled, bool canClaimAgain) =
                batchRequestManager.claimDeposit(poolId, scId, investor, USDC);

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

    function testClaimRedeemSkippedEpochsNoPayout(uint8 skippedEpochs) public {
        vm.assume(skippedEpochs > 0);

        D18 navPoolPerShare = d18(1e18);
        uint128 approvedShares = 1;
        uint32 lastUpdate = _nowRedeem(USDC);

        // Other investor should eat up the single approved asset amount
        batchRequestManager.requestRedeem(poolId, scId, 1, investor, USDC);
        batchRequestManager.requestRedeem(poolId, scId, MAX_REQUEST_AMOUNT_SHARES, bytes32("bigPockets"), USDC);

        // Approve a few epochs without payout
        for (uint256 i = 0; i < skippedEpochs; i++) {
            batchRequestManager.approveRedeems(
                poolId, scId, USDC, _nowRedeem(USDC), approvedShares, _pricePoolPerAsset(USDC)
            );
            batchRequestManager.revokeShares(poolId, scId, USDC, _nowRevoke(USDC), navPoolPerShare, SHARE_HOOK_GAS);
        }

        // Claim all epochs without expected payout due to low redeem amount
        for (uint256 i = 0; i < skippedEpochs; i++) {
            vm.expectEmit();
            emit IBatchRequestManager.ClaimRedeem(
                poolId, scId, lastUpdate, investor, USDC, 0, 1, 0, block.timestamp.toUint64()
            );
            (uint128 payout, uint128 payment, uint128 cancelled, bool canClaimAgain) =
                batchRequestManager.claimRedeem(poolId, scId, investor, USDC);

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

        // Other investor should eat up the single approved asset amount
        batchRequestManager.requestRedeem(poolId, scId, redeemShares, investor, USDC);
        batchRequestManager.approveRedeems(poolId, scId, USDC, _nowRedeem(USDC), redeemShares, nonZeroPrice);
        batchRequestManager.revokeShares(poolId, scId, USDC, _nowRevoke(USDC), nonZeroPrice, SHARE_HOOK_GAS);

        // Request redeem with another investors to enable approvals after first epoch
        batchRequestManager.requestRedeem(poolId, scId, MAX_REQUEST_AMOUNT_USDC, bytes32("bigPockets"), USDC);

        // Approve more epochs which should all be skipped when investor claims first epoch
        for (uint256 i = 0; i < skippedEpochs; i++) {
            batchRequestManager.approveRedeems(poolId, scId, USDC, _nowRedeem(USDC), 1, nonZeroPrice);
            batchRequestManager.revokeShares(poolId, scId, USDC, _nowRevoke(USDC), nonZeroPrice, SHARE_HOOK_GAS);
        }

        // Expect only single claim to be required
        (uint128 payout, uint128 payment, uint128 cancelled, bool canClaimAgain) =
            batchRequestManager.claimRedeem(poolId, scId, investor, USDC);

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

        batchRequestManager.requestRedeem(poolId, scId, totalRedeemShares, investor, USDC);

        // Approve + revoke shares for each epoch
        for (uint256 i = 0; i < epochs; i++) {
            batchRequestManager.approveRedeems(
                poolId, scId, USDC, _nowRedeem(USDC), epochApprovedShares, _pricePoolPerAsset(USDC)
            );

            uint128 revokedAssetAmount =
                _intoAssetAmount(USDC, poolPerShare.mulUint128(epochApprovedShares, MathLib.Rounding.Down));
            batchRequestManager.revokeShares(poolId, scId, USDC, _nowRevoke(USDC), poolPerShare, SHARE_HOOK_GAS);
            totalAssets += revokedAssetAmount;
        }

        assertEq(batchRequestManager.maxRedeemClaims(scId, investor, USDC), epochs);

        for (uint256 i = 0; i < epochs; i++) {
            (uint128 payout, uint128 payment, uint128 cancelled, bool canClaimAgain) =
                batchRequestManager.claimRedeem(poolId, scId, investor, USDC);

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
}
