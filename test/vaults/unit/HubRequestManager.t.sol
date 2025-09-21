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
import {IHubGatewayHandler} from "../../../src/common/interfaces/IGatewayHandlers.sol";

import {HubRequestManager} from "../../../src/vaults/HubRequestManager.sol";
import {IHubRegistry} from "../../../src/hub/interfaces/IHubRegistry.sol";
import {
    IHubRequestManager,
    EpochInvestAmounts,
    EpochRedeemAmounts,
    UserOrder,
    QueuedOrder,
    RequestType,
    EpochId
} from "../../../src/hub/interfaces/IHubRequestManager.sol";

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

contract HubMock is IHubGatewayHandler {
    uint256 public totalCost;

    function requestCallback(PoolId, ShareClassId, AssetId, bytes calldata, uint128)
        external
        override
        returns (uint256)
    {
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
    {}

    function updateShares(uint16, PoolId, ShareClassId, uint128, bool, bool, uint64) external override {}
}

abstract contract HubRequestManagerBaseTest is Test {
    using MathLib for uint128;
    using MathLib for uint256;
    using CastLib for string;
    using PricingLib for *;

    HubRequestManager public hubRequestManager;
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
        hubRequestManager = new HubRequestManager(IHubRegistry(address(hubRegistryMock)), address(this));

        // Set the hub address
        hubRequestManager.file("hub", address(hubMock));

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
            revert("HubRequestManagerBaseTest._priceAssetPerPool() - Unknown assetId");
        }
    }

    function _assertDepositRequestEq(AssetId asset, bytes32 investor_, UserOrder memory expected) internal view {
        (uint128 pending, uint32 lastUpdate) = hubRequestManager.depositRequest(scId, asset, investor_);

        assertEq(pending, expected.pending, "Mismatch: Deposit UserOrder.pending");
        assertEq(lastUpdate, expected.lastUpdate, "Mismatch: Deposit UserOrder.lastUpdate");
    }

    function _assertQueuedDepositRequestEq(AssetId asset, bytes32 investor_, QueuedOrder memory expected)
        internal
        view
    {
        (bool isCancelling, uint128 amount) = hubRequestManager.queuedDepositRequest(scId, asset, investor_);

        assertEq(isCancelling, expected.isCancelling, "isCancelling deposit mismatch");
        assertEq(amount, expected.amount, "amount deposit mismatch");
    }

    function _assertRedeemRequestEq(AssetId asset, bytes32 investor_, UserOrder memory expected) internal view {
        (uint128 pending, uint32 lastUpdate) = hubRequestManager.redeemRequest(scId, asset, investor_);

        assertEq(pending, expected.pending, "Mismatch: Redeem UserOrder.pending");
        assertEq(lastUpdate, expected.lastUpdate, "Mismatch: Redeem UserOrder.lastUpdate");
    }

    function _assertQueuedRedeemRequestEq(AssetId asset, bytes32 investor_, QueuedOrder memory expected)
        internal
        view
    {
        (bool isCancelling, uint128 amount) = hubRequestManager.queuedRedeemRequest(scId, asset, investor_);

        assertEq(isCancelling, expected.isCancelling, "isCancelling redeem mismatch");
        assertEq(amount, expected.amount, "amount redeem mismatch");
    }

    // Note: HubRequestManager doesn't expose epochInvestAmounts view function
    // Internal epoch state is not directly testable from outside

    // Note: HubRequestManager doesn't expose epochRedeemAmounts view function
    // Internal epoch state is not directly testable from outside

    function _nowDeposit(AssetId assetId) internal view returns (uint32) {
        return hubRequestManager.nowDepositEpoch(scId, assetId);
    }

    function _nowIssue(AssetId assetId) internal view returns (uint32) {
        return hubRequestManager.nowIssueEpoch(scId, assetId);
    }

    function _nowRedeem(AssetId assetId) internal view returns (uint32) {
        return hubRequestManager.nowRedeemEpoch(scId, assetId);
    }

    function _nowRevoke(AssetId assetId) internal view returns (uint32) {
        return hubRequestManager.nowRevokeEpoch(scId, assetId);
    }
}

///@dev Contains all simple tests which are expected to succeed
contract HubRequestManagerSimpleTest is HubRequestManagerBaseTest {
    using MathLib for uint128;
    using CastLib for string;

    function testInitialValues() public view {
        assertEq(hubRequestManager.nowDepositEpoch(scId, USDC), 1);
        assertEq(hubRequestManager.nowRedeemEpoch(scId, USDC), 1);
        assertEq(hubRequestManager.nowIssueEpoch(scId, USDC), 1);
        assertEq(hubRequestManager.nowRevokeEpoch(scId, USDC), 1);
    }

    function testMaxDepositClaims() public {
        assertEq(hubRequestManager.maxDepositClaims(scId, investor, USDC), 0);

        hubRequestManager.requestDeposit(poolId, scId, 1, investor, USDC);
        assertEq(hubRequestManager.maxDepositClaims(scId, investor, USDC), 0);
    }

    function testMaxRedeemClaims() public {
        assertEq(hubRequestManager.maxRedeemClaims(scId, investor, USDC), 0);

        hubRequestManager.requestRedeem(poolId, scId, 1, investor, USDC);
        assertEq(hubRequestManager.maxRedeemClaims(scId, investor, USDC), 0);
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
        assertEq(hubRequestManager.maxDepositClaims(scId, investor, USDC), 0);
        assertEq(hubRequestManager.maxRedeemClaims(scId, investor, USDC), 0);
    }
}

///@dev Contains all deposit related tests which are expected to succeed and don't make use of transient storage
contract HubRequestManagerDepositsNonTransientTest is HubRequestManagerBaseTest {
    using MathLib for *;

    function _deposit(uint128 depositAmountUsdc_, uint128 approvedAmountUsdc_)
        internal
        returns (uint128 depositAmountUsdc, uint128 approvedAmountUsdc, uint128 approvedPool)
    {
        depositAmountUsdc = uint128(bound(depositAmountUsdc_, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC));
        approvedAmountUsdc = uint128(bound(approvedAmountUsdc_, MIN_REQUEST_AMOUNT_USDC - 1, depositAmountUsdc));
        approvedPool = _intoPoolAmount(USDC, approvedAmountUsdc);

        hubRequestManager.requestDeposit(poolId, scId, depositAmountUsdc, investor, USDC);
        hubRequestManager.approveDeposits(
            poolId, scId, USDC, _nowDeposit(USDC), approvedAmountUsdc, _pricePoolPerAsset(USDC)
        );
    }

    function testRequestDeposit(uint128 amount) public {
        amount = uint128(bound(amount, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC));

        assertEq(hubRequestManager.pendingDeposit(scId, USDC), 0);
        _assertDepositRequestEq(USDC, investor, UserOrder(0, 0));

        vm.expectEmit();
        emit IHubRequestManager.UpdateDepositRequest(
            poolId, scId, USDC, hubRequestManager.nowDepositEpoch(scId, USDC), investor, amount, amount, 0, false
        );
        hubRequestManager.requestDeposit(poolId, scId, amount, investor, USDC);

        assertEq(hubRequestManager.pendingDeposit(scId, USDC), amount);
        _assertDepositRequestEq(USDC, investor, UserOrder(amount, 1));
    }

    function testCancelDepositRequest(uint128 amount) public {
        amount = uint128(bound(amount, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC));
        hubRequestManager.requestDeposit(poolId, scId, amount, investor, USDC);

        vm.expectEmit();
        emit IHubRequestManager.UpdateDepositRequest(
            poolId, scId, USDC, hubRequestManager.nowDepositEpoch(scId, USDC), investor, 0, 0, 0, false
        );
        (uint128 cancelledShares) = hubRequestManager.cancelDepositRequest(poolId, scId, investor, USDC);

        assertEq(cancelledShares, amount);
        assertEq(hubRequestManager.pendingDeposit(scId, USDC), 0);
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
            hubRequestManager.requestDeposit(poolId, scId, investorDeposit, investor, USDC);

            assertEq(hubRequestManager.pendingDeposit(scId, USDC), deposits);
        }

        assertEq(_nowDeposit(USDC), 1);

        vm.expectEmit();
        emit IHubRequestManager.ApproveDeposits(
            poolId,
            scId,
            USDC,
            _nowDeposit(USDC),
            _intoPoolAmount(USDC, approvedUsdc),
            approvedUsdc,
            deposits - approvedUsdc
        );
        uint256 cost = hubRequestManager.approveDeposits(
            poolId, scId, USDC, _nowDeposit(USDC), approvedUsdc, _pricePoolPerAsset(USDC)
        );
        assertEq(cost, 1000, "Should return callback cost");

        assertEq(hubRequestManager.pendingDeposit(scId, USDC), deposits - approvedUsdc);

        // Only one epoch should have passed
        assertEq(_nowDeposit(USDC), 2);

        // Note: Cannot test internal epoch state as epochInvestAmounts is not exposed
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

        hubRequestManager.requestDeposit(poolId, scId, depositAmountUsdc, investorUsdc, USDC);
        hubRequestManager.requestDeposit(poolId, scId, depositAmountOther, investorOther, OTHER_STABLE);

        assertEq(_nowDeposit(USDC), 1);
        assertEq(_nowDeposit(OTHER_STABLE), 1);

        hubRequestManager.approveDeposits(poolId, scId, USDC, _nowDeposit(USDC), approvedUsdc, _pricePoolPerAsset(USDC));
        hubRequestManager.approveDeposits(
            poolId, scId, OTHER_STABLE, _nowDeposit(OTHER_STABLE), approvedOtherStable, _pricePoolPerAsset(OTHER_STABLE)
        );

        assertEq(_nowDeposit(USDC), 2);
        assertEq(_nowDeposit(OTHER_STABLE), 2);

        // Note: Cannot test internal epoch state as epochInvestAmounts is not exposed
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

        uint256 cost =
            hubRequestManager.issueShares(poolId, scId, USDC, _nowIssue(USDC), navPoolPerShare, SHARE_HOOK_GAS);
        assertEq(cost, 1000, "Should return callback cost");

        // Note: Cannot test internal epoch state as epochInvestAmounts is not exposed
    }

    function testClaimDepositZeroApproved() public {
        hubRequestManager.requestDeposit(poolId, scId, 1, investor, USDC);
        hubRequestManager.requestDeposit(poolId, scId, 10, bytes32("investorOther"), USDC);
        hubRequestManager.approveDeposits(poolId, scId, USDC, _nowDeposit(USDC), 1, d18(1));

        hubRequestManager.issueShares(poolId, scId, USDC, _nowIssue(USDC), d18(1), SHARE_HOOK_GAS);

        vm.expectEmit();
        emit IHubRequestManager.ClaimDeposit(poolId, scId, 1, investor, USDC, 0, 1, 0, block.timestamp.toUint64());
        hubRequestManager.claimDeposit(poolId, scId, investor, USDC);
    }

    function testFullClaimDepositSingleEpoch() public {
        uint128 approvedAmountUsdc = 100 * DENO_USDC;
        uint128 depositAmountUsdc = approvedAmountUsdc;
        uint128 approvedPool = _intoPoolAmount(USDC, approvedAmountUsdc);
        assertEq(approvedPool, 100 * DENO_POOL);

        hubRequestManager.requestDeposit(poolId, scId, depositAmountUsdc, investor, USDC);
        hubRequestManager.approveDeposits(
            poolId, scId, USDC, _nowDeposit(USDC), approvedAmountUsdc, _pricePoolPerAsset(USDC)
        );

        vm.expectRevert(IHubRequestManager.IssuanceRequired.selector);
        hubRequestManager.claimDeposit(poolId, scId, investor, USDC);

        D18 navPoolPerShare = d18(11, 10);
        hubRequestManager.issueShares(poolId, scId, USDC, _nowIssue(USDC), navPoolPerShare, SHARE_HOOK_GAS);

        uint128 expectedShares = _calcSharesIssued(USDC, approvedAmountUsdc, navPoolPerShare);

        vm.expectEmit();
        emit IHubRequestManager.ClaimDeposit(
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
            hubRequestManager.claimDeposit(poolId, scId, investor, USDC);

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

        vm.expectRevert(IHubRequestManager.IssuanceRequired.selector);
        hubRequestManager.claimDeposit(poolId, scId, investor, USDC);

        hubRequestManager.issueShares(poolId, scId, USDC, _nowIssue(USDC), navPoolPerShare, SHARE_HOOK_GAS);

        uint128 expectedShares = _calcSharesIssued(USDC, approvedAmountUsdc, navPoolPerShare);

        vm.expectEmit();
        emit IHubRequestManager.ClaimDeposit(
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
            hubRequestManager.claimDeposit(poolId, scId, investor, USDC);

        assertEq(expectedShares, payoutShareAmount, "Mismatch: payoutShareAmount");
        assertEq(approvedAmountUsdc, depositAssetAmount, "Mismatch: depositAssetAmount");
        assertEq(0, cancelledAssetAmount, "Mismatch: cancelledAssetAmount");
        assertEq(false, canClaimAgain, "Mismatch: canClaimAgain");

        _assertDepositRequestEq(USDC, investor, UserOrder(depositAmountUsdc - approvedAmountUsdc, 2));
    }

    function testForceCancelDepositRequestZeroPending() public {
        hubRequestManager.cancelDepositRequest(poolId, scId, investor, USDC);

        vm.expectEmit();
        emit IHubRequestManager.UpdateDepositRequest(poolId, scId, USDC, 1, investor, 0, 0, 0, false);
        uint256 cancelledAmount = hubRequestManager.forceCancelDepositRequest(poolId, scId, investor, USDC);

        assertEq(cancelledAmount, 0, "Cancelled amount should be zero");
        assertEq(
            hubRequestManager.allowForceDepositCancel(scId, USDC, investor),
            true,
            "Cancellation flag should not be reset"
        );

        // Verify the investor can make new requests after force cancellation
        hubRequestManager.requestDeposit(poolId, scId, 1, investor, USDC);
        assertEq(
            hubRequestManager.pendingDeposit(scId, USDC), 1, "Should be able to make new deposits after force cancel"
        );
    }

    function testForceCancelDepositRequestImmediate(uint128 depositAmount) public {
        depositAmount = uint128(bound(depositAmount, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC));

        // Set allowForceDepositCancel to true (initialize cancellation)
        hubRequestManager.cancelDepositRequest(poolId, scId, investor, USDC);

        // Submit a deposit request, which will be applied since pending is zero
        hubRequestManager.requestDeposit(poolId, scId, depositAmount, investor, USDC);

        // Force cancel before approval -> expect instant cancellation
        vm.expectEmit();
        emit IHubRequestManager.UpdateDepositRequest(poolId, scId, USDC, _nowDeposit(USDC), investor, 0, 0, 0, false);
        uint256 cancelledAmount = hubRequestManager.forceCancelDepositRequest(poolId, scId, investor, USDC);

        // Verify cancellation was immediate and not queued
        // Note: forceCancelDepositRequest returns callback cost, not cancelled amount
        assertEq(cancelledAmount, 1000, "Should return callback cost");
        assertEq(
            hubRequestManager.allowForceDepositCancel(scId, USDC, investor),
            true,
            "Cancellation flag should not be reset"
        );
        assertEq(hubRequestManager.pendingDeposit(scId, USDC), 0, "Pending deposit should be zero after force cancel");
        _assertDepositRequestEq(USDC, investor, UserOrder(0, 1));

        // Verify the investor can make new requests after force cancellation
        hubRequestManager.requestDeposit(poolId, scId, depositAmount, investor, USDC);
        _assertDepositRequestEq(USDC, investor, UserOrder(depositAmount, 1));
    }
}

///@dev Contains all redeem related tests which are expected to succeed and don't make use of transient storage
contract HubRequestManagerRedeemsNonTransientTest is HubRequestManagerBaseTest {
    using MathLib for *;

    function _redeem(uint128 redeemShares_, uint128 approvedShares_, uint128 navPerShare)
        internal
        returns (uint128 redeemShares, uint128 approvedShares, uint128 approvedPool, D18 poolPerShare)
    {
        redeemShares = uint128(bound(redeemShares_, MIN_REQUEST_AMOUNT_SHARES, MAX_REQUEST_AMOUNT_SHARES));
        approvedShares = uint128(bound(approvedShares_, MIN_REQUEST_AMOUNT_SHARES, redeemShares));
        poolPerShare = d18(uint128(bound(navPerShare, 1e15, type(uint128).max / 1e18)));
        approvedPool = poolPerShare.mulUint128(approvedShares, MathLib.Rounding.Down);

        hubRequestManager.requestRedeem(poolId, scId, redeemShares, investor, USDC);
        hubRequestManager.approveRedeems(poolId, scId, USDC, _nowRedeem(USDC), approvedShares, _pricePoolPerAsset(USDC));
    }

    function testRequestRedeem(uint128 amount) public {
        amount = uint128(bound(amount, MIN_REQUEST_AMOUNT_SHARES, MAX_REQUEST_AMOUNT_SHARES));

        assertEq(hubRequestManager.pendingRedeem(scId, USDC), 0);
        _assertRedeemRequestEq(USDC, investor, UserOrder(0, 0));

        vm.expectEmit();
        emit IHubRequestManager.UpdateRedeemRequest(
            poolId, scId, USDC, hubRequestManager.nowRedeemEpoch(scId, USDC), investor, amount, amount, 0, false
        );
        hubRequestManager.requestRedeem(poolId, scId, amount, investor, USDC);

        assertEq(hubRequestManager.pendingRedeem(scId, USDC), amount);
        _assertRedeemRequestEq(USDC, investor, UserOrder(amount, 1));
    }

    function testCancelRedeemRequest(uint128 amount) public {
        amount = uint128(bound(amount, MIN_REQUEST_AMOUNT_SHARES, MAX_REQUEST_AMOUNT_SHARES));
        hubRequestManager.requestRedeem(poolId, scId, amount, investor, USDC);

        vm.expectEmit();
        emit IHubRequestManager.UpdateRedeemRequest(
            poolId, scId, USDC, hubRequestManager.nowRedeemEpoch(scId, USDC), investor, 0, 0, 0, false
        );
        (uint128 cancelledShares) = hubRequestManager.cancelRedeemRequest(poolId, scId, investor, USDC);

        assertEq(cancelledShares, amount);
        assertEq(hubRequestManager.pendingRedeem(scId, USDC), 0);
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
            hubRequestManager.requestRedeem(poolId, scId, investorRedeem, investor, USDC);

            assertEq(hubRequestManager.pendingRedeem(scId, USDC), redeems);
        }

        assertEq(_nowRedeem(USDC), 1);

        uint128 payoutAssetAmount = _intoAssetAmount(USDC, d18(1).mulUint128(approvedShares, MathLib.Rounding.Down));

        vm.expectEmit();
        emit IHubRequestManager.ApproveRedeems(
            poolId, scId, USDC, _nowRedeem(USDC), approvedShares, redeems - approvedShares
        );
        hubRequestManager.approveRedeems(poolId, scId, USDC, _nowRedeem(USDC), approvedShares, _pricePoolPerAsset(USDC));

        assertEq(hubRequestManager.pendingRedeem(scId, USDC), redeems - approvedShares);

        // Only one epoch should have passed
        assertEq(_nowRedeem(USDC), 2);

        // Note: Cannot test internal epoch state as epochRedeemAmounts is not exposed
    }

    function testRevokeSharesSingleEpoch(uint128 navPoolPerShare_, uint128 fuzzRedeemShares, uint128 fuzzApprovedShares)
        public
    {
        D18 navPoolPerShare = d18(uint128(bound(navPoolPerShare_, 1e14, type(uint128).max / 1e18)));
        (uint128 redeemShares, uint128 approvedShares,,) =
            _redeem(fuzzRedeemShares, fuzzApprovedShares, navPoolPerShare.raw());

        uint256 cost =
            hubRequestManager.revokeShares(poolId, scId, USDC, _nowRevoke(USDC), navPoolPerShare, SHARE_HOOK_GAS);
        assertEq(cost, 1000, "Should return callback cost");

        uint128 payoutAssetAmount =
            _intoAssetAmount(USDC, navPoolPerShare.mulUint128(approvedShares, MathLib.Rounding.Down));

        // Note: Cannot test internal epoch state as epochRedeemAmounts is not exposed
    }

    function testClaimRedeemZeroApproved() public {
        hubRequestManager.requestRedeem(poolId, scId, 1, investor, USDC);
        hubRequestManager.requestRedeem(poolId, scId, 10, bytes32("investorOther"), USDC);
        hubRequestManager.approveRedeems(poolId, scId, USDC, _nowRedeem(USDC), 1, d18(1));

        hubRequestManager.revokeShares(poolId, scId, USDC, _nowRevoke(USDC), d18(1), SHARE_HOOK_GAS);

        vm.expectEmit();
        emit IHubRequestManager.ClaimRedeem(poolId, scId, 1, investor, USDC, 0, 1, 0, block.timestamp.toUint64());
        hubRequestManager.claimRedeem(poolId, scId, investor, USDC);
    }

    function testFullClaimRedeemSingleEpoch() public {
        uint128 approvedShares = 100 * DENO_POOL;
        uint128 redeemShares = approvedShares;
        D18 navPoolPerShare = d18(11, 10);

        hubRequestManager.requestRedeem(poolId, scId, redeemShares, investor, USDC);
        hubRequestManager.approveRedeems(poolId, scId, USDC, _nowRedeem(USDC), approvedShares, _pricePoolPerAsset(USDC));

        vm.expectRevert(IHubRequestManager.RevocationRequired.selector);
        hubRequestManager.claimRedeem(poolId, scId, investor, USDC);

        hubRequestManager.revokeShares(poolId, scId, USDC, _nowRevoke(USDC), navPoolPerShare, SHARE_HOOK_GAS);

        uint128 expectedAssetAmount =
            _intoAssetAmount(USDC, navPoolPerShare.mulUint128(approvedShares, MathLib.Rounding.Down));

        vm.expectEmit();
        emit IHubRequestManager.ClaimRedeem(
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
            hubRequestManager.claimRedeem(poolId, scId, investor, USDC);

        assertEq(expectedAssetAmount, payoutAssetAmount, "Mismatch: payoutAssetAmount");
        assertEq(approvedShares, redeemShareAmount, "Mismatch: redeemShareAmount");
        assertEq(0, cancelledShareAmount, "Mismatch: cancelledShareAmount");
        assertEq(false, canClaimAgain, "Mismatch: canClaimAgain");

        _assertRedeemRequestEq(USDC, investor, UserOrder(redeemShares - approvedShares, 2));
    }

    function testForceCancelRedeemRequestZeroPending() public {
        hubRequestManager.cancelRedeemRequest(poolId, scId, investor, USDC);

        vm.expectEmit();
        emit IHubRequestManager.UpdateRedeemRequest(poolId, scId, USDC, 1, investor, 0, 0, 0, false);
        uint256 cancelledAmount = hubRequestManager.forceCancelRedeemRequest(poolId, scId, investor, USDC);

        assertEq(cancelledAmount, 0, "Cancelled amount should be zero");
        assertEq(
            hubRequestManager.allowForceRedeemCancel(scId, USDC, investor),
            true,
            "Cancellation flag should not be reset"
        );

        // Verify the investor can make new requests after force cancellation
        hubRequestManager.requestRedeem(poolId, scId, 1, investor, USDC);
        assertEq(
            hubRequestManager.pendingRedeem(scId, USDC), 1, "Should be able to make new redeems after force cancel"
        );
    }

    function testForceCancelRedeemRequestImmediate(uint128 redeemAmount) public {
        redeemAmount = uint128(bound(redeemAmount, MIN_REQUEST_AMOUNT_SHARES, MAX_REQUEST_AMOUNT_SHARES));

        // Set allowForceRedeemCancel to true (initialize cancellation)
        hubRequestManager.cancelRedeemRequest(poolId, scId, investor, USDC);

        // Submit a redeem request, which will be applied since pending is zero
        hubRequestManager.requestRedeem(poolId, scId, redeemAmount, investor, USDC);

        // Force cancel before approval -> expect instant cancellation
        vm.expectEmit();
        emit IHubRequestManager.UpdateRedeemRequest(poolId, scId, USDC, _nowRedeem(USDC), investor, 0, 0, 0, false);
        uint256 cancelledAmount = hubRequestManager.forceCancelRedeemRequest(poolId, scId, investor, USDC);

        // Verify cancellation was immediate and not queued
        // Note: forceCancelRedeemRequest returns callback cost, not cancelled amount
        assertEq(cancelledAmount, 1000, "Should return callback cost");
        assertEq(
            hubRequestManager.allowForceRedeemCancel(scId, USDC, investor),
            true,
            "Cancellation flag should not be reset"
        );
        assertEq(hubRequestManager.pendingRedeem(scId, USDC), 0, "Pending redeem should be zero after force cancel");
        _assertRedeemRequestEq(USDC, investor, UserOrder(0, 1));

        // Verify the investor can make new requests after force cancellation
        hubRequestManager.requestRedeem(poolId, scId, redeemAmount, investor, USDC);
        _assertRedeemRequestEq(USDC, investor, UserOrder(redeemAmount, 1));
    }
}
