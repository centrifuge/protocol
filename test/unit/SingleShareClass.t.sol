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
address constant POOL_CURRENCY = address(840);
address constant USDC = address(0x0123456);
address constant OTHER_STABLE = address(0x01234567);
uint256 constant DENO_USDC = 10 ** 6;
uint256 constant DENO_OTHER_STABLE = 10 ** 12;
uint256 constant DENO_POOL = 10 ** 4;
uint256 constant MIN_REQUEST_AMOUNT = 1e10;
uint256 constant MAX_REQUEST_AMOUNT = 1e40;

contract PoolRegistryMock {
    function poolCurrencies(PoolId) external pure returns (IERC20Metadata) {
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

contract SingleShareClassTest is Test {
    using MathLib for uint256;

    SingleShareClass public shareClass;
    IPoolRegistry public poolRegistry;
    IInvestorPermissions public investorPermissions;

    OracleMock oracleMock = new OracleMock();
    PoolRegistryMock poolRegistryMock = new PoolRegistryMock();
    EveryoneInvestor investorPermissionsMock = new EveryoneInvestor();

    PoolId poolId = PoolId.wrap(1);
    bytes16 shareClassId = bytes16("shareClass123");
    address poolRegistryAddress = makeAddr("poolRegistry");
    address investorPermissionsAddress = makeAddr("investorPermissions");

    function setUp() public {
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
        address investor = makeAddr("investor");

        assertEq(shareClass.approvedDeposits(shareClassId), 0);
        assertEq(shareClass.pendingDeposits(shareClassId, USDC), 0);
        _assertDepositRequestEq(shareClassId, USDC, investor, UserOrder(0, 0));

        vm.expectEmit(true, true, true, true);
        emit IShareClassManager.UpdatedDepositRequest(poolId, shareClassId, 0, investor, USDC, amount, amount);
        shareClass.requestDeposit(poolId, shareClassId, amount, investor, USDC);

        assertEq(shareClass.approvedDeposits(shareClassId), 0);
        assertEq(shareClass.pendingDeposits(shareClassId, USDC), amount);
        _assertDepositRequestEq(shareClassId, USDC, investor, UserOrder(0, amount));
    }

    function testCancelDepositRequest(uint256 amount) public {
        amount = uint256(bound(amount, MIN_REQUEST_AMOUNT, MAX_REQUEST_AMOUNT));
        address investor = makeAddr("investor");
        shareClass.requestDeposit(poolId, shareClassId, amount, investor, USDC);

        vm.expectEmit(true, true, true, true);
        emit IShareClassManager.UpdatedDepositRequest(poolId, shareClassId, 0, investor, USDC, 0, 0);
        shareClass.cancelDepositRequest(poolId, shareClassId, investor, USDC);

        assertEq(shareClass.approvedDeposits(shareClassId), 0);
        assertEq(shareClass.pendingDeposits(shareClassId, USDC), 0);
        _assertDepositRequestEq(shareClassId, USDC, investor, UserOrder(0, 0));
    }

    function testApproveDepositsSingleAssetManyInvestors(
        uint256 depositAmount,
        uint8 numInvestors,
        uint128 approvalRatio
    ) public {
        depositAmount = uint256(bound(depositAmount, MIN_REQUEST_AMOUNT, MAX_REQUEST_AMOUNT));
        approvalRatio = uint128(bound(approvalRatio, 1e14, 1e18));
        numInvestors = uint8(bound(numInvestors, 1, 100));

        uint256 deposits = 0;
        for (uint16 i = 0; i < numInvestors; i++) {
            address investor = address(uint160(uint256(keccak256(abi.encodePacked("investor_", i)))));
            uint256 investorDeposit = depositAmount + i;
            deposits += investorDeposit;
            shareClass.requestDeposit(poolId, shareClassId, investorDeposit, investor, USDC);

            assertEq(shareClass.pendingDeposits(shareClassId, USDC), deposits);
        }
        assertEq(shareClass.epochIds(poolId), 0);

        uint256 approvedUSDC = deposits.mulDiv(approvalRatio, 1e18);
        uint256 approvedPool = approvedUSDC / 100;

        vm.expectEmit(true, true, true, true);
        emit IShareClassManager.NewEpoch(poolId, 1);
        vm.expectEmit(true, true, true, true);
        emit IShareClassManager.ApprovedDeposits(
            poolId, shareClassId, 0, USDC, approvalRatio, approvedPool, approvedUSDC, deposits - approvedUSDC, 1e16
        );
        shareClass.approveDeposits(poolId, shareClassId, approvalRatio, USDC, oracleMock);

        assertEq(shareClass.pendingDeposits(shareClassId, USDC), deposits - approvedUSDC);
        assertEq(shareClass.approvedDeposits(shareClassId), approvedPool);
        assertEq(shareClass.epochIds(poolId), 1);

        _assertEpochEq(shareClassId, 0, Epoch(d18(0), oracleMock, approvedPool, 0));
        _assertEpochRatioEq(shareClassId, USDC, 0, EpochRatio(d18(0), d18(approvalRatio), d18(1e16)));
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

        shareClass.approveDeposits(poolId, shareClassId, approvalRatioUsdc.inner(), USDC, oracleMock);
        shareClass.approveDeposits(poolId, shareClassId, approvalRatioOther.inner(), OTHER_STABLE, oracleMock);

        assertEq(shareClass.approvedDeposits(shareClassId), approvedPool);
        assertEq(shareClass.epochIds(poolId), 1);

        _assertEpochEq(shareClassId, 0, Epoch(d18(0), oracleMock, approvedPool, 0));
        _assertEpochRatioEq(shareClassId, USDC, 0, EpochRatio(d18(0), approvalRatioUsdc, d18(1e16)));
        _assertEpochRatioEq(shareClassId, OTHER_STABLE, 0, EpochRatio(d18(0), approvalRatioOther, d18(1e10)));
    }

    function _assertDepositRequestEq(bytes16 shareClassId_, address asset, address investor, UserOrder memory expected)
        private
        view
    {
        (uint32 lastUpdate, uint256 pending) = shareClass.depositRequests(shareClassId_, asset, investor);

        assertEq(lastUpdate, expected.lastUpdate, "lastUpdate mismatch");
        assertEq(pending, expected.pending, "pending mismatch");
    }

    function _assertEpochEq(bytes16 shareClassId_, uint32 epochId, Epoch memory expected) private view {
        (D18 shareToPoolQuote, IERC7726Ext valuation, uint256 approvedDeposits, uint256 approvedShares) =
            shareClass.epochs(shareClassId_, epochId);

        assertEq(shareToPoolQuote.inner(), expected.shareToPoolQuote.inner());
        assertEq(address(valuation), address(expected.valuation));
        assertEq(approvedDeposits, expected.approvedDeposits);
        assertEq(approvedShares, expected.approvedShares);
    }

    function _assertEpochRatioEq(bytes16 shareClassId_, address assetId, uint32 epochId, EpochRatio memory expected)
        private
        view
    {
        (D18 redeemRatio, D18 depositRatio, D18 assetToPoolQuote) =
            shareClass.epochRatios(shareClassId_, assetId, epochId);
        assertEq(redeemRatio.inner(), expected.redeemRatio.inner());
        assertEq(depositRatio.inner(), expected.depositRatio.inner());
        assertEq(uint256(assetToPoolQuote.inner()), assetToPoolQuote.inner());
    }
}
