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

import {HubRequestManager} from "../../../src/vaults/HubRequestManager.sol";
import {IHubRegistry} from "../../../src/hub/interfaces/IHubRegistry.sol";
import {
    IHubRequestManager,
    EpochInvestAmounts,
    EpochRedeemAmounts,
    UserOrder,
    QueuedOrder,
    RequestType
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

abstract contract HubRequestManagerBaseTest is Test {
    using MathLib for uint128;
    using MathLib for uint256;
    using CastLib for string;
    using PricingLib for *;

    HubRequestManager public hubRequestManager;
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
        hubRequestManager = new HubRequestManager(IHubRegistry(hubRegistryMock), address(this));
        
        assertEq(IHubRegistry(hubRegistryMock).decimals(poolId), DECIMALS_POOL);
        assertEq(IHubRegistry(hubRegistryMock).decimals(USDC), DECIMALS_USDC);
        assertEq(IHubRegistry(hubRegistryMock).decimals(OTHER_STABLE), DECIMALS_OTHER_STABLE);
    }

    function _intoPoolAmount(AssetId assetId, uint128 amount) internal view returns (uint128) {
        return PricingLib.convertWithPrice(
            amount,
            IHubRegistry(hubRegistryMock).decimals(assetId),
            IHubRegistry(hubRegistryMock).decimals(poolId),
            d18(1)
        );
    }
    
    function _intoAssetAmount(AssetId assetId, uint128 amount) internal view returns (uint128) {
        return PricingLib.convertWithPrice(
            amount,
            IHubRegistry(hubRegistryMock).decimals(poolId),
            IHubRegistry(hubRegistryMock).decimals(assetId),
            d18(1)
        );
    }

    function _approveDeposits(uint128 approvedAssetAmount) internal returns (uint128, uint128) {
        uint32 nowDepositEpochId = hubRequestManager.nowDepositEpoch(scId, USDC);
        D18 pricePoolPerAsset = d18(1);
        
        return hubRequestManager.approveDeposits(
            poolId,
            scId,
            USDC,
            nowDepositEpochId,
            approvedAssetAmount,
            pricePoolPerAsset
        );
    }

    function _approveRedeems(uint128 approvedShareAmount) internal returns (uint128) {
        uint32 nowRedeemEpochId = hubRequestManager.nowRedeemEpoch(scId, USDC);
        D18 pricePoolPerAsset = d18(1);
        
        return hubRequestManager.approveRedeems(
            poolId,
            scId,
            USDC,
            nowRedeemEpochId,
            approvedShareAmount,
            pricePoolPerAsset
        );
    }
}

contract HubRequestManagerRequestsTest is HubRequestManagerBaseTest {
    function testRequestDeposit(uint128 amount) public {
        amount = uint128(bound(amount, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC));

        vm.expectEmit();
        emit IHubRequestManager.UpdateDepositRequest(
            poolId,
            scId,
            USDC,
            hubRequestManager.nowDepositEpoch(scId, USDC),
            investor,
            amount,
            amount,
            0,
            false
        );
        hubRequestManager.requestDeposit(poolId, scId, amount, investor, USDC);

        (uint128 pending, uint32 lastUpdate) = hubRequestManager.depositRequest(scId, USDC, investor);
        assertEq(pending, amount);
        assertEq(lastUpdate, hubRequestManager.nowDepositEpoch(scId, USDC));
        assertEq(hubRequestManager.pendingDeposit(scId, USDC), amount);
    }

    function testCancelDepositRequest(uint128 amount) public {
        amount = uint128(bound(amount, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC));

        // First make a deposit request
        hubRequestManager.requestDeposit(poolId, scId, amount, investor, USDC);

        // Cancel it
        uint128 cancelled = hubRequestManager.cancelDepositRequest(poolId, scId, investor, USDC);

        assertEq(cancelled, amount);
        assertEq(hubRequestManager.pendingDeposit(scId, USDC), 0);
        (uint128 pending,) = hubRequestManager.depositRequest(scId, USDC, investor);
        assertEq(pending, 0);
    }

    function testRequestRedeem(uint128 amount) public {
        amount = uint128(bound(amount, MIN_REQUEST_AMOUNT_SHARES, MAX_REQUEST_AMOUNT_SHARES));

        vm.expectEmit();
        emit IHubRequestManager.UpdateRedeemRequest(
            poolId,
            scId,
            USDC,
            hubRequestManager.nowRedeemEpoch(scId, USDC),
            investor,
            amount,
            amount,
            0,
            false
        );
        hubRequestManager.requestRedeem(poolId, scId, amount, investor, USDC);

        (uint128 pending, uint32 lastUpdate) = hubRequestManager.redeemRequest(scId, USDC, investor);
        assertEq(pending, amount);
        assertEq(lastUpdate, hubRequestManager.nowRedeemEpoch(scId, USDC));
        assertEq(hubRequestManager.pendingRedeem(scId, USDC), amount);
    }

    function testCancelRedeemRequest(uint128 amount) public {
        amount = uint128(bound(amount, MIN_REQUEST_AMOUNT_SHARES, MAX_REQUEST_AMOUNT_SHARES));

        // First make a redeem request
        hubRequestManager.requestRedeem(poolId, scId, amount, investor, USDC);

        // Cancel it
        uint128 cancelled = hubRequestManager.cancelRedeemRequest(poolId, scId, investor, USDC);

        assertEq(cancelled, amount);
        assertEq(hubRequestManager.pendingRedeem(scId, USDC), 0);
        (uint128 pending,) = hubRequestManager.redeemRequest(scId, USDC, investor);
        assertEq(pending, 0);
    }
}

contract HubRequestManagerEpochsTest is HubRequestManagerBaseTest {
    function testApproveDeposits(uint128 depositAmount, uint128 approvedAmount) public {
        depositAmount = uint128(bound(depositAmount, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC));
        approvedAmount = uint128(bound(approvedAmount, 1, depositAmount));

        // First make a deposit request
        hubRequestManager.requestDeposit(poolId, scId, depositAmount, investor, USDC);

        // Approve deposits
        (uint128 pendingAssetAmount, uint128 approvedPoolAmount) = _approveDeposits(approvedAmount);

        assertEq(pendingAssetAmount, depositAmount - approvedAmount);
        assertEq(approvedPoolAmount, _intoPoolAmount(USDC, approvedAmount));
        assertEq(hubRequestManager.pendingDeposit(scId, USDC), depositAmount - approvedAmount);
    }

    function testApproveRedeems(uint128 redeemAmount, uint128 approvedAmount) public {
        redeemAmount = uint128(bound(redeemAmount, MIN_REQUEST_AMOUNT_SHARES, MAX_REQUEST_AMOUNT_SHARES));
        approvedAmount = uint128(bound(approvedAmount, 1, redeemAmount));

        // First make a redeem request
        hubRequestManager.requestRedeem(poolId, scId, redeemAmount, investor, USDC);

        // Approve redeems
        uint128 pendingShareAmount = _approveRedeems(approvedAmount);

        assertEq(pendingShareAmount, redeemAmount - approvedAmount);
        assertEq(hubRequestManager.pendingRedeem(scId, USDC), redeemAmount - approvedAmount);
    }

    function testIssueShares(uint128 approvedAmount, uint128 navPoolPerShare) public {
        approvedAmount = uint128(bound(approvedAmount, MIN_REQUEST_AMOUNT_USDC, MAX_REQUEST_AMOUNT_USDC));
        navPoolPerShare = uint128(bound(navPoolPerShare, 1e15, 1e21)); // 0.001 to 1000 in D18

        // Setup: request, approve deposits
        hubRequestManager.requestDeposit(poolId, scId, approvedAmount, investor, USDC);
        _approveDeposits(approvedAmount);

        // Issue shares
        uint32 nowIssueEpochId = hubRequestManager.nowIssueEpoch(scId, USDC);
        (uint128 issuedShareAmount, uint128 depositAssetAmount, uint128 depositPoolAmount) =
            hubRequestManager.issueShares(poolId, scId, USDC, nowIssueEpochId, d18(navPoolPerShare));

        assertEq(depositAssetAmount, approvedAmount);
        assertEq(depositPoolAmount, _intoPoolAmount(USDC, approvedAmount));
        
        // Check issued share amount calculation
        uint128 expectedShares = PricingLib.assetToShareAmount(
            approvedAmount,
            IHubRegistry(hubRegistryMock).decimals(USDC),
            IHubRegistry(hubRegistryMock).decimals(poolId),
            d18(1), // pricePoolPerAsset
            d18(navPoolPerShare),
            MathLib.Rounding.Down
        );
        assertEq(issuedShareAmount, expectedShares);
    }

    function testRevokeShares(uint128 approvedAmount, uint128 navPoolPerShare) public {
        approvedAmount = uint128(bound(approvedAmount, MIN_REQUEST_AMOUNT_SHARES, MAX_REQUEST_AMOUNT_SHARES));
        navPoolPerShare = uint128(bound(navPoolPerShare, 1e15, 1e21)); // 0.001 to 1000 in D18

        // Setup: request, approve redeems
        hubRequestManager.requestRedeem(poolId, scId, approvedAmount, investor, USDC);
        _approveRedeems(approvedAmount);

        // Revoke shares
        uint32 nowRevokeEpochId = hubRequestManager.nowRevokeEpoch(scId, USDC);
        (uint128 revokedShareAmount, uint128 payoutAssetAmount, uint128 payoutPoolAmount) =
            hubRequestManager.revokeShares(poolId, scId, USDC, nowRevokeEpochId, d18(navPoolPerShare));

        assertEq(revokedShareAmount, approvedAmount);
        
        // Check payout calculations
        uint128 expectedPayoutPool = d18(navPoolPerShare).mulUint128(approvedAmount, MathLib.Rounding.Down);
        assertEq(payoutPoolAmount, expectedPayoutPool);
        
        uint128 expectedPayoutAsset = _intoAssetAmount(USDC, expectedPayoutPool);
        assertEq(payoutAssetAmount, expectedPayoutAsset);
    }
}

contract HubRequestManagerClaimingTest is HubRequestManagerBaseTest {
    function testClaimDepositBasic() public {
        uint128 depositAmount = 1000 * DENO_USDC;
        uint128 navPoolPerShare = uint128(d18(1).raw()); // 1:1 ratio

        // Setup: request, approve, issue
        hubRequestManager.requestDeposit(poolId, scId, depositAmount, investor, USDC);
        _approveDeposits(depositAmount);
        
        uint32 nowIssueEpochId = hubRequestManager.nowIssueEpoch(scId, USDC);
        hubRequestManager.issueShares(poolId, scId, USDC, nowIssueEpochId, d18(navPoolPerShare));

        // Claim deposit
        (uint128 payoutShareAmount, uint128 paymentAssetAmount, uint128 cancelledAssetAmount, bool canClaimAgain) =
            hubRequestManager.claimDeposit(poolId, scId, investor, USDC);

        assertEq(paymentAssetAmount, depositAmount);
        assertGt(payoutShareAmount, 0);
        assertEq(cancelledAssetAmount, 0);
        assertEq(canClaimAgain, false);
    }

    function testClaimRedeemBasic() public {
        uint128 redeemAmount = 1000 * DENO_POOL;
        uint128 navPoolPerShare = uint128(d18(1).raw()); // 1:1 ratio

        // Setup: request, approve, revoke
        hubRequestManager.requestRedeem(poolId, scId, redeemAmount, investor, USDC);
        _approveRedeems(redeemAmount);
        
        uint32 nowRevokeEpochId = hubRequestManager.nowRevokeEpoch(scId, USDC);
        hubRequestManager.revokeShares(poolId, scId, USDC, nowRevokeEpochId, d18(navPoolPerShare));

        // Claim redeem
        (uint128 payoutAssetAmount, uint128 paymentShareAmount, uint128 cancelledShareAmount, bool canClaimAgain) =
            hubRequestManager.claimRedeem(poolId, scId, investor, USDC);

        assertEq(paymentShareAmount, redeemAmount);
        assertGt(payoutAssetAmount, 0);
        assertEq(cancelledShareAmount, 0);
        assertEq(canClaimAgain, false);
    }
}

contract HubRequestManagerViewsTest is HubRequestManagerBaseTest {
    function testEpochViews() public {
        // Test initial epoch values
        assertEq(hubRequestManager.nowDepositEpoch(scId, USDC), 1);
        assertEq(hubRequestManager.nowIssueEpoch(scId, USDC), 1);
        assertEq(hubRequestManager.nowRedeemEpoch(scId, USDC), 1);
        assertEq(hubRequestManager.nowRevokeEpoch(scId, USDC), 1);
    }

    function testMaxClaims() public {
        // Test max claims when no requests
        assertEq(hubRequestManager.maxDepositClaims(scId, investor, USDC), 0);
        assertEq(hubRequestManager.maxRedeemClaims(scId, investor, USDC), 0);
    }
}