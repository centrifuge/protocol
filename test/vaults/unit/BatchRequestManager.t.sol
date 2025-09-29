// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {D18, d18} from "../../../src/misc/types/D18.sol";
import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";
import {MathLib} from "../../../src/misc/libraries/MathLib.sol";
import {IERC165} from "../../../src/misc/interfaces/IERC165.sol";

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {AssetId} from "../../../src/common/types/AssetId.sol";
import {PricingLib} from "../../../src/common/libraries/PricingLib.sol";
import {ShareClassId} from "../../../src/common/types/ShareClassId.sol";
import {IHubGatewayHandler} from "../../../src/common/interfaces/IGatewayHandlers.sol";

import {IHubRegistry} from "../../../src/hub/interfaces/IHubRegistry.sol";
import {IHubRequestManagerCallback} from "../../../src/hub/interfaces/IHubRequestManagerCallback.sol";
import {IHubRequestManager, IHubRequestManagerNotifications} from "../../../src/hub/interfaces/IHubRequestManager.sol";

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
uint256 constant CB_GAS_COST = 1000;

contract HubRegistryMock {
    mapping(PoolId => mapping(address user => bool)) public manager;

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

    function updateManager(PoolId poolId, address user, bool isManager) external {
        manager[poolId][user] = isManager;
    }
}

contract HubMock is IHubGatewayHandler, IHubRequestManagerCallback {
    uint256 public totalCost;

    function requestCallback(PoolId, ShareClassId, AssetId, bytes calldata, uint128) external returns (uint256) {
        uint256 cost = CB_GAS_COST; // Mock cost
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

contract GatewayMock {
    function depositSubsidy(PoolId) external payable {}

    function withdrawSubsidy(PoolId, address recipient, uint256 amount) external {
        payable(recipient).transfer(amount);
    }
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

    function cancelDepositRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId depositAssetId)
        public
        returns (uint128 cancelledAssetAmount)
    {
        return _cancelDepositRequest(poolId, scId, investor, depositAssetId);
    }

    function cancelRedeemRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId payoutAssetId)
        public
        returns (uint128 cancelledShareAmount)
    {
        return _cancelRedeemRequest(poolId, scId, investor, payoutAssetId);
    }

    function unclaimedDepositCancellation(ShareClassId scId, AssetId depositAssetId, bytes32 investor)
        public
        view
        returns (uint128)
    {
        return pendingDepositCancellation[scId][depositAssetId][investor];
    }

    function unclaimedRedeemCancellation(ShareClassId scId, AssetId payoutAssetId, bytes32 investor)
        public
        view
        returns (uint128)
    {
        return pendingRedeemCancellation[scId][payoutAssetId][investor];
    }
}

abstract contract BatchRequestManagerBaseTest is Test {
    using MathLib for uint128;
    using MathLib for uint256;
    using CastLib for string;
    using PricingLib for *;

    receive() external payable {}

    BatchRequestManagerHarness public batchRequestManager;
    HubRegistryMock public hubRegistryMock;
    HubMock public hubMock;
    GatewayMock public gatewayMock;

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
        gatewayMock = new GatewayMock();
        batchRequestManager = new BatchRequestManagerHarness(IHubRegistry(address(hubRegistryMock)), address(this));

        // Set the hub and gateway addresses
        batchRequestManager.file("hub", address(hubMock));
        batchRequestManager.file("gateway", address(gatewayMock));

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

    // ============ Event Parsing Helpers ============

    /// @dev Generic helper to extract event data by selector
    function _extractEventData(bytes32 eventSig) internal returns (bytes memory) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                return logs[i].data;
            }
        }
        revert(string.concat("Event not found: ", vm.toString(eventSig)));
    }

    function _extractIssueSharesEvent()
        internal
        returns (uint128 issuedShares, D18 navPoolPerShare, D18 priceAssetPerShare)
    {
        bytes memory data = _extractEventData(IBatchRequestManager.IssueShares.selector);
        (, navPoolPerShare, priceAssetPerShare, issuedShares) = abi.decode(data, (uint32, D18, D18, uint128));
        return (issuedShares, navPoolPerShare, priceAssetPerShare);
    }

    function _extractRevokeSharesEvent()
        internal
        returns (
            uint128 revokedShares,
            uint128 payoutAssetAmount,
            uint128 payoutPoolAmount,
            D18 navPoolPerShare,
            D18 priceAssetPerShare
        )
    {
        bytes memory data = _extractEventData(IBatchRequestManager.RevokeShares.selector);
        (, navPoolPerShare, priceAssetPerShare, revokedShares, payoutAssetAmount, payoutPoolAmount) =
            abi.decode(data, (uint32, D18, D18, uint128, uint128, uint128));
        return (revokedShares, payoutAssetAmount, payoutPoolAmount, navPoolPerShare, priceAssetPerShare);
    }

    function _extractApproveDepositsEvent()
        internal
        returns (uint128 approvedPoolAmount, uint128 approvedAssetAmount, uint128 pendingAssetAmount)
    {
        bytes memory data = _extractEventData(IBatchRequestManager.ApproveDeposits.selector);
        (, approvedPoolAmount, approvedAssetAmount, pendingAssetAmount) =
            abi.decode(data, (uint32, uint128, uint128, uint128));
        return (approvedPoolAmount, approvedAssetAmount, pendingAssetAmount);
    }

    function _extractApproveRedeemsEvent() internal returns (uint128 approvedShareAmount, uint128 pendingShareAmount) {
        bytes memory data = _extractEventData(IBatchRequestManager.ApproveRedeems.selector);
        (, approvedShareAmount, pendingShareAmount) = abi.decode(data, (uint32, uint128, uint128));
        return (approvedShareAmount, pendingShareAmount);
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

    /// @dev Helper function for deposit and approval - direct calls
    function _depositAndApprove(uint128 depositAmount, uint128 approvedAmount) internal {
        batchRequestManager.requestDeposit(poolId, scId, depositAmount, investor, USDC);
        batchRequestManager.approveDeposits(
            poolId, scId, USDC, _nowDeposit(USDC), approvedAmount, _pricePoolPerAsset(USDC)
        );
    }

    /// @dev Helper function for deposit and approval with bounds checking for fuzz testing
    function _depositAndApproveWithFuzzBounds(uint128 depositAmountUsdc_, uint128 approvedAmountUsdc_)
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

    /// @dev Helper function for redeem and approval - direct calls
    function _redeemAndApprove(uint128 redeemShares, uint128 approvedShares, uint128 /* navPerShare */) internal {
        batchRequestManager.requestRedeem(poolId, scId, redeemShares, investor, USDC);
        batchRequestManager.approveRedeems(
            poolId, scId, USDC, _nowRedeem(USDC), approvedShares, _pricePoolPerAsset(USDC)
        );
    }

    /// @dev Helper function for redeem and approval with bounds checking for fuzz testing
    function _redeemAndApproveWithFuzzBounds(uint128 redeemShares_, uint128 approvedShares_, uint128 navPerShare)
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

    function testEpochViewsInitialValues() public view {
        assertEq(_nowDeposit(USDC), 1);
        assertEq(_nowIssue(USDC), 1);
        assertEq(_nowRedeem(USDC), 1);
        assertEq(_nowRevoke(USDC), 1);
    }

    function testMaxClaimsStartsAtZero() public view {
        assertEq(batchRequestManager.maxDepositClaims(scId, investor, USDC), 0);
        assertEq(batchRequestManager.maxRedeemClaims(scId, investor, USDC), 0);
    }
}

///@dev Contains all deposit related tests which are expected to succeed and don't make use of transient storage
contract BatchRequestManagerDepositsNonTransientTest is BatchRequestManagerBaseTest {
    using MathLib for *;

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
        assertEq(
            batchRequestManager.unclaimedDepositCancellation(scId, USDC, investor), amount, "Should store cancellation"
        );
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

        uint128 expectedPoolAmount = _intoPoolAmount(USDC, approvedUsdc);
        uint128 expectedPendingAfter = deposits - approvedUsdc;

        vm.recordLogs();
        vm.expectEmit();
        emit IBatchRequestManager.ApproveDeposits(
            poolId, scId, USDC, _nowDeposit(USDC), expectedPoolAmount, approvedUsdc, expectedPendingAfter
        );
        uint256 cost = batchRequestManager.approveDeposits(
            poolId, scId, USDC, _nowDeposit(USDC), approvedUsdc, _pricePoolPerAsset(USDC)
        );
        assertEq(cost, CB_GAS_COST, "Should return callback cost");

        (uint128 eventPoolAmount, uint128 eventAssetAmount, uint128 eventPending) = _extractApproveDepositsEvent();
        assertEq(eventPoolAmount, expectedPoolAmount, "Event pool amount mismatch");
        assertEq(eventAssetAmount, approvedUsdc, "Event asset amount mismatch");
        assertEq(eventPending, expectedPendingAfter, "Event pending amount mismatch");

        assertEq(batchRequestManager.pendingDeposit(scId, USDC), deposits - approvedUsdc);

        {
            (uint128 storedPoolAmount, uint128 storedApprovedAsset,,,,) =
                batchRequestManager.epochInvestAmounts(scId, USDC, _nowDeposit(USDC) - 1);
            assertEq(storedApprovedAsset, approvedUsdc, "Epoch approved asset amount mismatch");
            assertEq(storedPoolAmount, expectedPoolAmount, "Epoch pool amount mismatch");
        }

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
        (, uint128 approvedAmount,) = _depositAndApproveWithFuzzBounds(fuzzDepositAmountUsdc, fuzzApprovedAmountUsdc);

        uint128 expectedIssuedShares = _calcSharesIssued(USDC, approvedAmount, navPoolPerShare);

        vm.recordLogs();
        uint256 cost =
            batchRequestManager.issueShares(poolId, scId, USDC, _nowIssue(USDC), navPoolPerShare, SHARE_HOOK_GAS);
        assertEq(cost, CB_GAS_COST, "Should return callback cost");

        (uint128 actualIssuedShares, D18 eventNav,) = _extractIssueSharesEvent();
        assertEq(actualIssuedShares, expectedIssuedShares, "Issued shares mismatch");
        assertEq(eventNav.raw(), navPoolPerShare.raw(), "NAV in event mismatch");
        {
            (,,,, D18 storedNav, uint64 issuedAt) =
                batchRequestManager.epochInvestAmounts(scId, USDC, _nowIssue(USDC) - 1);
            assertEq(storedNav.raw(), navPoolPerShare.raw(), "Stored NAV mismatch");
            assertGt(issuedAt, 0, "Issuance timestamp not set");
        }

        assertEq(actualIssuedShares, expectedIssuedShares, "Event shares should match calculated");
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

        _depositAndApprove(depositAmountUsdc, approvedAmountUsdc);

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
            _depositAndApproveWithFuzzBounds(fuzzDepositAmountUsdc, fuzzApprovedAmountUsdc);

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

        batchRequestManager.requestDeposit(poolId, scId, 1, investor, USDC);
        assertEq(
            batchRequestManager.pendingDeposit(scId, USDC), 1, "Should be able to make new deposits after force cancel"
        );
    }

    function testForceCancelDepositRequestImmediate(uint128 depositAmount) public {
        depositAmount = uint128(bound(depositAmount, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC));

        // Set allowForceDepositCancel to true (initialize cancellation)
        batchRequestManager.cancelDepositRequest(poolId, scId, investor, USDC);

        batchRequestManager.requestDeposit(poolId, scId, depositAmount, investor, USDC);

        (uint128 pendingBefore,) = batchRequestManager.depositRequest(scId, USDC, investor);
        uint128 totalPendingBefore = batchRequestManager.pendingDeposit(scId, USDC);

        // Expected cancelled amount should be the full pending
        uint128 expectedCancelledAmount = pendingBefore;

        vm.expectEmit();
        emit IBatchRequestManager.UpdateDepositRequest(poolId, scId, USDC, _nowDeposit(USDC), investor, 0, 0, 0, false);
        uint256 cost = batchRequestManager.forceCancelDepositRequest(poolId, scId, investor, USDC);
        assertEq(cost, 0, "Should return 0 cost as no immediate callback");

        (uint128 pendingAfter,) = batchRequestManager.depositRequest(scId, USDC, investor);
        uint128 totalPendingAfter = batchRequestManager.pendingDeposit(scId, USDC);

        uint128 actualCancelledAmount = pendingBefore - pendingAfter;
        assertEq(actualCancelledAmount, expectedCancelledAmount, "Cancelled amount mismatch");
        assertEq(actualCancelledAmount, depositAmount, "Should cancel full deposit amount");
        assertEq(totalPendingBefore - totalPendingAfter, depositAmount, "Total pending reduction mismatch");

        assertEq(
            batchRequestManager.allowForceDepositCancel(scId, USDC, investor),
            true,
            "Cancellation flag should not be reset"
        );
        assertEq(batchRequestManager.pendingDeposit(scId, USDC), 0, "Pending deposit should be zero after force cancel");
        _assertDepositRequestEq(USDC, investor, UserOrder(0, 1));

        assertEq(
            batchRequestManager.unclaimedDepositCancellation(scId, USDC, investor),
            depositAmount,
            "Should store cancellation"
        );

        // Verify the investor can make new requests after force cancellation
        batchRequestManager.requestDeposit(poolId, scId, depositAmount, investor, USDC);
        _assertDepositRequestEq(USDC, investor, UserOrder(depositAmount, 1));
    }

    /// @dev Tests request() function with DepositRequest message
    function testDepositRequestMessageSerialization() public {
        uint128 amount = MIN_REQUEST_AMOUNT_USDC;
        bytes memory payload = abi.encodePacked(uint8(1), abi.encode(investor, amount));

        vm.expectEmit();
        emit IBatchRequestManager.UpdateDepositRequest(poolId, scId, USDC, 1, investor, 0, 0, 0, false);
        batchRequestManager.request(poolId, scId, USDC, payload);

        _assertDepositRequestEq(USDC, investor, UserOrder(0, 1));
        assertEq(batchRequestManager.pendingDeposit(scId, USDC), 0, "Pending should be updated");
    }

    /// @dev Tests request() function with CancelDepositRequest message
    function testCancelDepositRequestMessageSerialization() public {
        batchRequestManager.requestDeposit(poolId, scId, MIN_REQUEST_AMOUNT_USDC, investor, USDC);

        // Cancel via request() function using serialized message
        bytes memory payload = abi.encodePacked(uint8(3), abi.encode(investor));

        vm.expectEmit();
        emit IBatchRequestManager.UpdateDepositRequest(poolId, scId, USDC, 1, investor, 0, 0, 0, false);
        batchRequestManager.request(poolId, scId, USDC, payload);

        _assertDepositRequestEq(USDC, investor, UserOrder(0, 1));
        assertEq(batchRequestManager.pendingDeposit(scId, USDC), 0, "Pending should be cleared");
        assertEq(
            batchRequestManager.allowForceDepositCancel(scId, USDC, investor), true, "Force cancel should be enabled"
        );

        assertEq(
            batchRequestManager.unclaimedDepositCancellation(scId, USDC, investor),
            MIN_REQUEST_AMOUNT_USDC,
            "Should store cancellation"
        );
    }

    /// @dev Tests queued cancellation blocking
    function testQueuedDepositCancellationBlocking() public {
        _depositAndApprove(MIN_REQUEST_AMOUNT_USDC, MIN_REQUEST_AMOUNT_USDC);
        assertEq(_nowDeposit(USDC), 2, "Should now be epoch 2");

        // Queue a new request (will be queued since epoch advanced)
        batchRequestManager.requestDeposit(poolId, scId, MIN_REQUEST_AMOUNT_USDC, investor, USDC);
        _assertQueuedDepositRequestEq(USDC, investor, QueuedOrder(false, MIN_REQUEST_AMOUNT_USDC));

        // Queue cancellation
        batchRequestManager.cancelDepositRequest(poolId, scId, investor, USDC);
        _assertQueuedDepositRequestEq(USDC, investor, QueuedOrder(true, MIN_REQUEST_AMOUNT_USDC));

        // Try to add more to queue while cancellation is queued - should fail with CancellationQueued
        vm.expectRevert(IBatchRequestManager.CancellationQueued.selector);
        batchRequestManager.requestDeposit(poolId, scId, MIN_REQUEST_AMOUNT_USDC, investor, USDC);
    }

    function testNotifyDepositWithExcessGasShouldRefund() public {
        _depositAndApproveWithFuzzBounds(MIN_REQUEST_AMOUNT_USDC, MIN_REQUEST_AMOUNT_USDC);
        batchRequestManager.issueShares(poolId, scId, USDC, 1, d18(1), SHARE_HOOK_GAS);

        uint256 excessGas = 1 ether;
        uint256 balanceBefore = address(this).balance;

        uint256 cost = batchRequestManager.notifyDeposit{value: excessGas}(poolId, scId, USDC, investor, 10);

        uint256 balanceAfter = address(this).balance;
        assertLt(balanceBefore - balanceAfter, excessGas);
        assertGt(cost, 0);
    }

    function testNotifyDepositNoCancellation() public {
        _depositAndApproveWithFuzzBounds(MIN_REQUEST_AMOUNT_USDC, MIN_REQUEST_AMOUNT_USDC);
        batchRequestManager.issueShares(poolId, scId, USDC, 1, d18(1), SHARE_HOOK_GAS);

        batchRequestManager.notifyDeposit{value: 0.1 ether}(poolId, scId, USDC, investor, 10);
        _assertDepositRequestEq(USDC, investor, UserOrder(0, 2));
    }

    function testNotifyDepositExactCost() public {
        _depositAndApproveWithFuzzBounds(MIN_REQUEST_AMOUNT_USDC, MIN_REQUEST_AMOUNT_USDC);
        batchRequestManager.issueShares(poolId, scId, USDC, 1, d18(1), SHARE_HOOK_GAS);

        uint256 balanceBefore = address(this).balance;

        uint256 cost = batchRequestManager.notifyDeposit{value: CB_GAS_COST}(poolId, scId, USDC, investor, 10);
        uint256 balanceAfter = address(this).balance;
        assertEq(balanceBefore - balanceAfter, CB_GAS_COST);
        assertEq(cost, CB_GAS_COST);

        _assertDepositRequestEq(USDC, investor, UserOrder(0, 2));
    }

    function testNotifyDepositWithQueuedCancellation() public {
        _depositAndApprove(MIN_REQUEST_AMOUNT_USDC, MIN_REQUEST_AMOUNT_USDC);
        batchRequestManager.issueShares(poolId, scId, USDC, 1, d18(1), SHARE_HOOK_GAS);

        // Queue
        batchRequestManager.requestDeposit(poolId, scId, MIN_REQUEST_AMOUNT_USDC, investor, USDC);
        batchRequestManager.cancelDepositRequest(poolId, scId, investor, USDC);

        uint256 cost = batchRequestManager.notifyDeposit{value: 0.1 ether}(poolId, scId, USDC, investor, 10);
        assertGt(cost, 0);
        _assertDepositRequestEq(USDC, investor, UserOrder(0, 2));
    }

    function testNotifyDepositZeroMaxClaims() public {
        _depositAndApproveWithFuzzBounds(MIN_REQUEST_AMOUNT_USDC, MIN_REQUEST_AMOUNT_USDC);
        batchRequestManager.issueShares(poolId, scId, USDC, 1, d18(1), SHARE_HOOK_GAS);

        (uint128 initialPending, uint32 initialLastUpdate) = batchRequestManager.depositRequest(scId, USDC, investor);

        uint256 cost = batchRequestManager.notifyDeposit{value: CB_GAS_COST}(poolId, scId, USDC, investor, 0);

        (uint128 finalPending, uint32 finalLastUpdate) = batchRequestManager.depositRequest(scId, USDC, investor);
        assertEq(finalPending, initialPending);
        assertEq(finalLastUpdate, initialLastUpdate);

        assertEq(cost, 0);
    }

    function testNotifyCancelDepositSuccess() public {
        uint128 amount = MIN_REQUEST_AMOUNT_USDC;
        batchRequestManager.requestDeposit(poolId, scId, amount, investor, USDC);
        batchRequestManager.cancelDepositRequest(poolId, scId, investor, USDC);

        assertEq(
            batchRequestManager.unclaimedDepositCancellation(scId, USDC, investor),
            amount,
            "Should have unclaimed cancellation"
        );

        uint256 gasSent = 0.1 ether;
        uint256 cost = batchRequestManager.notifyCancelDeposit{value: gasSent}(poolId, scId, USDC, investor);

        assertEq(batchRequestManager.unclaimedDepositCancellation(scId, USDC, investor), 0, "Should clear unclaimed");
        assertGt(cost, 0, "Should have gas cost");
    }
}

///@dev Contains all redeem related tests which are expected to succeed and don't make use of transient storage
contract BatchRequestManagerRedeemsNonTransientTest is BatchRequestManagerBaseTest {
    using MathLib for *;

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

        assertEq(
            batchRequestManager.unclaimedRedeemCancellation(scId, USDC, investor), amount, "Should store cancellation"
        );
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
        (, uint128 approvedShares,,) =
            _redeemAndApproveWithFuzzBounds(fuzzRedeemShares, fuzzApprovedShares, navPoolPerShare.raw());

        vm.recordLogs();
        uint256 cost =
            batchRequestManager.revokeShares(poolId, scId, USDC, _nowRevoke(USDC), navPoolPerShare, SHARE_HOOK_GAS);
        assertEq(cost, CB_GAS_COST, "Should return callback cost");

        (uint128 revokedShares, uint128 payoutAsset, uint128 payoutPool, D18 eventNav,) = _extractRevokeSharesEvent();

        assertEq(revokedShares, approvedShares, "Revoked shares should match approved");
        assertEq(eventNav.raw(), navPoolPerShare.raw(), "NAV in event mismatch");

        // Calculate and verify expected amounts
        uint128 expectedPayoutPool = navPoolPerShare.mulUint128(approvedShares, MathLib.Rounding.Down);
        uint128 expectedPayoutAsset = _intoAssetAmount(USDC, expectedPayoutPool);
        assertEq(payoutAsset, expectedPayoutAsset, "Payout asset amount mismatch");
        assertEq(payoutPool, expectedPayoutPool, "Payout pool amount mismatch");

        {
            (,,, D18 storedNav, uint128 storedPayoutAsset, uint64 revokedAt) =
                batchRequestManager.epochRedeemAmounts(scId, USDC, _nowRevoke(USDC) - 1);
            assertEq(storedNav.raw(), navPoolPerShare.raw(), "Stored NAV mismatch");
            assertEq(storedPayoutAsset, payoutAsset, "Stored payout mismatch");
            assertGt(revokedAt, 0, "Revocation timestamp not set");
        }
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

        (uint128 pendingBefore,) = batchRequestManager.redeemRequest(scId, USDC, investor);
        uint128 totalPendingBefore = batchRequestManager.pendingRedeem(scId, USDC);

        // Expected cancelled amount should be the full pending
        uint128 expectedCancelledShares = pendingBefore;

        // Force cancel before approval -> expect instant cancellation
        vm.expectEmit();
        emit IBatchRequestManager.UpdateRedeemRequest(poolId, scId, USDC, _nowRedeem(USDC), investor, 0, 0, 0, false);
        uint256 cost = batchRequestManager.forceCancelRedeemRequest(poolId, scId, investor, USDC);
        assertEq(cost, 0, "Should return 0 cost as no immediate callback");

        (uint128 pendingAfter,) = batchRequestManager.redeemRequest(scId, USDC, investor);
        uint128 totalPendingAfter = batchRequestManager.pendingRedeem(scId, USDC);

        uint128 actualCancelledShares = pendingBefore - pendingAfter;
        assertEq(actualCancelledShares, expectedCancelledShares, "Cancelled shares mismatch");
        assertEq(actualCancelledShares, redeemAmount, "Should cancel full redeem amount");
        assertEq(totalPendingBefore - totalPendingAfter, redeemAmount, "Total pending reduction mismatch");

        assertEq(
            batchRequestManager.allowForceRedeemCancel(scId, USDC, investor),
            true,
            "Cancellation flag should not be reset"
        );
        assertEq(batchRequestManager.pendingRedeem(scId, USDC), 0, "Pending redeem should be zero after force cancel");
        _assertRedeemRequestEq(USDC, investor, UserOrder(0, 1));
        assertEq(
            batchRequestManager.unclaimedRedeemCancellation(scId, USDC, investor),
            redeemAmount,
            "Should store cancellation"
        );

        // Verify the investor can make new requests after force cancellation
        batchRequestManager.requestRedeem(poolId, scId, redeemAmount, investor, USDC);
        _assertRedeemRequestEq(USDC, investor, UserOrder(redeemAmount, 1));
    }

    /// @dev Tests request() function with RedeemRequest message
    function testRedeemRequestMessageSerialization() public {
        uint128 amount = MIN_REQUEST_AMOUNT_SHARES;
        bytes memory payload = abi.encodePacked(uint8(2), abi.encode(investor, amount));

        vm.expectEmit();
        emit IBatchRequestManager.UpdateRedeemRequest(poolId, scId, USDC, 1, investor, 0, 0, 0, false);
        batchRequestManager.request(poolId, scId, USDC, payload);

        _assertRedeemRequestEq(USDC, investor, UserOrder(0, 1));
        assertEq(batchRequestManager.pendingRedeem(scId, USDC), 0, "Pending should be updated");
    }

    /// @dev Tests request() function with CancelRedeemRequest message
    function testCancelRedeemRequestMessageSerialization() public {
        batchRequestManager.requestRedeem(poolId, scId, MIN_REQUEST_AMOUNT_SHARES, investor, USDC);

        bytes memory payload = abi.encodePacked(uint8(4), abi.encode(investor));
        vm.expectEmit();
        emit IBatchRequestManager.UpdateRedeemRequest(poolId, scId, USDC, 1, investor, 0, 0, 0, false);
        batchRequestManager.request(poolId, scId, USDC, payload);

        _assertRedeemRequestEq(USDC, investor, UserOrder(0, 1));
        assertEq(batchRequestManager.pendingRedeem(scId, USDC), 0, "Pending should be cleared");
        assertEq(
            batchRequestManager.allowForceRedeemCancel(scId, USDC, investor), true, "Force cancel should be enabled"
        );
        assertEq(
            batchRequestManager.unclaimedRedeemCancellation(scId, USDC, investor),
            MIN_REQUEST_AMOUNT_SHARES,
            "Should store cancellation"
        );
    }

    /// @dev Tests queued cancellation blocking for redeems
    function testQueuedRedeemCancellationBlocking() public {
        _redeemAndApprove(MIN_REQUEST_AMOUNT_SHARES, MIN_REQUEST_AMOUNT_SHARES, 1e18);
        assertEq(_nowRedeem(USDC), 2, "Should now be epoch 2");

        // Queue a new request (will be queued since epoch advanced)
        batchRequestManager.requestRedeem(poolId, scId, MIN_REQUEST_AMOUNT_SHARES, investor, USDC);
        _assertQueuedRedeemRequestEq(USDC, investor, QueuedOrder(false, MIN_REQUEST_AMOUNT_SHARES));

        // Queue cancellation
        batchRequestManager.cancelRedeemRequest(poolId, scId, investor, USDC);
        _assertQueuedRedeemRequestEq(USDC, investor, QueuedOrder(true, MIN_REQUEST_AMOUNT_SHARES));

        // Try to add more to queue while cancellation is queued - should fail with CancellationQueued
        vm.expectRevert(IBatchRequestManager.CancellationQueued.selector);
        batchRequestManager.requestRedeem(poolId, scId, MIN_REQUEST_AMOUNT_SHARES, investor, USDC);
    }

    function testNotifyRedeemWithExcessGasShouldRefund() public {
        _redeemAndApproveWithFuzzBounds(MIN_REQUEST_AMOUNT_SHARES, MIN_REQUEST_AMOUNT_SHARES, 1);
        batchRequestManager.revokeShares(poolId, scId, USDC, 1, d18(1), SHARE_HOOK_GAS);

        uint256 excessGas = 1 ether;
        uint256 balanceBefore = address(this).balance;

        uint256 cost = batchRequestManager.notifyRedeem{value: excessGas}(poolId, scId, USDC, investor, 10);
        uint256 balanceAfter = address(this).balance;
        assertLt(balanceBefore - balanceAfter, excessGas);
        assertGt(cost, 0);
    }

    function testNotifyRedeemNoCancellation() public {
        _redeemAndApproveWithFuzzBounds(MIN_REQUEST_AMOUNT_SHARES, MIN_REQUEST_AMOUNT_SHARES, 1);
        batchRequestManager.revokeShares(poolId, scId, USDC, 1, d18(1), SHARE_HOOK_GAS);

        batchRequestManager.notifyRedeem{value: 0.1 ether}(poolId, scId, USDC, investor, 10);
        _assertRedeemRequestEq(USDC, investor, UserOrder(0, 2));
    }

    function testNotifyRedeemExactCost() public {
        _redeemAndApproveWithFuzzBounds(MIN_REQUEST_AMOUNT_SHARES, MIN_REQUEST_AMOUNT_SHARES, 1);
        batchRequestManager.revokeShares(poolId, scId, USDC, 1, d18(1), SHARE_HOOK_GAS);

        uint256 exactCost = CB_GAS_COST;
        uint256 balanceBefore = address(this).balance;

        uint256 cost = batchRequestManager.notifyRedeem{value: exactCost}(poolId, scId, USDC, investor, 10);

        uint256 balanceAfter = address(this).balance;
        assertEq(balanceBefore - balanceAfter, exactCost);
        assertEq(cost, exactCost);

        _assertRedeemRequestEq(USDC, investor, UserOrder(0, 2));
    }

    function testNotifyRedeemWithQueuedCancellation() public {
        _redeemAndApprove(MIN_REQUEST_AMOUNT_SHARES, MIN_REQUEST_AMOUNT_SHARES, 1);
        batchRequestManager.revokeShares(poolId, scId, USDC, 1, d18(1), SHARE_HOOK_GAS);

        // Queue
        batchRequestManager.requestRedeem(poolId, scId, MIN_REQUEST_AMOUNT_SHARES, investor, USDC);
        batchRequestManager.cancelRedeemRequest(poolId, scId, investor, USDC);

        uint256 cost = batchRequestManager.notifyRedeem{value: 0.1 ether}(poolId, scId, USDC, investor, 10);
        assertGt(cost, 0);
        _assertRedeemRequestEq(USDC, investor, UserOrder(0, 2));
    }

    function testNotifyRedeemZeroMaxClaims() public {
        _redeemAndApproveWithFuzzBounds(MIN_REQUEST_AMOUNT_SHARES, MIN_REQUEST_AMOUNT_SHARES, 1);
        batchRequestManager.revokeShares(poolId, scId, USDC, 1, d18(1), SHARE_HOOK_GAS);

        (uint128 initialPending, uint32 initialLastUpdate) = batchRequestManager.redeemRequest(scId, USDC, investor);
        uint256 cost = batchRequestManager.notifyRedeem{value: CB_GAS_COST}(poolId, scId, USDC, investor, 0);

        (uint128 finalPending, uint32 finalLastUpdate) = batchRequestManager.redeemRequest(scId, USDC, investor);
        assertEq(finalPending, initialPending);
        assertEq(finalLastUpdate, initialLastUpdate);
        assertEq(cost, 0);
    }

    function testNotifyCancelRedeemSuccess() public {
        uint128 amount = MIN_REQUEST_AMOUNT_SHARES;
        batchRequestManager.requestRedeem(poolId, scId, amount, investor, USDC);
        batchRequestManager.cancelRedeemRequest(poolId, scId, investor, USDC);

        assertEq(
            batchRequestManager.unclaimedRedeemCancellation(scId, USDC, investor),
            amount,
            "Should have unclaimed cancellation"
        );

        uint256 gasSent = 0.1 ether;
        uint256 cost = batchRequestManager.notifyCancelRedeem{value: gasSent}(poolId, scId, USDC, investor);

        assertEq(batchRequestManager.unclaimedRedeemCancellation(scId, USDC, investor), 0, "Should clear unclaimed");
        assertGt(cost, 0, "Should have gas cost");
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

        uint128 expectedQueuedCancel = queuedCancelAmount;

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
        assertEq(cancelledDeposit, expectedQueuedCancel, "Queued cancellation amount mismatch");
        assertEq(cancelledDeposit, depositAmount - approvedAmount, "Should cancel unapproved amount");
        assertEq(canClaimAgain, false, "Can claim again mismatch");

        assertEq(batchRequestManager.pendingDeposit(scId, USDC), 0, "Pending deposit should be zero after force cancel");
        _assertDepositRequestEq(USDC, investor, UserOrder(0, 2));

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

        // Track expected queued cancellation amount
        uint128 expectedQueuedCancel = queuedCancelAmount;

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
        assertEq(cancelledRedeem, expectedQueuedCancel, "Queued cancellation shares mismatch");
        assertEq(cancelledRedeem, redeemAmount - approvedAmount, "Should cancel unapproved shares");
        assertEq(canClaimAgain, false, "Can claim again mismatch");

        // Verify post claiming cleanup
        assertEq(batchRequestManager.pendingRedeem(scId, USDC), 0, "Pending redeem should be zero after force cancel");
        _assertRedeemRequestEq(USDC, investor, UserOrder(0, 2));

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

    function testMaxClaimsCalculationBranches() public {
        // Test branch 1: userOrder.pending == 0 -> return 0
        assertEq(batchRequestManager.maxDepositClaims(scId, investor, USDC), 0, "No pending, should return 0");

        // Test branch 2: userOrder.lastUpdate > lastEpoch -> return 0 (user ahead of processing)
        batchRequestManager.requestDeposit(poolId, scId, MIN_REQUEST_AMOUNT_USDC, investor, USDC);
        assertEq(
            batchRequestManager.maxDepositClaims(scId, investor, USDC), 0, "User ahead of processing, should return 0"
        );

        // Test normal calculation: lastEpoch - userOrder.lastUpdate + 1
        batchRequestManager.approveDeposits(
            poolId, scId, USDC, _nowDeposit(USDC), MIN_REQUEST_AMOUNT_USDC, _pricePoolPerAsset(USDC)
        );
        batchRequestManager.issueShares(poolId, scId, USDC, _nowIssue(USDC), d18(1), SHARE_HOOK_GAS);

        assertEq(batchRequestManager.maxDepositClaims(scId, investor, USDC), 1, "Should have 1 claimable epoch");

        // Create multiple epochs to test calculation
        for (uint256 i = 0; i < 3; i++) {
            batchRequestManager.requestDeposit(poolId, scId, MIN_REQUEST_AMOUNT_USDC, bytes32(uint256(i + 100)), USDC);
            batchRequestManager.approveDeposits(
                poolId, scId, USDC, _nowDeposit(USDC), MIN_REQUEST_AMOUNT_USDC, _pricePoolPerAsset(USDC)
            );
            batchRequestManager.issueShares(poolId, scId, USDC, _nowIssue(USDC), d18(1), SHARE_HOOK_GAS);
        }

        // Original investor should still have 1+3=4 claimable epochs
        assertEq(batchRequestManager.maxDepositClaims(scId, investor, USDC), 4, "Should have 4 claimable epochs");
    }

    /// @dev Tests all three conditions in _canMutatePending function
    function testCanMutatePendingAllConditions(uint128 amount) public {
        amount = uint128(bound(amount, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC));

        // Condition 1: currentEpoch <= 1 (first epoch allows direct mutation)
        assertEq(_nowDeposit(USDC), 1, "Should be epoch 1");
        batchRequestManager.requestDeposit(poolId, scId, amount, investor, USDC);
        _assertDepositRequestEq(USDC, investor, UserOrder(amount, 1));
        assertEq(batchRequestManager.pendingDeposit(scId, USDC), amount, "Should update pending directly");

        // Condition 2: userOrder.pending == 0 (allows direct mutation)
        batchRequestManager.cancelDepositRequest(poolId, scId, investor, USDC);
        _assertDepositRequestEq(USDC, investor, UserOrder(0, 1));

        // Should allow direct mutation since pending == 0
        batchRequestManager.requestDeposit(poolId, scId, amount, investor, USDC);
        _assertDepositRequestEq(USDC, investor, UserOrder(amount, 1));

        // Move to epoch 2 by approving
        batchRequestManager.approveDeposits(poolId, scId, USDC, _nowDeposit(USDC), amount, _pricePoolPerAsset(USDC));
        assertEq(_nowDeposit(USDC), 2, "Should be epoch 2");

        // Condition 3: userOrder.lastUpdate >= currentEpoch (user is current, allows direct mutation)
        // Since investor's lastUpdate = 1 and currentEpoch = 2, this will be queued, not direct
        batchRequestManager.requestDeposit(poolId, scId, amount, investor, USDC);
        _assertDepositRequestEq(USDC, investor, UserOrder(amount, 1));
        assertEq(batchRequestManager.pendingDeposit(scId, USDC), 0, "Should not update pending when queued");

        // Should queue instead of direct mutation when no conditions are met
        bytes32 otherInvestor = bytes32("laggingInvestor");
        batchRequestManager.requestDeposit(poolId, scId, amount, otherInvestor, USDC);
        batchRequestManager.approveDeposits(poolId, scId, USDC, _nowDeposit(USDC), amount, _pricePoolPerAsset(USDC));
        assertEq(_nowDeposit(USDC), 3, "Should be epoch 3");

        // otherInvestor's lastUpdate is 2, currentEpoch is 3, has pending > 0
        // None of the three conditions met, so should queue
        uint128 newAmount = amount * 2;
        vm.expectEmit();
        emit IBatchRequestManager.UpdateDepositRequest(
            poolId, scId, USDC, 3, otherInvestor, amount, 0, newAmount, false // Queued, not pending
        );
        batchRequestManager.requestDeposit(poolId, scId, newAmount, otherInvestor, USDC);

        _assertQueuedDepositRequestEq(USDC, otherInvestor, QueuedOrder(false, newAmount));
        assertEq(
            batchRequestManager.pendingDeposit(scId, USDC),
            0,
            "Pending should be 0 after approving otherInvestor's deposit"
        );
    }

    /// @dev Tests force cancel callback handling
    function testForceCancelCallbackHandling() public {
        batchRequestManager.cancelDepositRequest(poolId, scId, investor, USDC);

        // Test immediate force cancel (returns callback cost)
        batchRequestManager.requestDeposit(poolId, scId, MIN_REQUEST_AMOUNT_USDC, investor, USDC);

        uint256 callbackCost = batchRequestManager.forceCancelDepositRequest(poolId, scId, investor, USDC);
        assertEq(callbackCost, 0, "Should return 0 cost as no immediate callback, amount stored for claiming");

        batchRequestManager.requestDeposit(poolId, scId, MIN_REQUEST_AMOUNT_USDC, investor, USDC);
        batchRequestManager.approveDeposits(
            poolId, scId, USDC, _nowDeposit(USDC), MIN_REQUEST_AMOUNT_USDC / 2, _pricePoolPerAsset(USDC)
        );
        batchRequestManager.issueShares(poolId, scId, USDC, _nowIssue(USDC), d18(1), SHARE_HOOK_GAS);

        // This should queue the cancellation
        uint256 queuedCost = batchRequestManager.forceCancelDepositRequest(poolId, scId, investor, USDC);
        assertEq(queuedCost, 0, "Should return 0 when cancellation is queued");
    }

    /// @dev Tests claiming at exact epoch boundaries
    function testClaimingAtEpochBoundaries() public {
        uint128 amount = MIN_REQUEST_AMOUNT_USDC;

        batchRequestManager.requestDeposit(poolId, scId, amount, investor, USDC);
        batchRequestManager.approveDeposits(poolId, scId, USDC, _nowDeposit(USDC), amount, _pricePoolPerAsset(USDC));
        batchRequestManager.issueShares(poolId, scId, USDC, _nowIssue(USDC), d18(1), SHARE_HOOK_GAS);

        assertEq(batchRequestManager.maxDepositClaims(scId, investor, USDC), 1, "Should have 1 claim");
        (,,, bool canClaimAgain) = batchRequestManager.claimDeposit(poolId, scId, investor, USDC);
        assertEq(canClaimAgain, false, "Should not be able to claim again after last epoch");

        _assertDepositRequestEq(USDC, investor, UserOrder(0, 2));
        assertEq(batchRequestManager.maxDepositClaims(scId, investor, USDC), 0, "Should have no more claims");
    }
}

///@dev Contains all authorization failure tests
contract BatchRequestManagerAuthTest is BatchRequestManagerBaseTest {
    address unauthorized;

    function setUp() public override {
        super.setUp();
        unauthorized = makeAddr("unauthorized");

        assertEq(batchRequestManager.wards(unauthorized), 0, "Should have no authorization");
    }

    function testFileUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        batchRequestManager.file("hub", address(hubMock));
    }

    function testFileInvalidParam() public {
        vm.expectRevert(IBatchRequestManager.FileUnrecognizedParam.selector);
        batchRequestManager.file("invalid", address(0));
    }

    function testRequestUnauthorized() public {
        bytes memory payload = abi.encodePacked(uint8(0), abi.encode(investor, MIN_REQUEST_AMOUNT_USDC));
        vm.prank(unauthorized);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        batchRequestManager.request(poolId, scId, USDC, payload);
    }

    function testRequestDepositUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        batchRequestManager.requestDeposit(poolId, scId, MIN_REQUEST_AMOUNT_USDC, investor, USDC);
    }

    function testRequestRedeemUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        batchRequestManager.requestRedeem(poolId, scId, MIN_REQUEST_AMOUNT_SHARES, investor, USDC);
    }

    function testApproveDepositsUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        batchRequestManager.approveDeposits(poolId, scId, USDC, 1, MIN_REQUEST_AMOUNT_USDC, _pricePoolPerAsset(USDC));
    }

    function testApproveRedeemsUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        batchRequestManager.approveRedeems(poolId, scId, USDC, 1, MIN_REQUEST_AMOUNT_SHARES, _pricePoolPerAsset(USDC));
    }

    function testIssueSharesUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        batchRequestManager.issueShares(poolId, scId, USDC, 1, d18(1), SHARE_HOOK_GAS);
    }

    function testRevokeSharesUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        batchRequestManager.revokeShares(poolId, scId, USDC, 1, d18(1), SHARE_HOOK_GAS);
    }

    function testForceCancelDepositRequestUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        batchRequestManager.forceCancelDepositRequest(poolId, scId, investor, USDC);
    }

    function testForceCancelRedeemRequestUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        batchRequestManager.forceCancelRedeemRequest(poolId, scId, investor, USDC);
    }

    function testFileGateway() public {
        address newGateway = makeAddr("newGateway");
        vm.expectEmit();
        emit IBatchRequestManager.File("gateway", newGateway);
        batchRequestManager.file("gateway", newGateway);
        assertEq(address(batchRequestManager.gateway()), newGateway);
    }
}

contract BatchRequestManagerErrorTest is BatchRequestManagerBaseTest {
    function testRequestUnknownType() public {
        // Create payload with invalid message type (0 = Invalid enum value, valid handled ones are 1,2,3,4)
        bytes memory invalidPayload = abi.encodePacked(uint8(0), abi.encode(investor, uint128(100)));
        vm.expectRevert(IBatchRequestManager.UnknownRequestType.selector);
        batchRequestManager.request(poolId, scId, USDC, invalidPayload);
    }

    function testApproveDepositsEpochNotInSequence() public {
        vm.expectRevert(abi.encodeWithSelector(IBatchRequestManager.EpochNotInSequence.selector, 2, 1));
        batchRequestManager.approveDeposits(poolId, scId, USDC, 2, MIN_REQUEST_AMOUNT_USDC, _pricePoolPerAsset(USDC));
    }

    function testApproveDepositsInsufficientPending() public {
        uint128 pendingAmount = MIN_REQUEST_AMOUNT_USDC;
        batchRequestManager.requestDeposit(poolId, scId, pendingAmount, investor, USDC);
        uint32 currentEpoch = _nowDeposit(USDC);

        vm.expectRevert(IBatchRequestManager.InsufficientPending.selector);
        batchRequestManager.approveDeposits(
            poolId, scId, USDC, currentEpoch, pendingAmount + 1, _pricePoolPerAsset(USDC)
        );
    }

    function testApproveDepositsZeroAmount() public {
        batchRequestManager.requestDeposit(poolId, scId, MIN_REQUEST_AMOUNT_USDC, investor, USDC);

        uint32 currentEpoch = _nowDeposit(USDC);
        vm.expectRevert(IBatchRequestManager.ZeroApprovalAmount.selector);
        batchRequestManager.approveDeposits(poolId, scId, USDC, currentEpoch, 0, _pricePoolPerAsset(USDC));
    }

    function testApproveRedeemsEpochNotInSequence() public {
        vm.expectRevert(abi.encodeWithSelector(IBatchRequestManager.EpochNotInSequence.selector, 2, 1));
        batchRequestManager.approveRedeems(poolId, scId, USDC, 2, MIN_REQUEST_AMOUNT_SHARES, _pricePoolPerAsset(USDC));
    }

    function testApproveRedeemsInsufficientPending() public {
        uint128 pendingShares = MIN_REQUEST_AMOUNT_SHARES;
        batchRequestManager.requestRedeem(poolId, scId, pendingShares, investor, USDC);

        uint32 currentEpoch = _nowRedeem(USDC);

        vm.expectRevert(IBatchRequestManager.InsufficientPending.selector);
        batchRequestManager.approveRedeems(
            poolId, scId, USDC, currentEpoch, pendingShares + 1, _pricePoolPerAsset(USDC)
        );
    }

    function testApproveRedeemsZeroAmount() public {
        batchRequestManager.requestRedeem(poolId, scId, MIN_REQUEST_AMOUNT_SHARES, investor, USDC);

        uint32 currentEpoch = _nowRedeem(USDC);

        vm.expectRevert(IBatchRequestManager.ZeroApprovalAmount.selector);
        batchRequestManager.approveRedeems(poolId, scId, USDC, currentEpoch, 0, _pricePoolPerAsset(USDC));
    }

    function testIssueSharesEpochNotFound() public {
        vm.expectRevert(IBatchRequestManager.EpochNotFound.selector);
        batchRequestManager.issueShares(poolId, scId, USDC, 1, d18(1), SHARE_HOOK_GAS);
    }

    function testIssueSharesEpochNotInSequence() public {
        batchRequestManager.requestDeposit(poolId, scId, MIN_REQUEST_AMOUNT_USDC, investor, USDC);
        batchRequestManager.approveDeposits(poolId, scId, USDC, 1, MIN_REQUEST_AMOUNT_USDC, _pricePoolPerAsset(USDC));
        batchRequestManager.issueShares(poolId, scId, USDC, 1, d18(1), SHARE_HOOK_GAS);

        batchRequestManager.requestDeposit(poolId, scId, MIN_REQUEST_AMOUNT_USDC, bytes32("investor2"), USDC);
        batchRequestManager.approveDeposits(poolId, scId, USDC, 2, MIN_REQUEST_AMOUNT_USDC, _pricePoolPerAsset(USDC));

        // Current issue epoch is 2, test issuing epoch 1
        vm.expectRevert(abi.encodeWithSelector(IBatchRequestManager.EpochNotInSequence.selector, 1, 2));
        batchRequestManager.issueShares(poolId, scId, USDC, 1, d18(1), SHARE_HOOK_GAS);
    }

    function testRevokeSharesEpochNotFound() public {
        vm.expectRevert(IBatchRequestManager.EpochNotFound.selector);
        batchRequestManager.revokeShares(poolId, scId, USDC, 1, d18(1), SHARE_HOOK_GAS);
    }

    function testRevokeSharesEpochNotInSequence() public {
        batchRequestManager.requestRedeem(poolId, scId, MIN_REQUEST_AMOUNT_SHARES, investor, USDC);
        batchRequestManager.approveRedeems(poolId, scId, USDC, 1, MIN_REQUEST_AMOUNT_SHARES, _pricePoolPerAsset(USDC));
        batchRequestManager.revokeShares(poolId, scId, USDC, 1, d18(1), SHARE_HOOK_GAS);

        batchRequestManager.requestRedeem(poolId, scId, MIN_REQUEST_AMOUNT_SHARES, bytes32("investor2"), USDC);
        batchRequestManager.approveRedeems(poolId, scId, USDC, 2, MIN_REQUEST_AMOUNT_SHARES, _pricePoolPerAsset(USDC));

        // Current revoke epoch is 2, test revoking epoch 1
        vm.expectRevert(abi.encodeWithSelector(IBatchRequestManager.EpochNotInSequence.selector, 1, 2));
        batchRequestManager.revokeShares(poolId, scId, USDC, 1, d18(1), SHARE_HOOK_GAS);
    }

    function testClaimDepositNoOrderFound() public {
        vm.expectRevert(IBatchRequestManager.NoOrderFound.selector);
        batchRequestManager.claimDeposit(poolId, scId, bytes32("nonexistent"), USDC);
    }

    function testClaimDepositIssuanceRequired() public {
        _depositAndApprove(MIN_REQUEST_AMOUNT_USDC, MIN_REQUEST_AMOUNT_USDC);

        // Try to claim before issuance
        vm.expectRevert(IBatchRequestManager.IssuanceRequired.selector);
        batchRequestManager.claimDeposit(poolId, scId, investor, USDC);
    }

    function testClaimRedeemNoOrderFound() public {
        vm.expectRevert(IBatchRequestManager.NoOrderFound.selector);
        batchRequestManager.claimRedeem(poolId, scId, bytes32("nonexistent"), USDC);
    }

    /// @dev Tests claimRedeem() revocation required validation
    function testClaimRedeemRevocationRequired() public {
        _redeemAndApprove(MIN_REQUEST_AMOUNT_SHARES, MIN_REQUEST_AMOUNT_SHARES, 1e18);

        // Try to claim before revocation
        vm.expectRevert(IBatchRequestManager.RevocationRequired.selector);
        batchRequestManager.claimRedeem(poolId, scId, investor, USDC);
    }

    function testForceCancelDepositNotInitialized() public {
        vm.expectRevert(IBatchRequestManager.CancellationInitializationRequired.selector);
        batchRequestManager.forceCancelDepositRequest(poolId, scId, investor, USDC);
    }

    function testForceCancelRedeemNotInitialized() public {
        vm.expectRevert(IBatchRequestManager.CancellationInitializationRequired.selector);
        batchRequestManager.forceCancelRedeemRequest(poolId, scId, investor, USDC);
    }

    function testNotifyDepositInsufficientGas() public {
        // Setup deposit and approve it
        batchRequestManager.requestDeposit(poolId, scId, MIN_REQUEST_AMOUNT_USDC, investor, USDC);
        batchRequestManager.approveDeposits(poolId, scId, USDC, 1, MIN_REQUEST_AMOUNT_USDC, _pricePoolPerAsset(USDC));
        batchRequestManager.issueShares(poolId, scId, USDC, 1, d18(1), SHARE_HOOK_GAS);

        // Call notifyDeposit with insufficient gas (0 value when cost > 0)
        vm.expectRevert(IBatchRequestManager.NotEnoughGas.selector);
        batchRequestManager.notifyDeposit{value: 0}(poolId, scId, USDC, investor, 10);
    }

    function testNotifyRedeemInsufficientGas() public {
        // Setup redeem and approve it
        batchRequestManager.requestRedeem(poolId, scId, MIN_REQUEST_AMOUNT_SHARES, investor, USDC);
        batchRequestManager.approveRedeems(poolId, scId, USDC, 1, MIN_REQUEST_AMOUNT_SHARES, _pricePoolPerAsset(USDC));
        batchRequestManager.revokeShares(poolId, scId, USDC, 1, d18(1), SHARE_HOOK_GAS);

        // Call notifyRedeem with insufficient gas (0 value when cost > 0)
        vm.expectRevert(IBatchRequestManager.NotEnoughGas.selector);
        batchRequestManager.notifyRedeem{value: 0}(poolId, scId, USDC, investor, 10);
    }

    function testNotifyCancelDepositNoCancel() public {
        vm.expectRevert(IBatchRequestManager.NoUnclaimedCancellation.selector);
        batchRequestManager.notifyCancelDeposit{value: 0.1 ether}(poolId, scId, USDC, investor);
    }

    function testNotifyCancelRedeemNoCancel() public {
        vm.expectRevert(IBatchRequestManager.NoUnclaimedCancellation.selector);
        batchRequestManager.notifyCancelRedeem{value: 0.1 ether}(poolId, scId, USDC, investor);
    }

    function testNotifyCancelDepositDoubleClaim() public {
        batchRequestManager.requestDeposit(poolId, scId, MIN_REQUEST_AMOUNT_USDC, investor, USDC);
        batchRequestManager.cancelDepositRequest(poolId, scId, investor, USDC);
        batchRequestManager.notifyCancelDeposit{value: 0.1 ether}(poolId, scId, USDC, investor);

        // Second claim should fail
        vm.expectRevert(IBatchRequestManager.NoUnclaimedCancellation.selector);
        batchRequestManager.notifyCancelDeposit{value: 0.1 ether}(poolId, scId, USDC, investor);
    }

    function testNotifyCancelRedeemDoubleClaim() public {
        batchRequestManager.requestRedeem(poolId, scId, MIN_REQUEST_AMOUNT_SHARES, investor, USDC);
        batchRequestManager.cancelRedeemRequest(poolId, scId, investor, USDC);
        batchRequestManager.notifyCancelRedeem{value: 0.1 ether}(poolId, scId, USDC, investor);

        // Second claim should fail
        vm.expectRevert(IBatchRequestManager.NoUnclaimedCancellation.selector);
        batchRequestManager.notifyCancelRedeem{value: 0.1 ether}(poolId, scId, USDC, investor);
    }
}

///@dev Contains all zero amount and isNotZero() branch tests with exact assertions
contract BatchRequestManagerZeroAmountTest is BatchRequestManagerBaseTest {
    function testIssueSharesZeroNav() public {
        _depositAndApprove(MIN_REQUEST_AMOUNT_USDC, MIN_REQUEST_AMOUNT_USDC);

        vm.expectEmit();
        emit IBatchRequestManager.IssueShares(poolId, scId, USDC, 1, d18(0), d18(0), 0);
        uint256 cost = batchRequestManager.issueShares(poolId, scId, USDC, _nowIssue(USDC), d18(0), SHARE_HOOK_GAS);
        assertEq(cost, CB_GAS_COST, "Should return callback cost");

        (,, uint128 approvedPoolAmount,, D18 navPoolPerShare, uint64 issuedAt) =
            batchRequestManager.epochInvestAmounts(scId, USDC, 1);
        assertEq(navPoolPerShare.raw(), 0, "NAV should be zero");
        assertEq(issuedAt, 1, "Should be issued at epoch 1");
        assertGt(approvedPoolAmount, 0, "Should have approved amount");
    }

    function testRevokeSharesZeroNav() public {
        batchRequestManager.requestRedeem(poolId, scId, MIN_REQUEST_AMOUNT_SHARES, investor, USDC);
        batchRequestManager.approveRedeems(
            poolId, scId, USDC, _nowRedeem(USDC), MIN_REQUEST_AMOUNT_SHARES, _pricePoolPerAsset(USDC)
        );

        // Revoke shares with zero NAV
        vm.expectEmit();
        emit IBatchRequestManager.RevokeShares(
            poolId, scId, USDC, 1, d18(0), d18(0), MIN_REQUEST_AMOUNT_SHARES, 0, 0 // Zero payout
        );
        uint256 cost = batchRequestManager.revokeShares(poolId, scId, USDC, _nowRevoke(USDC), d18(0), SHARE_HOOK_GAS);
        assertEq(cost, CB_GAS_COST, "Should return callback cost");

        (,,, D18 navPoolPerShare, uint128 payoutAssetAmount, uint64 revokedAt) =
            batchRequestManager.epochRedeemAmounts(scId, USDC, 1);
        assertEq(navPoolPerShare.raw(), 0, "NAV should be zero");
        assertEq(payoutAssetAmount, 0, "Payout should be zero");
        assertEq(revokedAt, 1, "Should be revoked at epoch 1");
    }

    /// @dev Tests issueShares() with zero price
    function testIssueSharesZeroPrice() public {
        batchRequestManager.requestDeposit(poolId, scId, MIN_REQUEST_AMOUNT_USDC, investor, USDC);
        batchRequestManager.approveDeposits(
            poolId,
            scId,
            USDC,
            _nowDeposit(USDC),
            MIN_REQUEST_AMOUNT_USDC,
            d18(0) // Zero price
        );

        // Issue shares with non-zero NAV but zero price
        vm.expectEmit();
        emit IBatchRequestManager.IssueShares(
            poolId, scId, USDC, 1, d18(1), d18(0), 0 // d18(0) from zero price calculation
        );
        batchRequestManager.issueShares(poolId, scId, USDC, _nowIssue(USDC), d18(1), SHARE_HOOK_GAS);

        (,,, D18 pricePoolPerAsset, D18 navPoolPerShare, uint64 issuedAt) =
            batchRequestManager.epochInvestAmounts(scId, USDC, 1);
        assertEq(pricePoolPerAsset.raw(), 0, "Price should be zero");
        assertEq(navPoolPerShare.raw(), 1, "NAV should be stored as 1 raw");
        assertEq(issuedAt, 1, "Should be issued at epoch 1");
    }

    /// @dev Tests revokeShares() with zero price
    function testRevokeSharesZeroPrice() public {
        batchRequestManager.requestRedeem(poolId, scId, MIN_REQUEST_AMOUNT_SHARES, investor, USDC);
        batchRequestManager.approveRedeems(
            poolId,
            scId,
            USDC,
            _nowRedeem(USDC),
            MIN_REQUEST_AMOUNT_SHARES,
            d18(0) // Zero price
        );

        // Revoke shares with non-zero NAV but zero price
        vm.expectEmit();
        emit IBatchRequestManager.RevokeShares(
            poolId,
            scId,
            USDC,
            1,
            d18(1),
            d18(0),
            MIN_REQUEST_AMOUNT_SHARES,
            0,
            1 // Pool payout = NAV * shares = 1 * 1e18 = 1
        );
        batchRequestManager.revokeShares(poolId, scId, USDC, _nowRevoke(USDC), d18(1), SHARE_HOOK_GAS);

        (,, D18 pricePoolPerAsset,, uint128 payoutAssetAmount, uint64 revokedAt) =
            batchRequestManager.epochRedeemAmounts(scId, USDC, 1);
        assertEq(pricePoolPerAsset.raw(), 0, "Price should be zero");
        assertEq(payoutAssetAmount, 0, "Asset payout should be zero due to zero price");
        assertEq(revokedAt, 1, "Should be revoked at epoch 1");
    }
}

///@dev Contains all deposit tests which deal with rounding edge cases
contract BatchRequestManagerRoundingEdgeCasesDeposit is BatchRequestManagerBaseTest {
    using MathLib for *;

    uint128 constant MIN_REQUEST_AMOUNT_OTHER_STABLE = DENO_OTHER_STABLE;
    uint128 constant MAX_REQUEST_AMOUNT_OTHER_STABLE = 1e24;
    bytes32 constant INVESTOR_A = bytes32("investorA");
    bytes32 constant INVESTOR_B = bytes32("investorB");
    bytes32 constant INVESTOR_C = bytes32("investorC");

    function _approveAllDepositsAndIssue(uint128 approvedAssetAmount, D18 navPerShare)
        private
        returns (uint128 issuedShares)
    {
        uint256 approveCost = batchRequestManager.approveDeposits(
            poolId, scId, OTHER_STABLE, _nowDeposit(OTHER_STABLE), approvedAssetAmount, _pricePoolPerAsset(OTHER_STABLE)
        );
        assertEq(approveCost, 1000, "Should return callback cost");

        vm.recordLogs();
        uint256 issueCost =
            batchRequestManager.issueShares(poolId, scId, OTHER_STABLE, _nowIssue(OTHER_STABLE), navPerShare, 0);
        assertEq(issueCost, 1000, "Should return callback cost");

        (issuedShares,,) = _extractIssueSharesEvent();
        (,,,, D18 storedNav, uint64 issuedAt) =
            batchRequestManager.epochInvestAmounts(scId, OTHER_STABLE, _nowIssue(OTHER_STABLE) - 1);
        assertEq(storedNav.raw(), navPerShare.raw(), "NAV mismatch in storage");
        assertGt(issuedAt, 0, "Should be issued");
    }

    /// @dev Investors cannot claim the single issued share atom (one of smallest denomination of share) but still pay
    function testClaimDepositSingleShareAtom() public {
        uint128 approvedAssetAmount = DENO_OTHER_STABLE;
        uint128 depositAmountA = 1;
        uint128 depositAmountB = approvedAssetAmount - depositAmountA;
        D18 navPerShare = d18(_intoPoolAmount(OTHER_STABLE, approvedAssetAmount), 1);

        batchRequestManager.requestDeposit(poolId, scId, depositAmountA, INVESTOR_A, OTHER_STABLE);
        batchRequestManager.requestDeposit(poolId, scId, depositAmountB, INVESTOR_B, OTHER_STABLE);

        uint128 issuedShares = _approveAllDepositsAndIssue(approvedAssetAmount, navPerShare);
        assertEq(issuedShares, 1, "Should issue exactly 1 share");

        (uint128 claimedA, uint128 paymentA, uint128 cancelledA,) =
            batchRequestManager.claimDeposit(poolId, scId, INVESTOR_A, OTHER_STABLE);
        (uint128 claimedB, uint128 paymentB, uint128 cancelledB,) =
            batchRequestManager.claimDeposit(poolId, scId, INVESTOR_B, OTHER_STABLE);

        assertEq(claimedA, claimedB, "Claimed shares should be equal");
        assertEq(claimedA + claimedB + 1, issuedShares, "System should have 1 share class token atom surplus");
        assertEq(paymentA, depositAmountA, "Payment A should never be zero");
        assertEq(paymentB, depositAmountB, "Payment B should never be zero");
        assertEq(cancelledA + cancelledB, 0, "No queued cancellation");
        assertEq(batchRequestManager.pendingDeposit(scId, OTHER_STABLE), 0, "Pending deposit should be zero");

        _assertDepositRequestEq(OTHER_STABLE, INVESTOR_A, UserOrder(0, 2));
        _assertDepositRequestEq(OTHER_STABLE, INVESTOR_B, UserOrder(0, 2));
    }

    /// @dev Investors can claim 50% rounded down of an uneven number of shares => 1 share atom surplus in system
    function testClaimDepositEvenInvestorsUnevenClaimable() public {
        uint128 approvedAssetAmount = 100 * DENO_OTHER_STABLE;
        uint128 depositAmountA = 49 * approvedAssetAmount / 100;
        uint128 depositAmountB = 51 * approvedAssetAmount / 100;
        D18 navPerShare = d18(_intoPoolAmount(OTHER_STABLE, approvedAssetAmount), 11);

        batchRequestManager.requestDeposit(poolId, scId, depositAmountA, INVESTOR_A, OTHER_STABLE);
        batchRequestManager.requestDeposit(poolId, scId, depositAmountB, INVESTOR_B, OTHER_STABLE);

        uint128 issuedShares = _approveAllDepositsAndIssue(approvedAssetAmount, navPerShare);
        assertEq(issuedShares, 11, "Should issue exactly 11 shares");

        (uint128 claimedA, uint128 paymentA, uint128 cancelledA,) =
            batchRequestManager.claimDeposit(poolId, scId, INVESTOR_A, OTHER_STABLE);
        (uint128 claimedB, uint128 paymentB, uint128 cancelledB,) =
            batchRequestManager.claimDeposit(poolId, scId, INVESTOR_B, OTHER_STABLE);

        assertEq(claimedA, claimedB, "Claimed shares should be equal");
        assertEq(claimedA + claimedB + 1, issuedShares, "System should have 1 share class token atom surplus");
        assertEq(paymentA, depositAmountA, "Payment A should never be zero");
        assertEq(paymentB, depositAmountB, "Payment B should never be zero");
        assertEq(cancelledA + cancelledB, 0, "No queued cancellation");
    }

    /// @dev Investors can claim 1/3 of an even number of shares => 1 share atom surplus in system
    function testClaimDepositUnevenInvestorsEvenClaimable() public {
        uint128 approvedAssetAmount = 100 * DENO_OTHER_STABLE;
        uint128 depositAmountA = 30 * approvedAssetAmount / 100;
        uint128 depositAmountB = 31 * approvedAssetAmount / 100;
        uint128 depositAmountC = 39 * approvedAssetAmount / 100;
        D18 navPerShare = d18(_intoPoolAmount(OTHER_STABLE, approvedAssetAmount), 10);

        batchRequestManager.requestDeposit(poolId, scId, depositAmountA, INVESTOR_A, OTHER_STABLE);
        batchRequestManager.requestDeposit(poolId, scId, depositAmountB, INVESTOR_B, OTHER_STABLE);
        batchRequestManager.requestDeposit(poolId, scId, depositAmountC, INVESTOR_C, OTHER_STABLE);

        uint128 issuedShares = _approveAllDepositsAndIssue(approvedAssetAmount, navPerShare);
        assertEq(issuedShares, 10, "Should issue exactly 10 shares");

        (uint128 claimedA, uint128 paymentA, uint128 cancelledA,) =
            batchRequestManager.claimDeposit(poolId, scId, INVESTOR_A, OTHER_STABLE);
        (uint128 claimedB, uint128 paymentB, uint128 cancelledB,) =
            batchRequestManager.claimDeposit(poolId, scId, INVESTOR_B, OTHER_STABLE);
        (uint128 claimedC, uint128 paymentC, uint128 cancelledC,) =
            batchRequestManager.claimDeposit(poolId, scId, INVESTOR_C, OTHER_STABLE);

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

    /// @dev Proves that for any deposit request, the difference between payment calculated with
    /// rounding down (actual) vs rounding up (theoretical) is at most 1 atom
    function testPaymentDiffRoundedDownVsUpAtMostOne(
        uint128 depositAmountA_,
        uint128 depositAmountB_,
        uint128 approvalRatio_
    ) public {
        // Bound deposit amounts to reasonable ranges
        depositAmountA_ =
            uint128(bound(depositAmountA_, MIN_REQUEST_AMOUNT_OTHER_STABLE, MAX_REQUEST_AMOUNT_OTHER_STABLE / 2));
        depositAmountB_ =
            uint128(bound(depositAmountB_, MIN_REQUEST_AMOUNT_OTHER_STABLE, MAX_REQUEST_AMOUNT_OTHER_STABLE / 2));
        approvalRatio_ = uint128(bound(approvalRatio_, 1, 100));
        uint128 depositAmountA = depositAmountA_;
        uint128 depositAmountB = depositAmountB_;
        uint128 totalDeposit = depositAmountA + depositAmountB;
        uint128 approvedAssetAmount =
            (totalDeposit * approvalRatio_ / 100).max(MIN_REQUEST_AMOUNT_OTHER_STABLE).toUint128();
        D18 navPerShare = d18(_intoPoolAmount(OTHER_STABLE, approvedAssetAmount), 100 * DENO_POOL);

        batchRequestManager.requestDeposit(poolId, scId, depositAmountA, INVESTOR_A, OTHER_STABLE);
        batchRequestManager.requestDeposit(poolId, scId, depositAmountB, INVESTOR_B, OTHER_STABLE);
        uint128 issuedShares = _approveAllDepositsAndIssue(approvedAssetAmount, navPerShare);

        (uint128 claimedSharesA, uint128 paymentAssetA,,) =
            batchRequestManager.claimDeposit(poolId, scId, INVESTOR_A, OTHER_STABLE);
        (uint128 claimedSharesB, uint128 paymentAssetB,,) =
            batchRequestManager.claimDeposit(poolId, scId, INVESTOR_B, OTHER_STABLE);

        // Calculate theoretical payments with rounding up
        uint128 paymentAssetARoundedUp =
            depositAmountA.mulDiv(approvedAssetAmount, totalDeposit, MathLib.Rounding.Up).toUint128();
        uint128 paymentAssetBRoundedUp =
            depositAmountB.mulDiv(approvedAssetAmount, totalDeposit, MathLib.Rounding.Up).toUint128();

        // Assert that the difference between rounded down and rounded up payment is at most 1
        assertApproxEqAbs(paymentAssetARoundedUp, paymentAssetA, 1, "Investor A payment diff should be at most 1");
        assertApproxEqAbs(paymentAssetBRoundedUp, paymentAssetB, 1, "Investor B payment diff should be at most 1");

        // Assert that the sum of payments equals the total approved amount (or is off by at most 1)
        assertApproxEqAbs(
            paymentAssetA + paymentAssetB,
            approvedAssetAmount,
            1,
            "Sum of actual payments should not exceed approvedAmount with at most 1 delta"
        );

        // The sum of rounded-up payments might exceed the approved amount by at most the number of investors
        assertApproxEqAbs(
            paymentAssetARoundedUp + paymentAssetBRoundedUp,
            approvedAssetAmount,
            2,
            "Sum of rounded-up payments should not exceed approvedAmount + 2"
        );

        // Verify that the total shares issued matches the sum of claimed shares (accounting for dust)
        uint128 totalClaimedShares = claimedSharesA + claimedSharesB;
        assertApproxEqAbs(issuedShares, totalClaimedShares, 1e8 + 1, "Share dust should be at most 1e8");
    }

    /// @dev One investor pays nothing despite having non-zero pending amount, while the other claims almost all shares.
    function testInvestorPaysNothingOtherClaimsAlmostAll() public {
        uint128 depositAmountA = 100;
        uint128 depositAmountB = 1000 * DENO_OTHER_STABLE;
        uint128 totalDeposit = depositAmountA + depositAmountB;

        // Approve slightly less than the total deposit (by exactly 1 unit)
        uint128 approvedAssetAmount = (totalDeposit - depositAmountA) / depositAmountA;
        D18 navPerShare = d18(_intoPoolAmount(OTHER_STABLE, approvedAssetAmount), 100 * DENO_POOL);
        assertEq(navPerShare.raw(), 1e15, "d18(1e18, 1e20) = 1e16");

        batchRequestManager.requestDeposit(poolId, scId, depositAmountA, INVESTOR_A, OTHER_STABLE);
        batchRequestManager.requestDeposit(poolId, scId, depositAmountB, INVESTOR_B, OTHER_STABLE);
        uint128 issuedShares = _approveAllDepositsAndIssue(approvedAssetAmount, navPerShare);

        (uint128 claimedSharesA, uint128 paymentAssetA,,) =
            batchRequestManager.claimDeposit(poolId, scId, INVESTOR_A, OTHER_STABLE);
        (uint128 claimedSharesB, uint128 paymentAssetB,,) =
            batchRequestManager.claimDeposit(poolId, scId, INVESTOR_B, OTHER_STABLE);

        // Investor A should pay nothing and get no shares
        assertEq(paymentAssetA, 0, "Investor A should pay nothing due to rounding");
        assertEq(claimedSharesA, 0, "Investor A should get no shares");
        uint128 paymentAssetARoundedUp =
            depositAmountA.mulDiv(approvedAssetAmount, totalDeposit, MathLib.Rounding.Up).toUint128();
        assertApproxEqAbs(
            paymentAssetARoundedUp, paymentAssetA, 1, "Diff between paymentA rounded up and down should be at most 1"
        );

        // Investor B should pay almost all and get almost all shares
        assertEq(
            paymentAssetB, approvedAssetAmount - 1, "Investor B should pay the entire approved amount minus 1 atom"
        );
        // NOTE: pool(payB) / navPerShare = ((1e19 - 1e4) * 1e18) / 1e15 = 1e20 - 1e7 = issuedShares - 1e7
        assertEq(claimedSharesB, issuedShares - 1e7, "Investor B should get all shares minus 1e5");

        // Check remaining state
        _assertDepositRequestEq(OTHER_STABLE, INVESTOR_A, UserOrder(depositAmountA, 2));
        _assertDepositRequestEq(OTHER_STABLE, INVESTOR_B, UserOrder(depositAmountB - paymentAssetB, 2));

        // 1e7 shares should remain unclaimed in the system
        assertEq(claimedSharesA + claimedSharesB + 1e7, issuedShares, "System should have 1 share atom surplus");
    }
}

///@dev Contains all redeem tests which deal with rounding edge cases
contract BatchRequestManagerPoolManagerPermissionsTest is BatchRequestManagerBaseTest {
    address poolManager;

    function setUp() public override {
        super.setUp();

        poolManager = makeAddr("poolManager");
        hubRegistryMock.updateManager(poolId, poolManager, true);
    }

    function testApproveDepositsAsManager() public {
        batchRequestManager.requestDeposit(poolId, scId, MIN_REQUEST_AMOUNT_USDC, investor, USDC);

        vm.prank(poolManager);
        uint256 cost = batchRequestManager.approveDeposits(
            poolId, scId, USDC, _nowDeposit(USDC), MIN_REQUEST_AMOUNT_USDC, _pricePoolPerAsset(USDC)
        );

        assertEq(cost, CB_GAS_COST, "Should return callback cost");
        assertEq(batchRequestManager.pendingDeposit(scId, USDC), 0, "Pending should be cleared");

        (, uint128 approvedAssetAmount,,,,) = batchRequestManager.epochInvestAmounts(scId, USDC, 1);
        assertEq(approvedAssetAmount, MIN_REQUEST_AMOUNT_USDC, "Should approve correct amount");
    }

    function testApproveRedeemsAsManager() public {
        batchRequestManager.requestRedeem(poolId, scId, MIN_REQUEST_AMOUNT_SHARES, investor, USDC);

        vm.prank(poolManager);
        batchRequestManager.approveRedeems(
            poolId, scId, USDC, _nowRedeem(USDC), MIN_REQUEST_AMOUNT_SHARES, _pricePoolPerAsset(USDC)
        );

        assertEq(batchRequestManager.pendingRedeem(scId, USDC), 0, "Pending should be cleared");
        (uint128 approvedShareAmount,,,,,) = batchRequestManager.epochRedeemAmounts(scId, USDC, 1);
        assertEq(approvedShareAmount, MIN_REQUEST_AMOUNT_SHARES, "Should approve correct amount");
    }

    function testIssueSharesAsManager() public {
        _depositAndApprove(MIN_REQUEST_AMOUNT_USDC, MIN_REQUEST_AMOUNT_USDC);

        vm.prank(poolManager);
        uint256 cost = batchRequestManager.issueShares(poolId, scId, USDC, _nowIssue(USDC), d18(1), SHARE_HOOK_GAS);

        assertEq(cost, CB_GAS_COST, "Should return callback cost");
        assertEq(_nowIssue(USDC), 2, "Issue epoch should advance");
    }

    function testRevokeSharesAsManager() public {
        _redeemAndApprove(MIN_REQUEST_AMOUNT_SHARES, MIN_REQUEST_AMOUNT_SHARES, 1e18);

        vm.prank(poolManager);
        uint256 cost = batchRequestManager.revokeShares(poolId, scId, USDC, _nowRevoke(USDC), d18(1), SHARE_HOOK_GAS);

        assertEq(cost, CB_GAS_COST, "Should return callback cost");
        assertEq(_nowRevoke(USDC), 2, "Revoke epoch should advance");
    }

    function testForceCancelDepositRequestAsManager() public {
        batchRequestManager.requestDeposit(poolId, scId, MIN_REQUEST_AMOUNT_USDC, investor, USDC);
        batchRequestManager.cancelDepositRequest(poolId, scId, investor, USDC);
        batchRequestManager.requestDeposit(poolId, scId, MIN_REQUEST_AMOUNT_USDC, investor, USDC);

        vm.prank(poolManager);
        uint256 cost = batchRequestManager.forceCancelDepositRequest(poolId, scId, investor, USDC);

        assertEq(cost, 0, "Should return 0 cost as no immediate callback");
        (uint128 pending,) = batchRequestManager.depositRequest(scId, USDC, investor);
        assertEq(pending, 0, "Request should be cancelled");
    }

    function testForceCancelRedeemRequestAsManager() public {
        batchRequestManager.requestRedeem(poolId, scId, MIN_REQUEST_AMOUNT_SHARES, investor, USDC);
        batchRequestManager.cancelRedeemRequest(poolId, scId, investor, USDC);
        batchRequestManager.requestRedeem(poolId, scId, MIN_REQUEST_AMOUNT_SHARES, investor, USDC);

        vm.prank(poolManager);
        uint256 cost = batchRequestManager.forceCancelRedeemRequest(poolId, scId, investor, USDC);

        assertEq(cost, 0, "Should return 0 cost as no immediate callback");
        (uint128 pending,) = batchRequestManager.redeemRequest(scId, USDC, investor);
        assertEq(pending, 0, "Request should be cancelled");
    }

    function testMultipleManagersCanManageSamePool() public {
        address poolManager2 = makeAddr("poolManager2");
        hubRegistryMock.updateManager(poolId, poolManager2, true);

        batchRequestManager.requestDeposit(poolId, scId, MIN_REQUEST_AMOUNT_USDC, investor, USDC);

        vm.prank(poolManager2);
        uint256 cost = batchRequestManager.approveDeposits(
            poolId, scId, USDC, _nowDeposit(USDC), MIN_REQUEST_AMOUNT_USDC, _pricePoolPerAsset(USDC)
        );
        assertEq(cost, CB_GAS_COST, "Manager 2 should be able to approve");
    }

    function testManagerPermissionRevocation() public {
        batchRequestManager.requestDeposit(poolId, scId, MIN_REQUEST_AMOUNT_USDC, investor, USDC);

        hubRegistryMock.updateManager(poolId, poolManager, false);

        vm.prank(poolManager);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        batchRequestManager.approveDeposits(poolId, scId, USDC, 1, 1, d18(1));
    }
}

contract BatchRequestManagerRoundingEdgeCasesRedeem is BatchRequestManagerBaseTest {
    using MathLib for *;

    bytes32 constant INVESTOR_A = bytes32("investorA");
    bytes32 constant INVESTOR_B = bytes32("investorB");
    bytes32 constant INVESTOR_C = bytes32("investorC");

    uint128 constant TOTAL_ISSUANCE = 1000 * DENO_POOL;

    // 100 OTHER_STABLE = 1 POOL leads to max OTHER_STABLE precision of 100
    // NOTE: If 1 OTHER_STABLE equalled 100 POOL, max OTHER_STABLE precision would be 1
    // This originates from the price conversion which does base * exponentQuote / exponentBase
    uint128 constant MAX_OTHER_STABLE_PRECISION = OTHER_STABLE_PER_POOL;

    function _approveAllRedeemsAndRevoke(uint128 approvedShares, uint128 expectedAssetPayout, D18 navPerShare)
        private
        returns (uint128 actualAssetPayout)
    {
        batchRequestManager.approveRedeems(
            poolId, scId, OTHER_STABLE, _nowRedeem(OTHER_STABLE), approvedShares, _pricePoolPerAsset(OTHER_STABLE)
        );

        // Record logs and revoke shares
        vm.recordLogs();
        uint256 revokeCost =
            batchRequestManager.revokeShares(poolId, scId, OTHER_STABLE, _nowRevoke(OTHER_STABLE), navPerShare, 0);
        assertEq(revokeCost, 1000, "Should return callback cost");

        // Extract payout from event
        (, actualAssetPayout,,,) = _extractRevokeSharesEvent();
        assertEq(actualAssetPayout, expectedAssetPayout, "Mismatch in expected asset payout");
    }

    /// @dev Helper function to calculate rounded up payment to avoid stack too deep
    function _calculateRoundedUpPayment(uint128 shares, uint128 approved, uint128 total)
        private
        pure
        returns (uint128)
    {
        return shares.mulDiv(approved, total, MathLib.Rounding.Up).toUint128();
    }

    /// @dev Investors cannot claim anything despite non-zero pending amounts
    function testClaimRedeemSingleAssetAtom() public {
        uint128 approvedShares = DENO_POOL / DENO_OTHER_STABLE; // 1e6
        uint128 assetPayout = 1;
        uint128 redeemAmountA = 1;
        uint128 redeemAmountB = approvedShares - redeemAmountA;
        uint128 poolPayout = _intoPoolAmount(OTHER_STABLE, assetPayout); // 1
        D18 navPerShare = d18(poolPayout, approvedShares); // = 1e18

        batchRequestManager.requestRedeem(poolId, scId, redeemAmountA, INVESTOR_A, OTHER_STABLE);
        batchRequestManager.requestRedeem(poolId, scId, redeemAmountB, INVESTOR_B, OTHER_STABLE);
        _approveAllRedeemsAndRevoke(approvedShares, assetPayout, navPerShare);

        (uint128 claimedA, uint128 paymentA,,) = batchRequestManager.claimRedeem(poolId, scId, INVESTOR_A, OTHER_STABLE);
        (uint128 claimedB, uint128 paymentB,,) = batchRequestManager.claimRedeem(poolId, scId, INVESTOR_B, OTHER_STABLE);

        assertEq(claimedA, claimedB, "Both investors should have claimed same amount");
        assertEq(claimedA + claimedB, 0, "Claimed amount should be zero for both investors");
        assertEq(paymentA, redeemAmountA, "Payment A should never be zero");
        assertEq(paymentB, redeemAmountB, "Payment B should never be zero");
        assertEq(batchRequestManager.pendingRedeem(scId, OTHER_STABLE), 0, "Pending redeem should be zero");

        _assertRedeemRequestEq(OTHER_STABLE, INVESTOR_A, UserOrder(0, 2));
        _assertRedeemRequestEq(OTHER_STABLE, INVESTOR_B, UserOrder(0, 2));
    }

    /// @dev Investors can claim 50% rounded down of an uneven number of asset amount => asset amount surplus in
    /// system
    function testClaimRedeemEvenInvestorsUnevenClaimable() public {
        uint128 approvedShares = DENO_POOL / DENO_OTHER_STABLE;
        uint128 assetPayout = 11;
        uint128 redeemAmountA = 49 * approvedShares / 100;
        uint128 redeemAmountB = 51 * approvedShares / 100;
        uint128 poolPayout = _intoPoolAmount(OTHER_STABLE, assetPayout);
        D18 navPerShare = d18(poolPayout, approvedShares);

        batchRequestManager.requestRedeem(poolId, scId, redeemAmountA, INVESTOR_A, OTHER_STABLE);
        batchRequestManager.requestRedeem(poolId, scId, redeemAmountB, INVESTOR_B, OTHER_STABLE);
        _approveAllRedeemsAndRevoke(approvedShares, assetPayout, navPerShare);

        (uint128 claimedA, uint128 paymentA, uint128 cancelledA,) =
            batchRequestManager.claimRedeem(poolId, scId, INVESTOR_A, OTHER_STABLE);
        (uint128 claimedB, uint128 paymentB, uint128 cancelledB,) =
            batchRequestManager.claimRedeem(poolId, scId, INVESTOR_B, OTHER_STABLE);

        assertEq(claimedA, claimedB, "Claimed asset amount should be equal");
        assertEq(claimedA + claimedB + 1, assetPayout, "System should have 1 amount surplus");
        assertEq(paymentA, redeemAmountA, "Payment A should never be zero");
        assertEq(paymentB, redeemAmountB, "Payment B should never be zero");
        assertEq(batchRequestManager.pendingRedeem(scId, OTHER_STABLE), 0, "Pending redeem should not have reset");
        assertEq(cancelledA + cancelledB, 0, "No queued cancellation");

        _assertRedeemRequestEq(OTHER_STABLE, INVESTOR_A, UserOrder(0, 2));
        _assertRedeemRequestEq(OTHER_STABLE, INVESTOR_B, UserOrder(0, 2));
    }

    /// @dev Investors can claim 50% rounded down of an uneven number of asset amount =>  asset amount surplus in
    /// system
    function testClaimRedeemUnevenInvestorsEvenClaimable() public {
        uint128 approvedShares = DENO_POOL / DENO_OTHER_STABLE;
        uint128 assetPayout = 10;
        uint128 redeemAmountA = 30 * approvedShares / 100;
        uint128 redeemAmountB = 31 * approvedShares / 100;
        uint128 redeemAmountC = 39 * approvedShares / 100;
        uint128 poolPayout = _intoPoolAmount(OTHER_STABLE, assetPayout); // 10
        D18 navPerShare = d18(poolPayout, approvedShares);

        batchRequestManager.requestRedeem(poolId, scId, redeemAmountA, INVESTOR_A, OTHER_STABLE);
        batchRequestManager.requestRedeem(poolId, scId, redeemAmountB, INVESTOR_B, OTHER_STABLE);
        batchRequestManager.requestRedeem(poolId, scId, redeemAmountC, INVESTOR_C, OTHER_STABLE);
        _approveAllRedeemsAndRevoke(approvedShares, assetPayout, navPerShare);

        (uint128 claimedA, uint128 paymentA,,) = batchRequestManager.claimRedeem(poolId, scId, INVESTOR_A, OTHER_STABLE);
        (uint128 claimedB, uint128 paymentB,,) = batchRequestManager.claimRedeem(poolId, scId, INVESTOR_B, OTHER_STABLE);
        (uint128 claimedC, uint128 paymentC,,) = batchRequestManager.claimRedeem(poolId, scId, INVESTOR_C, OTHER_STABLE);

        assertEq(claimedA, claimedB, "Claimed asset amount should be equal");
        assertEq(claimedB, claimedC, "Claimed asset amount should be equal");
        assertEq(claimedA + claimedB + claimedC + 1, assetPayout, "System should have 1 amount surplus");
        assertEq(paymentA, redeemAmountA, "Payment A should never be zero");
        assertEq(paymentB, redeemAmountB, "Payment B should never be zero");
        assertEq(paymentC, redeemAmountC, "Payment C should never be zero");
        assertEq(batchRequestManager.pendingRedeem(scId, OTHER_STABLE), 0, "Pending redeem should not have reset");

        _assertRedeemRequestEq(OTHER_STABLE, INVESTOR_A, UserOrder(0, 2));
        _assertRedeemRequestEq(OTHER_STABLE, INVESTOR_B, UserOrder(0, 2));
        _assertRedeemRequestEq(OTHER_STABLE, INVESTOR_C, UserOrder(0, 2));
    }

    /// @dev Proves that for any redeem request, the difference between payment calculated with
    /// rounding down (actual) vs rounding up (theoretical) is at most 1 atom
    function testRedeemPaymentDiffRoundedDownVsUpAtMostOne(
        uint128 redeemSharesA_,
        uint128 redeemSharesB_,
        uint128 approvalRatio_,
        uint128 navPerShareValue_
    ) public {
        // Bound inputs to reasonable ranges
        redeemSharesA_ = uint128(bound(redeemSharesA_, MIN_REQUEST_AMOUNT_SHARES, TOTAL_ISSUANCE / 4));
        redeemSharesB_ = uint128(bound(redeemSharesB_, MIN_REQUEST_AMOUNT_SHARES, TOTAL_ISSUANCE / 4));
        approvalRatio_ = uint128(bound(approvalRatio_, 1, 100));
        navPerShareValue_ = uint128(bound(navPerShareValue_, 1e15, 1e20));

        uint128 approvedShares;
        uint128 expectedAssetPayout;
        {
            D18 navPerShare = d18(navPerShareValue_);
            uint128 totalRedeemShares = redeemSharesA_ + redeemSharesB_;
            approvedShares = (totalRedeemShares * approvalRatio_ / 100).max(MIN_REQUEST_AMOUNT_SHARES).toUint128();
            uint128 poolPayout = navPerShare.mulUint128(approvedShares, MathLib.Rounding.Down);
            expectedAssetPayout = _intoAssetAmount(OTHER_STABLE, poolPayout);

            batchRequestManager.requestRedeem(poolId, scId, redeemSharesA_, INVESTOR_A, OTHER_STABLE);
            batchRequestManager.requestRedeem(poolId, scId, redeemSharesB_, INVESTOR_B, OTHER_STABLE);
        }

        uint128 actualAssetPayout =
            _approveAllRedeemsAndRevoke(approvedShares, expectedAssetPayout, d18(navPerShareValue_));

        // Claim phase with payment verification
        uint128 payoutAssetA;
        uint128 paymentSharesA;
        uint128 payoutAssetB;
        uint128 paymentSharesB;
        {
            (payoutAssetA, paymentSharesA,,) = batchRequestManager.claimRedeem(poolId, scId, INVESTOR_A, OTHER_STABLE);
            (payoutAssetB, paymentSharesB,,) = batchRequestManager.claimRedeem(poolId, scId, INVESTOR_B, OTHER_STABLE);
        }

        // Verify rounding differences
        {
            uint128 totalRedeemShares = redeemSharesA_ + redeemSharesB_;
            uint128 paymentSharesARoundedUp =
                _calculateRoundedUpPayment(redeemSharesA_, approvedShares, totalRedeemShares);
            uint128 paymentSharesBRoundedUp =
                _calculateRoundedUpPayment(redeemSharesB_, approvedShares, totalRedeemShares);

            assertApproxEqAbs(
                paymentSharesA, paymentSharesARoundedUp, 1, "Investor A share payment diff should be at most 1"
            );
            assertApproxEqAbs(
                paymentSharesB, paymentSharesBRoundedUp, 1, "Investor B share payment diff should be at most 1"
            );

            assertApproxEqAbs(
                paymentSharesARoundedUp + paymentSharesBRoundedUp,
                approvedShares,
                2,
                "Sum of rounded-up payments should not exceed approvedShares + 2"
            );
        }

        // Verify totals
        assertApproxEqAbs(
            paymentSharesA + paymentSharesB,
            approvedShares,
            1,
            "Sum of actual share payments should be approvedShares at most 1 delta"
        );

        assertApproxEqAbs(payoutAssetA + payoutAssetB, actualAssetPayout, 2, "Asset payout dust should be at most 2");
    }
}

contract BatchRequestManagerERC165Support is BatchRequestManagerBaseTest {
    function testERC165SupportBRM(bytes4 unsupportedInterfaceId) public view {
        bytes4 erc165 = 0x01ffc9a7;
        bytes4 hubRequestManager = 0x2f6c33bf;
        bytes4 hubRequestManagerNotifications = 0x260efff8;
        bytes4 batchRequestManagerID = 0x5f64b1fa;

        vm.assume(
            unsupportedInterfaceId != erc165 && unsupportedInterfaceId != hubRequestManager
                && unsupportedInterfaceId != hubRequestManagerNotifications
                && unsupportedInterfaceId != batchRequestManagerID
        );

        assertEq(type(IERC165).interfaceId, erc165);
        assertEq(type(IHubRequestManager).interfaceId, hubRequestManager);
        assertEq(type(IHubRequestManagerNotifications).interfaceId, hubRequestManagerNotifications);
        assertEq(type(IBatchRequestManager).interfaceId, batchRequestManagerID);

        assertEq(batchRequestManager.supportsInterface(erc165), true);
        assertEq(batchRequestManager.supportsInterface(hubRequestManager), true);
        assertEq(batchRequestManager.supportsInterface(hubRequestManagerNotifications), true);
        assertEq(batchRequestManager.supportsInterface(batchRequestManagerID), true);

        assertEq(batchRequestManager.supportsInterface(unsupportedInterfaceId), false);
    }
}
