// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {SingleShareClass, Epoch, EpochRatio, UserOrder} from "src/SingleShareClass.sol";
import {PoolId} from "src/types/PoolId.sol";
import {D18, d18} from "src/types/D18.sol";
import {IERC7726Ext} from "src/interfaces/IERC7726.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {IShareClassManager} from "src/interfaces/IShareClassManager.sol";
import {IInvestorPermissions} from "src/interfaces/IInvestorPermissions.sol";
import {IPoolRegistry} from "src/interfaces/IPoolRegistry.sol";
import {IERC20Metadata} from "src/interfaces/IERC20Metadata.sol";

PoolId constant POOL_ID = PoolId.wrap(0x123);
bytes16 constant SHARE_CLASS_ID = bytes16("shareClassId");
address constant POOL_CURRENCY = address(840);
address constant USDC = address(0x0123456);
address constant OTHER_STABLE = address(0x01234567);
uint256 constant DENO_USDC = 10 ** 6;
uint256 constant DENO_OTHER_STABLE = 10 ** 12;
uint256 constant DENO_POOL = 10 ** 4;
uint256 constant MIN_REQUEST_AMOUNT = 1e10;
uint256 constant MAX_REQUEST_AMOUNT = 1e40;

contract PoolRegistryMock {
    function currency(PoolId) external pure returns (IERC20Metadata) {
        return IERC20Metadata(POOL_CURRENCY);
    }
}

contract EveryoneInvestor {
    function isFrozenInvestor(bytes16, address) external pure returns (bool) {
        return false;
    }

    function isUnfrozenInvestor(bytes16, address) external pure returns (bool) {
        return true;
    }
}

contract OracleMock is IERC7726Ext {
    using MathLib for uint256;

    uint256 private constant _ONE = 1e18;

    function getQuote(uint256 baseAmount, address base, address quote) external view returns (uint256 quoteAmount) {
        return baseAmount.mulDiv(this.getFactor(base, quote), 1e18);
    }

    function getFactor(address base, address quote) external pure returns (uint256 factor) {
        // NOTE: Implicitly refer to D18 factors, i.e. 0.1 = 1e17
        if (base == USDC && quote == OTHER_STABLE) {
            return _ONE.mulDiv(DENO_OTHER_STABLE, DENO_USDC);
        } else if (base == USDC && quote == POOL_CURRENCY) {
            return _ONE.mulDiv(DENO_POOL, DENO_USDC);
        } else if (base == OTHER_STABLE && quote == USDC) {
            return _ONE.mulDiv(DENO_USDC, DENO_OTHER_STABLE);
        } else if (base == OTHER_STABLE && quote == POOL_CURRENCY) {
            return _ONE.mulDiv(DENO_POOL, DENO_OTHER_STABLE);
        } else if (base == POOL_CURRENCY && quote == USDC) {
            return _ONE.mulDiv(DENO_USDC, DENO_POOL);
        } else if (base == POOL_CURRENCY && quote == OTHER_STABLE) {
            return _ONE.mulDiv(DENO_OTHER_STABLE, DENO_POOL);
        } else if (base == POOL_CURRENCY && quote == address(bytes20(SHARE_CLASS_ID))) {
            return _ONE;
        } else {
            revert("Unsupported factor pair");
        }
    }
}

// TODO(@wischli): Remove before merge
contract OracleMockTest is Test {
    using MathLib for uint256;

    OracleMock public oracleMock = new OracleMock();

    function testGetQuoteUsdcToPool() public view {
        uint256 amount = 1e7;

        assertEq(oracleMock.getQuote(amount, USDC, POOL_CURRENCY), 1e5);
        assertEq(oracleMock.getQuote(amount, POOL_CURRENCY, USDC), 1e9);
    }

    function testGetFactorUsdcToPool() public view {
        assertEq(oracleMock.getFactor(USDC, POOL_CURRENCY), 1e16);
        assertEq(oracleMock.getFactor(POOL_CURRENCY, USDC), 1e20);
    }

    function testGetQuoteOtherStableToPool() public view {
        uint256 amount = 1e20;

        assertEq(oracleMock.getQuote(amount, OTHER_STABLE, POOL_CURRENCY), 1e12);
        assertEq(oracleMock.getQuote(amount, POOL_CURRENCY, OTHER_STABLE), 1e28);
    }

    function testGetFactorOtherStableToPool() public view {
        assertEq(oracleMock.getFactor(OTHER_STABLE, POOL_CURRENCY), 1e10);
        assertEq(oracleMock.getFactor(POOL_CURRENCY, OTHER_STABLE), 1e26);
    }
}

abstract contract SingleShareClassBaseTest is Test {
    using MathLib for uint256;

    SingleShareClass public shareClass;
    IPoolRegistry public poolRegistry;
    IInvestorPermissions public investorPermissions;

    OracleMock oracleMock = new OracleMock();
    PoolRegistryMock poolRegistryMock = new PoolRegistryMock();
    EveryoneInvestor investorPermissionsMock = new EveryoneInvestor();

    PoolId poolId = PoolId.wrap(1);
    bytes16 shareClassId = SHARE_CLASS_ID;
    address poolRegistryAddress = makeAddr("poolRegistry");
    address investorPermissionsAddress = makeAddr("investorPermissions");
    address investor = makeAddr("investor");

    function setUp() public virtual {
        // Set bytecode of interfaces to mock
        vm.etch(poolRegistryAddress, address(poolRegistryMock).code);
        poolRegistry = IPoolRegistry(poolRegistryAddress);
        vm.etch(investorPermissionsAddress, address(investorPermissionsMock).code);
        investorPermissions = IInvestorPermissions(investorPermissionsAddress);

        shareClass = new SingleShareClass(address(this), address(poolRegistry), address(investorPermissions));
        shareClass.setShareClassId(poolId, shareClassId);
        shareClass.allowAsset(poolId, shareClassId, USDC);
        shareClass.allowAsset(poolId, shareClassId, OTHER_STABLE);
    }

    function _assertDepositRequestEq(bytes16 shareClassId_, address asset, address investor_, UserOrder memory expected)
        internal
        view
    {
        (uint32 lastUpdate, uint256 pending) = shareClass.depositRequests(shareClassId_, asset, investor_);

        assertEq(lastUpdate, expected.lastUpdate, "lastUpdate mismatch");
        assertEq(pending, expected.pending, "pending mismatch");
    }

    function _assertEpochEq(bytes16 shareClassId_, uint32 epochId, Epoch memory expected) internal view {
        (IERC7726Ext valuation, uint256 approvedDeposits, uint256 approvedShares) =
            shareClass.epochs(shareClassId_, epochId);

        assertEq(address(valuation), address(expected.valuation));
        assertEq(approvedDeposits, expected.approvedDeposits, "approveDeposits mismatch");
        assertEq(approvedShares, expected.approvedShares, "approvedShares mismatch");
    }

    function _assertEpochRatioEq(bytes16 shareClassId_, address assetId, uint32 epochId, EpochRatio memory expected)
        internal
        view
    {
        (D18 redeemRatio, D18 depositRatio, D18 assetToPoolQuote, D18 poolToShareQuote) =
            shareClass.epochRatios(shareClassId_, assetId, epochId);

        assertEq(poolToShareQuote.inner(), expected.poolToShareQuote.inner(), "poolToShareQuote mismatch");
        assertEq(redeemRatio.inner(), expected.redeemRatio.inner(), "redeemRatio mismatch");
        assertEq(depositRatio.inner(), expected.depositRatio.inner(), "depositRatio mismatch");
        assertEq(assetToPoolQuote.inner(), expected.assetToPoolQuote.inner(), "assetToPoolQuote mismatch");
    }
}

///@dev Contains all tests which require transient storage to not reset between calls
contract SingleShareClassTest is SingleShareClassBaseTest {
    using MathLib for uint256;

    function testDeployment(address nonWard) public view {
        vm.assume(
            nonWard != address(poolRegistry) && nonWard != address(investorPermissions) && nonWard != address(this)
        );

        assertEq(shareClass.poolRegistry(), address(poolRegistry));
        assertEq(shareClass.investorPermissions(), address(investorPermissions));
        assertEq(shareClass.shareClassIds(poolId), shareClassId);
        assertTrue(shareClass.isAllowedAsset(poolId, shareClassId, USDC));
        assertTrue(shareClass.isAllowedAsset(poolId, shareClassId, OTHER_STABLE));

        assertEq(shareClass.wards(address(this)), 1);
        assertEq(shareClass.wards(address(poolRegistry)), 0);
        assertEq(shareClass.wards(address(investorPermissions)), 0);

        assertEq(shareClass.wards(nonWard), 0);
    }

    function testAllowAsset() public {
        address assetId = makeAddr("asset");

        assertFalse(shareClass.isAllowedAsset(poolId, shareClassId, assetId));
        shareClass.allowAsset(poolId, shareClassId, assetId);
        assertTrue(shareClass.isAllowedAsset(poolId, shareClassId, assetId));
    }

    function testDisallowAsset() public {
        shareClass.disallowAsset(poolId, shareClassId, USDC);
        assertFalse(shareClass.isAllowedAsset(poolId, shareClassId, USDC));
    }

    function testRequestDeposit(uint256 amount) public {
        amount = uint256(bound(amount, MIN_REQUEST_AMOUNT, MAX_REQUEST_AMOUNT));

        assertEq(shareClass.pendingDeposits(shareClassId, USDC), 0);
        _assertDepositRequestEq(shareClassId, USDC, investor, UserOrder(0, 0));

        vm.expectEmit(true, true, true, true);
        emit IShareClassManager.UpdatedDepositRequest(poolId, shareClassId, 1, investor, USDC, amount, amount);
        shareClass.requestDeposit(poolId, shareClassId, amount, investor, USDC);

        assertEq(shareClass.pendingDeposits(shareClassId, USDC), amount);
        _assertDepositRequestEq(shareClassId, USDC, investor, UserOrder(1, amount));
    }

    function testCancelDepositRequest(uint256 amount) public {
        amount = uint256(bound(amount, MIN_REQUEST_AMOUNT, MAX_REQUEST_AMOUNT));
        shareClass.requestDeposit(poolId, shareClassId, amount, investor, USDC);

        vm.expectEmit(true, true, true, true);
        emit IShareClassManager.UpdatedDepositRequest(poolId, shareClassId, 1, investor, USDC, 0, 0);
        shareClass.cancelDepositRequest(poolId, shareClassId, investor, USDC);

        assertEq(shareClass.pendingDeposits(shareClassId, USDC), 0);
        _assertDepositRequestEq(shareClassId, USDC, investor, UserOrder(1, 0));
    }

    function testApproveDepositsSingleAssetManyInvestors(
        uint256 depositAmount,
        uint8 numInvestors,
        uint128 approvalRatio_
    ) public {
        depositAmount = uint256(bound(depositAmount, MIN_REQUEST_AMOUNT, MAX_REQUEST_AMOUNT));
        D18 approvalRatio = d18(uint128(bound(approvalRatio_, 1e14, 1e18)));
        numInvestors = uint8(bound(numInvestors, 1, 100));

        uint256 deposits = 0;
        for (uint16 i = 0; i < numInvestors; i++) {
            address investor = address(uint160(uint256(keccak256(abi.encodePacked("investor_", i)))));
            uint256 investorDeposit = depositAmount + i;
            deposits += investorDeposit;
            shareClass.requestDeposit(poolId, shareClassId, investorDeposit, investor, USDC);

            assertEq(shareClass.pendingDeposits(shareClassId, USDC), deposits);
        }
        assertEq(shareClass.epochIds(poolId), 1);

        uint256 approvedUSDC = approvalRatio.mulUint256(deposits);
        uint256 approvedPool = approvedUSDC / 100;

        vm.expectEmit(true, true, true, true);
        emit IShareClassManager.NewEpoch(poolId, 2);
        vm.expectEmit(true, true, true, true);
        emit IShareClassManager.ApprovedDeposits(
            poolId, shareClassId, 1, USDC, approvalRatio, approvedPool, approvedUSDC, deposits - approvedUSDC, d18(1e16)
        );
        shareClass.approveDeposits(poolId, shareClassId, approvalRatio, USDC, oracleMock);

        assertEq(shareClass.pendingDeposits(shareClassId, USDC), deposits - approvedUSDC);

        // Only one epoch should have passed
        assertEq(shareClass.epochIds(poolId), 2);

        _assertEpochEq(shareClassId, 1, Epoch(oracleMock, approvedPool, 0));
        _assertEpochRatioEq(shareClassId, USDC, 1, EpochRatio(d18(0), approvalRatio, d18(1e16), d18(0)));
    }

    function testApproveDepositsTwoAssetsSameEpoch(uint256 depositAmount, uint128 approvalRatio) public {
        uint256 depositAmountUsdc = uint256(bound(depositAmount, MIN_REQUEST_AMOUNT, MAX_REQUEST_AMOUNT));
        uint256 depositAmountOther = uint256(bound(depositAmount, 1e8, MAX_REQUEST_AMOUNT));
        D18 approvalRatioUsdc = d18(uint128(bound(approvalRatio, 1e14, 1e18)));
        D18 approvalRatioOther = d18(uint128(bound(approvalRatio, 1e14, 1e18)));
        address investorUsdc = makeAddr("investorUsdc");
        address investorOther = makeAddr("investorOther");

        uint256 approvedPool = d18(1e16).mulUint256(approvalRatioUsdc.mulUint256(depositAmountUsdc))
            + d18(1e10).mulUint256(approvalRatioOther.mulUint256(depositAmountOther));

        shareClass.requestDeposit(poolId, shareClassId, depositAmountUsdc, investorUsdc, USDC);
        shareClass.requestDeposit(poolId, shareClassId, depositAmountOther, investorOther, OTHER_STABLE);

        shareClass.approveDeposits(poolId, shareClassId, approvalRatioUsdc, USDC, oracleMock);
        shareClass.approveDeposits(poolId, shareClassId, approvalRatioOther, OTHER_STABLE, oracleMock);

        assertEq(shareClass.epochIds(poolId), 2);

        _assertEpochEq(shareClassId, 1, Epoch(oracleMock, approvedPool, 0));
        _assertEpochRatioEq(shareClassId, USDC, 1, EpochRatio(d18(0), approvalRatioUsdc, d18(1e16), d18(0)));
        _assertEpochRatioEq(shareClassId, OTHER_STABLE, 1, EpochRatio(d18(0), approvalRatioOther, d18(1e10), d18(0)));
    }

    function testIssueSharesSingleEpoch(uint256 depositAmount, uint128 navPerShare, uint128 approvalRatio_) public {
        depositAmount = uint256(bound(depositAmount, MIN_REQUEST_AMOUNT, MAX_REQUEST_AMOUNT));
        D18 poolToShareQuote = d18(uint128(bound(navPerShare, 1e14, type(uint128).max / 1e18)));
        D18 approvalRatio = d18(uint128(bound(approvalRatio_, 1e14, 1e18)));
        address investor = makeAddr("investor");
        uint256 approvedUSDC = approvalRatio.mulUint256(depositAmount);
        uint256 approvedPool = approvedUSDC / 100;
        uint256 shares = poolToShareQuote.mulUint256(approvedPool);

        shareClass.requestDeposit(poolId, shareClassId, depositAmount, investor, USDC);
        shareClass.approveDeposits(poolId, shareClassId, approvalRatio, USDC, oracleMock);

        assertEq(shareClass.totalIssuance(shareClassId), 0);
        assertEq(shareClass.latestIssuance(shareClassId, USDC), 0);

        shareClass.issueShares(poolId, shareClassId, USDC, poolToShareQuote);
        assertEq(shareClass.totalIssuance(shareClassId), shares);
        assertEq(shareClass.latestIssuance(shareClassId, USDC), 1);
        _assertEpochEq(shareClassId, 1, Epoch(oracleMock, approvedPool, 0));
        _assertEpochRatioEq(shareClassId, USDC, 1, EpochRatio(d18(0), approvalRatio, d18(1e16), poolToShareQuote));
    }
}

///@dev Contains all tests which require transient storage to reset between calls
contract SingleShareClassIsolatedTest is SingleShareClassBaseTest {
    using MathLib for uint256;

    function testIssueSharesManyEpochs(
        uint256 depositAmount,
        uint128 navPerShare,
        uint128 approvalRatio_,
        uint8 maxEpochId
    ) public {
        depositAmount = uint256(bound(depositAmount, MIN_REQUEST_AMOUNT, MAX_REQUEST_AMOUNT));
        D18 poolToShareQuote = d18(uint128(bound(navPerShare, 1e10, type(uint128).max / 1e18)));
        maxEpochId = uint8(bound(maxEpochId, 3, 50));
        D18 approvalRatio = d18(uint128(bound(approvalRatio_, 1e14, 1e18)));

        // Bump up latestApproval epochs
        for (uint8 i = 1; i < maxEpochId; i++) {
            address investor = address(uint160(uint256(keccak256(abi.encodePacked("investor_", i)))));
            shareClass.tmpResetEpochIncrement();
            shareClass.requestDeposit(poolId, shareClassId, depositAmount, investor, USDC);
            shareClass.approveDeposits(poolId, shareClassId, approvalRatio, USDC, oracleMock);
        }
        assertEq(shareClass.totalIssuance(shareClassId), 0);

        shareClass.issueShares(poolId, shareClassId, USDC, poolToShareQuote);
        assertEq(shareClass.latestIssuance(shareClassId, USDC), maxEpochId - 1);

        // Ensure each epoch is issued separately
        uint256 shares = 0;
        uint256 pendingDeposits = 0;
        for (uint8 i = 1; i < maxEpochId; i++) {
            uint256 approvedDeposits = approvalRatio.mulUint256(depositAmount + pendingDeposits);
            pendingDeposits += depositAmount - approvedDeposits;
            uint256 approvedPool = approvedDeposits / 100;
            shares += poolToShareQuote.mulUint256(approvedPool);

            _assertEpochEq(shareClassId, i, Epoch(oracleMock, approvedPool, 0));
            _assertEpochRatioEq(shareClassId, USDC, 1, EpochRatio(d18(0), approvalRatio, d18(1e16), poolToShareQuote));
        }
        assertEq(shareClass.totalIssuance(shareClassId), shares, "totalIssuance mismatch");

        // Ensure another issuance has no impact
        shareClass.issueShares(poolId, shareClassId, USDC, poolToShareQuote);
        assertEq(shareClass.latestIssuance(shareClassId, USDC), maxEpochId - 1);
    }

    // TODO: function testClaimDeposit
    // TODO: function testIssueSharesWithApprovedRedemption
}

contract SingleShareClassRevertsTest is SingleShareClassBaseTest {
    using MathLib for uint256;

    bytes16 wrongShareClassId = bytes16("otherId");

    error Unauthorized();
    error NotYetApproved();

    function testConstructor() public {
        vm.expectRevert(bytes("Empty poolRegistry"));
        new SingleShareClass(address(this), address(0), address(0));
        vm.expectRevert(bytes("Empty investorPermissions"));
        new SingleShareClass(address(this), address(1), address(0));
    }

    function testAllowAssetWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassMismatch.selector, shareClassId));
        shareClass.allowAsset(poolId, wrongShareClassId, USDC);
    }

    function testDisallowAssetWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassMismatch.selector, shareClassId));
        shareClass.disallowAsset(poolId, wrongShareClassId, USDC);
    }

    function testRequestDepositWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassMismatch.selector, shareClassId));
        shareClass.requestDeposit(poolId, wrongShareClassId, 1, investor, USDC);
    }

    function testCancelRequestDepositWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassMismatch.selector, shareClassId));
        shareClass.cancelDepositRequest(poolId, wrongShareClassId, investor, USDC);
    }

    function testRequestRedeemWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassMismatch.selector, shareClassId));
        shareClass.requestRedeem(poolId, wrongShareClassId, 1, investor, USDC);
    }

    function testCancelRedeemRequestWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassMismatch.selector, shareClassId));
        shareClass.cancelRedeemRequest(poolId, wrongShareClassId, investor, USDC);
    }

    function testApproveDepositsWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassMismatch.selector, shareClassId));
        shareClass.approveDeposits(poolId, wrongShareClassId, d18(1), USDC, IERC7726Ext(address(this)));
    }

    function testApproveRedemptionsWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassMismatch.selector, shareClassId));
        shareClass.approveRedemptions(poolId, wrongShareClassId, d18(1), USDC, IERC7726Ext(address(this)));
    }

    function testIssueSharesWrongShareClassId() public {
        // Mock latestDepositApproval to epoch 1
        vm.store(
            address(shareClass),
            // NOTE: Storage slot without transient storage (which is not supported by forge yet)
            // keccak256(abi.encode(USDC, keccak256(abi.encode(wrongShareClassId, uint256(12))))),
            // NOTE: Storage slot with using transient storage (which is not supported by forge yet)
            keccak256(abi.encode(USDC, keccak256(abi.encode(wrongShareClassId, uint256(11))))),
            bytes32(uint256(1))
        );

        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassMismatch.selector, shareClassId));
        shareClass.issueShares(poolId, wrongShareClassId, USDC, d18(1));
    }

    function testIssueSharesUntilEpochWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassMismatch.selector, shareClassId));
        shareClass.issueSharesUntilEpoch(poolId, wrongShareClassId, USDC, d18(1), 0);
    }

    function testRevokeSharesWrongShareClassId() public {
        // Mock latestRedeemApproval to epoch 1
        vm.store(
            address(shareClass),
            // NOTE: Storage slot without transient storage (which is not supported by forge yet)
            // keccak256(abi.encode(USDC, keccak256(abi.encode(wrongShareClassId, uint256(13))))),
            // NOTE: Storage slot with using transient storage (which is not supported by forge yet)
            keccak256(abi.encode(USDC, keccak256(abi.encode(wrongShareClassId, uint256(12))))),
            bytes32(uint256(1))
        );

        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassMismatch.selector, shareClassId));
        shareClass.revokeShares(poolId, wrongShareClassId, USDC, d18(1));
    }

    function testRevokeSharesUntilEpochWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassMismatch.selector, shareClassId));
        shareClass.revokeSharesUntilEpoch(poolId, wrongShareClassId, USDC, d18(1), 0);
    }

    function testClaimDepositWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassMismatch.selector, shareClassId));
        shareClass.claimDeposit(poolId, wrongShareClassId, investor, USDC);
    }

    function testClaimDepositUntilEpochWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassMismatch.selector, shareClassId));
        shareClass.claimDepositUntilEpoch(poolId, wrongShareClassId, investor, USDC, 0);
    }

    function testClaimRedeemWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassMismatch.selector, shareClassId));
        shareClass.claimRedeem(poolId, wrongShareClassId, investor, USDC);
    }

    function testClaimRedeemUntilEpochWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassMismatch.selector, shareClassId));
        shareClass.claimRedeemUntilEpoch(poolId, wrongShareClassId, investor, USDC, 0);
    }

    function testUpdateShareClassNavWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassMismatch.selector, shareClassId));
        shareClass.updateShareClassNav(poolId, wrongShareClassId);
    }

    function testGetShareClassNavWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassMismatch.selector, shareClassId));
        shareClass.getShareClassNavPerShare(poolId, wrongShareClassId);
    }

    function testRequestDepositAssetNotAllowed() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.AssetNotAllowed.selector));
        shareClass.requestDeposit(poolId, shareClassId, 1, investor, POOL_CURRENCY);
    }

    function testRedeemRequestAssetNotAllowed() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.AssetNotAllowed.selector));
        shareClass.requestRedeem(poolId, shareClassId, 1, investor, POOL_CURRENCY);
    }

    function testAddShareClass() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.MaxShareClassNumberExceeded.selector, 1));
        shareClass.addShareClass(poolId, bytes(""));
    }

    function testIssueSharesBeforeApproval() public {
        // console.log("latest approval: ", shareClass.latestDepositApproval(shareClassId, USDC));
        vm.expectRevert(abi.encodeWithSelector(NotYetApproved.selector));
        shareClass.issueShares(poolId, shareClassId, USDC, d18(1));
    }

    function testRevokeSharesBeforeApproval() public {
        vm.expectRevert(abi.encodeWithSelector(NotYetApproved.selector));
        shareClass.revokeShares(poolId, shareClassId, USDC, d18(1));
    }

    function testRequestDepositNotInvestor() public {
        vm.mockCall(
            address(investorPermissions),
            abi.encodeWithSignature("isUnfrozenInvestor(bytes16,address)"),
            abi.encode(false)
        );

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector));
        shareClass.requestDeposit(poolId, shareClassId, 1, investor, USDC);
    }

    function testCancelDepositNotInvestor() public {
        vm.mockCall(
            address(investorPermissions),
            abi.encodeWithSignature("isUnfrozenInvestor(bytes16,address)"),
            abi.encode(false)
        );

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector));
        shareClass.cancelDepositRequest(poolId, shareClassId, investor, USDC);
    }

    function testUpdateShareClassUnsupported() public {
        vm.expectRevert(bytes("unsupported"));
        shareClass.updateShareClassNav(poolId, shareClassId);
    }

    function testUpdateUnsupported() public {
        vm.expectRevert(bytes("unsupported"));
        shareClass.update(poolId, bytes(""));
    }

    function testRequestDepositRequiresClaim() public {
        shareClass.requestDeposit(poolId, shareClassId, 1, investor, USDC);
        shareClass.approveDeposits(poolId, shareClassId, d18(1), USDC, oracleMock);

        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ClaimDepositRequired.selector));
        shareClass.requestDeposit(poolId, shareClassId, 1, investor, USDC);
    }

    function testRequestRedeemRequiresClaim() public {
        shareClass.requestRedeem(poolId, shareClassId, 1, investor, USDC);
        shareClass.approveRedemptions(poolId, shareClassId, d18(1), USDC, oracleMock);

        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ClaimRedeemRequired.selector));
        shareClass.requestRedeem(poolId, shareClassId, 1, investor, USDC);
    }
}
