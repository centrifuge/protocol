// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {MathLib} from "src/misc/libraries/MathLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {PoolId} from "src/pools/types/PoolId.sol";
import {AssetId} from "src/pools/types/AssetId.sol";
import {AssetId} from "src/pools/types/AssetId.sol";
import {ShareClassId} from "src/pools/types/ShareClassId.sol";
import {IShareClassManager} from "src/pools/interfaces/IShareClassManager.sol";
import {ISingleShareClass} from "src/pools/interfaces/ISingleShareClass.sol";
import {IPoolRegistry} from "src/pools/interfaces/IPoolRegistry.sol";
import {
    SingleShareClass,
    EpochAmounts,
    UserOrder,
    EpochPointers,
    ShareClassMetadata
} from "src/pools/SingleShareClass.sol";

uint64 constant POOL_ID = 42;
ShareClassId constant SHARE_CLASS_ID = ShareClassId.wrap(bytes16(uint128(POOL_ID)));
address constant POOL_CURRENCY = address(840);
AssetId constant USDC = AssetId.wrap(69);
AssetId constant OTHER_STABLE = AssetId.wrap(1337);
uint128 constant DENO_USDC = 10 ** 6;
uint128 constant DENO_OTHER_STABLE = 10 ** 12;
uint128 constant DENO_POOL = 10 ** 18;
uint128 constant MIN_REQUEST_AMOUNT = 1e6;
uint128 constant MAX_REQUEST_AMOUNT = 1e18;
string constant SC_META_NAME = "ExampleName";
string constant SC_META_SYMBOL = "ExampleSymbol";
bytes32 constant SC_META_HOOK = bytes32("ExampleHookData");

uint32 constant STORAGE_INDEX_EPOCH_ID = 2;
uint32 constant STORAGE_INDEX_TOTAL_ISSUANCE = 4;
uint32 constant STORAGE_INDEX_EPOCH_POINTERS = 7;

contract PoolRegistryMock {
    function currency(PoolId) external pure returns (AssetId) {
        return AssetId.wrap(uint64(uint160(POOL_CURRENCY)));
    }
}

contract OracleMock is IERC7726 {
    using MathLib for uint128;
    using MathLib for uint256;

    function getQuote(uint256 baseAmount, address base, address quote) external pure returns (uint256 quoteAmount) {
        if (base == USDC.addr() && quote == OTHER_STABLE.addr()) {
            return baseAmount.mulDiv(DENO_OTHER_STABLE, DENO_USDC);
        } else if (base == USDC.addr() && quote == POOL_CURRENCY) {
            return baseAmount.mulDiv(DENO_POOL, DENO_USDC);
        } else if (base == OTHER_STABLE.addr() && quote == USDC.addr()) {
            return baseAmount.mulDiv(DENO_USDC, DENO_OTHER_STABLE);
        } else if (base == OTHER_STABLE.addr() && quote == POOL_CURRENCY) {
            return baseAmount.mulDiv(DENO_POOL, DENO_OTHER_STABLE);
        } else if (base == POOL_CURRENCY && quote == USDC.addr()) {
            return baseAmount.mulDiv(DENO_USDC, DENO_POOL);
        } else if (base == POOL_CURRENCY && quote == OTHER_STABLE.addr()) {
            return baseAmount.mulDiv(DENO_OTHER_STABLE, DENO_POOL);
        } else if (base == POOL_CURRENCY && quote == address(bytes20(ShareClassId.unwrap(SHARE_CLASS_ID)))) {
            return baseAmount;
        } else {
            revert("Unsupported factor pair");
        }
    }
}

contract SingleShareClassExt is SingleShareClass {
    constructor(IPoolRegistry poolRegistry, address deployer) SingleShareClass(poolRegistry, deployer) {
        poolRegistry = poolRegistry;
    }

    function setEpochIncrement(uint32 epochIncrement) public {
        _epochIncrement = epochIncrement;
    }
}

abstract contract SingleShareClassBaseTest is Test {
    using MathLib for uint128;
    using MathLib for uint256;
    using CastLib for string;

    SingleShareClassExt public shareClass;

    OracleMock oracleMock = new OracleMock();
    PoolRegistryMock poolRegistryMock = new PoolRegistryMock();

    PoolId poolId = PoolId.wrap(POOL_ID);
    ShareClassId scId = SHARE_CLASS_ID;
    address poolRegistryAddress = makeAddr("poolRegistry");
    bytes32 investor = bytes32("investor");

    modifier notThisContract(address addr) {
        vm.assume(address(this) != addr);
        _;
    }

    function setUp() public virtual {
        shareClass = new SingleShareClassExt(IPoolRegistry(poolRegistryAddress), address(this));

        vm.expectEmit();
        emit ISingleShareClass.AddedShareClass(poolId, scId, SC_META_NAME, SC_META_SYMBOL, SC_META_HOOK);
        shareClass.addShareClass(poolId, _encodeMetadata(SC_META_NAME, SC_META_SYMBOL, SC_META_HOOK));

        // Mock IPoolRegistry.currency call
        vm.mockCall(
            poolRegistryAddress,
            abi.encodeWithSelector(IPoolRegistry.currency.selector, poolId),
            abi.encode(AssetId.wrap(uint64(uint160(POOL_CURRENCY))))
        );
        assertEq(IPoolRegistry(poolRegistryAddress).currency(poolId).addr(), POOL_CURRENCY);
    }

    function _assertDepositRequestEq(
        ShareClassId shareClassId_,
        AssetId asset,
        bytes32 investor_,
        UserOrder memory expected
    ) internal view {
        (uint128 pending, uint32 lastUpdate) = shareClass.depositRequest(shareClassId_, asset, investor_);

        assertEq(pending, expected.pending, "pending deposit mismatch");
        assertEq(lastUpdate, expected.lastUpdate, "lastUpdate deposit mismatch");
    }

    function _assertRedeemRequestEq(
        ShareClassId shareClassId_,
        AssetId asset,
        bytes32 investor_,
        UserOrder memory expected
    ) internal view {
        (uint128 pending, uint32 lastUpdate) = shareClass.redeemRequest(shareClassId_, asset, investor_);

        assertEq(pending, expected.pending, "pending redeem mismatch");
        assertEq(lastUpdate, expected.lastUpdate, "lastUpdate redeem mismatch");
    }

    function _assertEpochAmountsEq(
        ShareClassId shareClassId_,
        AssetId assetId,
        uint32 epochId,
        EpochAmounts memory expected
    ) internal view {
        (
            D18 depositApprovalRate,
            D18 redeemApprovalRate,
            uint128 depositAssetAmount,
            uint128 depositPoolAmount,
            uint128 depositSharesIssued,
            uint128 redeemAssetAmount,
            uint128 redeemSharesRevoked
        ) = shareClass.epochAmounts(shareClassId_, assetId, epochId);

        assertEq(depositApprovalRate.inner(), expected.depositApprovalRate.inner(), "depositApprovalRate mismatch");
        assertEq(redeemApprovalRate.inner(), expected.redeemApprovalRate.inner(), "redeemApprovalRate mismatch");
        assertEq(depositAssetAmount, expected.depositAssetAmount, "depositAssetAmount mismatch");
        assertEq(depositPoolAmount, expected.depositPoolAmount, "depositPoolAmount mismatch");
        assertEq(depositSharesIssued, expected.depositSharesIssued, "depositSharesIssued mismatch");
        assertEq(redeemAssetAmount, expected.redeemAssetAmount, "redeemAssetAmount mismatch");
        assertEq(redeemSharesRevoked, expected.redeemSharesRevoked, "redeemSharesRevoked mismatch");
    }

    function _assertEpochPointersEq(ShareClassId shareClassId_, AssetId assetId, EpochPointers memory expected)
        internal
        view
    {
        (uint32 latestDepositApproval, uint32 latestRedeemApproval, uint32 latestIssuance, uint32 latestRevocation) =
            shareClass.epochPointers(shareClassId_, assetId);

        assertEq(latestDepositApproval, expected.latestDepositApproval, "latestDepositApproval mismatch");
        assertEq(latestRedeemApproval, expected.latestRedeemApproval, "latestRedeemApproval mismatch");
        assertEq(latestIssuance, expected.latestIssuance, "latestIssuance mismatch");
        assertEq(latestRevocation, expected.latestRevocation, "latestRevocation mismatch");
    }

    function _resetTransientEpochIncrement() internal {
        shareClass.setEpochIncrement(0);
    }

    function usdcToPool(uint128 usdcAmount) internal view returns (uint128 poolAmount) {
        return oracleMock.getQuote(uint256(usdcAmount), USDC.addr(), POOL_CURRENCY).toUint128();
    }

    function poolToUsdc(uint128 poolAmount) internal view returns (uint128 usdcAmount) {
        return oracleMock.getQuote(uint256(poolAmount), POOL_CURRENCY, USDC.addr()).toUint128();
    }

    function _encodeMetadata(string memory name, string memory symbol, bytes32 hook)
        internal
        pure
        returns (bytes memory metadata)
    {
        return abi.encodePacked(bytes(name.stringToBytes128()), bytes(symbol.stringToBytes128()), hook);
    }
}

///@dev Contains all simple tests which are expected to succeed
contract SingleShareClassSimpleTest is SingleShareClassBaseTest {
    using MathLib for uint128;
    using CastLib for string;

    function testDeployment(address nonWard) public view notThisContract(poolRegistryAddress) {
        vm.assume(nonWard != address(shareClass.poolRegistry()) && nonWard != address(this));

        assertEq(address(shareClass.poolRegistry()), poolRegistryAddress);
        assertEq(ShareClassId.unwrap(shareClass.shareClassId(poolId)), ShareClassId.unwrap(scId));

        assertEq(shareClass.wards(address(this)), 1);
        assertEq(shareClass.wards(address(shareClass.poolRegistry())), 0);

        assertEq(shareClass.wards(nonWard), 0);
    }

    function testFile() public {
        address poolRegistryNew = makeAddr("poolRegistryNew");
        vm.expectEmit(true, true, true, true);
        emit ISingleShareClass.File("poolRegistry", poolRegistryNew);
        shareClass.file("poolRegistry", poolRegistryNew);

        assertEq(address(shareClass.poolRegistry()), poolRegistryNew);
    }

    function testDefaultGetShareClassNavPerShare() public view notThisContract(poolRegistryAddress) {
        (D18 navPerShare, uint128 nav) = shareClass.shareClassNavPerShare(poolId, scId);
        assertEq(nav, 0);
        assertEq(navPerShare.inner(), 0);
    }

    function testExistence() public view notThisContract(poolRegistryAddress) {
        assert(shareClass.exists(poolId, scId));
        assert(!shareClass.exists(poolId, ShareClassId.wrap(bytes16(0))));
    }

    function testDefaultMetadata() public view notThisContract(poolRegistryAddress) {
        (string memory name, string memory symbol, bytes32 hook) = shareClass.metadata(scId);

        assertEq(name, SC_META_NAME);
        assertEq(symbol, SC_META_SYMBOL);
        assertEq(hook, SC_META_HOOK);
    }

    function testSetMetadata(string memory name, string memory symbol, bytes32 hook)
        public
        notThisContract(poolRegistryAddress)
    {
        vm.assume(bytes(name).length > 0);
        vm.assume(bytes(symbol).length > 0);
        vm.assume(hook != bytes32(0));

        vm.expectEmit();
        emit ISingleShareClass.UpdatedMetadata(poolId, scId, name, symbol, hook);
        shareClass.setMetadata(poolId, scId, _encodeMetadata(name, symbol, hook));

        (string memory name_, string memory symbol_, bytes32 hook_) = shareClass.metadata(scId);
        assertEq(name, name_, "Metadata name mismatch");
        assertEq(symbol, symbol_, "Metadata symbol mismatch");
        assertEq(hook, hook_, "Metadata hook mismatch");
    }
}

///@dev Contains all deposit related tests which are expected to succeed and don't make use of transient storage
contract SingleShareClassDepositsNonTransientTest is SingleShareClassBaseTest {
    using MathLib for uint128;

    function testRequestDeposit(uint128 amount) public notThisContract(poolRegistryAddress) {
        amount = uint128(bound(amount, MIN_REQUEST_AMOUNT, MAX_REQUEST_AMOUNT));

        assertEq(shareClass.pendingDeposit(scId, USDC), 0);
        _assertDepositRequestEq(scId, USDC, investor, UserOrder(0, 0));

        vm.expectEmit(true, true, true, true);
        emit IShareClassManager.UpdatedDepositRequest(poolId, scId, 1, investor, USDC, amount, amount);
        shareClass.requestDeposit(poolId, scId, amount, investor, USDC);

        assertEq(shareClass.pendingDeposit(scId, USDC), amount);
        _assertDepositRequestEq(scId, USDC, investor, UserOrder(amount, 1));
    }

    function testCancelDepositRequest(uint128 amount) public notThisContract(poolRegistryAddress) {
        amount = uint128(bound(amount, MIN_REQUEST_AMOUNT, MAX_REQUEST_AMOUNT));
        shareClass.requestDeposit(poolId, scId, amount, investor, USDC);

        vm.expectEmit(true, true, true, true);
        emit IShareClassManager.UpdatedDepositRequest(poolId, scId, 1, investor, USDC, 0, 0);
        (uint128 cancelledAmount) = shareClass.cancelDepositRequest(poolId, scId, investor, USDC);

        assertEq(cancelledAmount, amount);
        assertEq(shareClass.pendingDeposit(scId, USDC), 0);
        _assertDepositRequestEq(scId, USDC, investor, UserOrder(0, 1));
    }

    function testApproveDepositsSingleAssetManyInvestors(
        uint128 depositAmount,
        uint8 numInvestors,
        uint128 approvalRatio_
    ) public notThisContract(poolRegistryAddress) {
        depositAmount = uint128(bound(depositAmount, MIN_REQUEST_AMOUNT, MAX_REQUEST_AMOUNT));
        D18 approvalRatio = d18(uint128(bound(approvalRatio_, 1e14, 1e18)));
        numInvestors = uint8(bound(numInvestors, 1, 100));

        uint128 deposits = 0;
        for (uint16 i = 0; i < numInvestors; i++) {
            bytes32 investor = bytes32(uint256(keccak256(abi.encodePacked("investor_", i))));
            uint128 investorDeposit = depositAmount + i;
            deposits += investorDeposit;
            shareClass.requestDeposit(poolId, scId, investorDeposit, investor, USDC);

            assertEq(shareClass.pendingDeposit(scId, USDC), deposits);
        }
        assertEq(shareClass.epochId(poolId), 1);

        uint128 approvedUSDC = approvalRatio.mulUint128(deposits);
        uint128 approvedPool = usdcToPool(approvedUSDC);

        vm.expectEmit(true, true, true, true);
        emit IShareClassManager.NewEpoch(poolId, 2);
        vm.expectEmit(true, true, true, true);
        emit IShareClassManager.ApprovedDeposits(
            poolId, scId, 1, USDC, approvalRatio, approvedPool, approvedUSDC, deposits - approvedUSDC
        );
        shareClass.approveDeposits(poolId, scId, approvalRatio, USDC, oracleMock);

        assertEq(shareClass.pendingDeposit(scId, USDC), deposits - approvedUSDC);

        // Only one epoch should have passed
        assertEq(shareClass.epochId(poolId), 2);

        _assertEpochAmountsEq(scId, USDC, 1, EpochAmounts(approvalRatio, d18(0), approvedUSDC, approvedPool, 0, 0, 0));
    }

    function testApproveDepositsTwoAssetsSameEpoch(uint128 depositAmount, uint128 approvalRatio)
        public
        notThisContract(poolRegistryAddress)
    {
        uint128 depositAmountUsdc = uint128(bound(depositAmount, MIN_REQUEST_AMOUNT, MAX_REQUEST_AMOUNT));
        uint128 depositAmountOther = uint128(bound(depositAmount, 1e8, MAX_REQUEST_AMOUNT));
        D18 approvalRatioUsdc = d18(uint128(bound(approvalRatio, 1e14, 1e18)));
        D18 approvalRatioOther = d18(uint128(bound(approvalRatio, 1e14, 1e18)));
        bytes32 investorUsdc = bytes32("investorUsdc");
        bytes32 investorOther = bytes32("investorOther");

        uint128 approvedAssetUsdc = approvalRatioUsdc.mulUint128(depositAmountUsdc);
        uint128 approvedAssetOther = approvalRatioOther.mulUint128(depositAmountOther);

        shareClass.requestDeposit(poolId, scId, depositAmountUsdc, investorUsdc, USDC);
        shareClass.requestDeposit(poolId, scId, depositAmountOther, investorOther, OTHER_STABLE);

        shareClass.approveDeposits(poolId, scId, approvalRatioUsdc, USDC, oracleMock);
        shareClass.approveDeposits(poolId, scId, approvalRatioOther, OTHER_STABLE, oracleMock);

        assertEq(shareClass.epochId(poolId), 2);

        _assertEpochAmountsEq(
            scId,
            USDC,
            1,
            EpochAmounts(approvalRatioUsdc, d18(0), approvedAssetUsdc, usdcToPool(approvedAssetUsdc), 0, 0, 0)
        );
        _assertEpochAmountsEq(
            scId,
            OTHER_STABLE,
            1,
            EpochAmounts(approvalRatioOther, d18(0), approvedAssetOther, approvedAssetOther * 1e6, 0, 0, 0)
        );
    }

    function testIssueSharesSingleEpoch(uint128 depositAmount, uint128 shareToPoolQuote_, uint128 approvalRatio_)
        public
        notThisContract(poolRegistryAddress)
    {
        depositAmount = uint128(bound(depositAmount, MIN_REQUEST_AMOUNT, MAX_REQUEST_AMOUNT));
        D18 shareToPoolQuote = d18(uint128(bound(shareToPoolQuote_, 1e14, type(uint128).max / 1e18)));
        D18 approvalRatio = d18(uint128(bound(approvalRatio_, 1e14, 1e18)));
        uint128 approvedUSDC = approvalRatio.mulUint128(depositAmount);
        uint128 approvedPool = usdcToPool(approvedUSDC);
        uint128 shares = shareToPoolQuote.reciprocalMulUint128(approvedPool);

        shareClass.requestDeposit(poolId, scId, depositAmount, investor, USDC);
        shareClass.approveDeposits(poolId, scId, approvalRatio, USDC, oracleMock);

        assertEq(shareClass.totalIssuance(scId), 0);
        _assertEpochPointersEq(scId, USDC, EpochPointers(1, 0, 0, 0));

        shareClass.issueShares(poolId, scId, USDC, shareToPoolQuote);
        assertEq(shareClass.totalIssuance(scId), shares);
        _assertEpochPointersEq(scId, USDC, EpochPointers(1, 0, 1, 0));
        _assertEpochAmountsEq(
            scId, USDC, 1, EpochAmounts(approvalRatio, d18(0), approvedUSDC, approvedPool, shares, 0, 0)
        );
    }

    function testClaimDepositSingleEpoch(uint128 depositAmount, uint128 navPerShare, uint128 approvalRatio_)
        public
        notThisContract(poolRegistryAddress)
    {
        depositAmount = uint128(bound(depositAmount, MIN_REQUEST_AMOUNT, MAX_REQUEST_AMOUNT));
        D18 shareToPoolQuote = d18(uint128(bound(navPerShare, 1e10, type(uint128).max / 1e18)));
        D18 approvalRatio = d18(uint128(bound(approvalRatio_, 1e14, 1e18)));
        uint128 approvedUSDC = approvalRatio.mulUint128(depositAmount);
        uint128 approvedPool = usdcToPool(approvedUSDC);
        uint128 shares = shareToPoolQuote.reciprocalMulUint128(approvedPool);
        uint128 pending = depositAmount - approvedUSDC;

        shareClass.requestDeposit(poolId, scId, depositAmount, investor, USDC);
        shareClass.approveDeposits(poolId, scId, approvalRatio, USDC, oracleMock);
        shareClass.issueShares(poolId, scId, USDC, shareToPoolQuote);
        assertEq(shareClass.totalIssuance(scId), shares);
        _assertDepositRequestEq(scId, USDC, investor, UserOrder(depositAmount, 1));

        vm.expectEmit(true, true, true, true);
        emit IShareClassManager.ClaimedDeposit(poolId, scId, 1, investor, USDC, approvedUSDC, pending, shares);
        (uint128 userShares, uint128 payment) = shareClass.claimDeposit(poolId, scId, investor, USDC);

        assertEq(shares, userShares, "shares mismatch");
        assertEq(approvedUSDC, payment, "payment mismatch");
        _assertDepositRequestEq(scId, USDC, investor, UserOrder(pending, 2));
        assertEq(shareClass.totalIssuance(scId), shares);

        // Ensure another claim has no impact
        (userShares, payment) = shareClass.claimDeposit(poolId, scId, investor, USDC);
        assertEq(userShares + payment, 0, "replay must not be possible");
    }

    function testClaimDepositSkipped() public notThisContract(poolRegistryAddress) {
        uint128 pending = MAX_REQUEST_AMOUNT;
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

        (uint128 payout, uint128 payment) = shareClass.claimDeposit(poolId, scId, investor, USDC);
        assertEq(payout + payment, 0);
        _assertDepositRequestEq(scId, USDC, investor, UserOrder(pending, mockEpochId));
    }
}

///@dev Contains all redeem related tests which are expected to succeed and don't make use of transient storage
contract SingleShareClassRedeemsNonTransientTest is SingleShareClassBaseTest {
    using MathLib for uint128;

    function testRequestRedeem(uint128 amount) public notThisContract(poolRegistryAddress) {
        amount = uint128(bound(amount, MIN_REQUEST_AMOUNT, MAX_REQUEST_AMOUNT));

        assertEq(shareClass.pendingRedeem(scId, USDC), 0);
        _assertRedeemRequestEq(scId, USDC, investor, UserOrder(0, 0));

        vm.expectEmit(true, true, true, true);
        emit IShareClassManager.UpdatedRedeemRequest(poolId, scId, 1, investor, USDC, amount, amount);
        shareClass.requestRedeem(poolId, scId, amount, investor, USDC);

        assertEq(shareClass.pendingRedeem(scId, USDC), amount);
        _assertRedeemRequestEq(scId, USDC, investor, UserOrder(amount, 1));
    }

    function testCancelRedeemRequest(uint128 amount) public notThisContract(poolRegistryAddress) {
        amount = uint128(bound(amount, MIN_REQUEST_AMOUNT, MAX_REQUEST_AMOUNT));
        shareClass.requestRedeem(poolId, scId, amount, investor, USDC);

        vm.expectEmit(true, true, true, true);
        emit IShareClassManager.UpdatedRedeemRequest(poolId, scId, 1, investor, USDC, 0, 0);
        (uint128 cancelledAmount) = shareClass.cancelRedeemRequest(poolId, scId, investor, USDC);

        assertEq(cancelledAmount, amount);
        assertEq(shareClass.pendingRedeem(scId, USDC), 0);
        _assertRedeemRequestEq(scId, USDC, investor, UserOrder(0, 1));
    }

    function testApproveRedeemsSingleAssetManyInvestors(uint128 amount, uint8 numInvestors, uint128 approvalRatio_)
        public
    {
        amount = uint128(bound(amount, MIN_REQUEST_AMOUNT, MAX_REQUEST_AMOUNT));
        D18 approvalRatio = d18(uint128(bound(approvalRatio_, 1e14, 1e18)));
        numInvestors = uint8(bound(numInvestors, 1, 100));

        uint128 totalRedeems = 0;
        for (uint16 i = 0; i < numInvestors; i++) {
            bytes32 investor = bytes32(uint256(keccak256(abi.encodePacked("investor_", i))));
            uint128 investorRedeem = amount + i;
            totalRedeems += investorRedeem;
            shareClass.requestRedeem(poolId, scId, investorRedeem, investor, USDC);

            assertEq(shareClass.pendingRedeem(scId, USDC), totalRedeems);
        }
        assertEq(shareClass.epochId(poolId), 1);

        uint128 approvedShares = approvalRatio.mulUint128(totalRedeems);
        uint128 pendingRedeems_ = totalRedeems - approvedShares;

        vm.expectEmit(true, true, true, true);
        emit IShareClassManager.NewEpoch(poolId, 2);
        vm.expectEmit(true, true, true, true);
        emit IShareClassManager.ApprovedRedeems(poolId, scId, 1, USDC, approvalRatio, approvedShares, pendingRedeems_);
        shareClass.approveRedeems(poolId, scId, approvalRatio, USDC);

        assertEq(shareClass.pendingRedeem(scId, USDC), pendingRedeems_);

        // Only one epoch should have passed
        assertEq(shareClass.epochId(poolId), 2);

        _assertEpochAmountsEq(scId, USDC, 1, EpochAmounts(d18(0), approvalRatio, 0, 0, 0, 0, approvedShares));
    }

    function testApproveRedeemsTwoAssetsSameEpoch(uint128 redeemAmount, uint128 approvalRatio)
        public
        notThisContract(poolRegistryAddress)
    {
        uint128 redeemAmountUsdc = uint128(bound(redeemAmount, MIN_REQUEST_AMOUNT, MAX_REQUEST_AMOUNT));
        uint128 redeemAmountOther = uint128(bound(redeemAmount, 1e8, MAX_REQUEST_AMOUNT));
        D18 approvalRatioUsdc = d18(uint128(bound(approvalRatio, 1e14, 1e18)));
        D18 approvalRatioOther = d18(uint128(bound(approvalRatio, 1e14, 1e18)));

        bytes32 investorUsdc = bytes32("investorUsdc");
        bytes32 investorOther = bytes32("investorOther");
        uint128 approvedSharesUsdc = approvalRatioUsdc.mulUint128(redeemAmountUsdc);
        uint128 approvedSharesOther = approvalRatioOther.mulUint128(redeemAmountOther);
        uint128 pendingUsdc = redeemAmountUsdc - approvedSharesUsdc;
        uint128 pendingOther = redeemAmountOther - approvedSharesOther;

        shareClass.requestRedeem(poolId, scId, redeemAmountUsdc, investorUsdc, USDC);
        shareClass.requestRedeem(poolId, scId, redeemAmountOther, investorOther, OTHER_STABLE);

        (uint128 approvedSharesUsdc_, uint128 pendingUsdc_) =
            shareClass.approveRedeems(poolId, scId, approvalRatioUsdc, USDC);
        (uint128 approvedSharesOther_, uint128 pendingOther_) =
            shareClass.approveRedeems(poolId, scId, approvalRatioOther, OTHER_STABLE);

        assertEq(shareClass.epochId(poolId), 2);
        assertEq(approvedSharesUsdc_, approvedSharesUsdc, "approved shares USDC mismatch");
        assertEq(pendingUsdc_, pendingUsdc, "pending shares USDC mismatch");
        assertEq(approvedSharesOther_, approvedSharesOther, "approved shares OtherCurrency mismatch");
        assertEq(pendingOther_, pendingOther, "pending shares OtherCurrency mismatch");

        EpochAmounts memory epochAmountsUsdc = EpochAmounts(d18(0), approvalRatioUsdc, 0, 0, 0, 0, approvedSharesUsdc);
        EpochAmounts memory epochAmountsOther =
            EpochAmounts(d18(0), approvalRatioOther, 0, 0, 0, 0, approvedSharesOther);
        _assertEpochAmountsEq(scId, USDC, 1, epochAmountsUsdc);
        _assertEpochAmountsEq(scId, OTHER_STABLE, 1, epochAmountsOther);
    }

    function testRevokeSharesSingleEpoch(uint128 redeemAmount, uint128 navPerShare, uint128 approvalRatio_)
        public
        notThisContract(poolRegistryAddress)
    {
        redeemAmount = uint128(bound(redeemAmount, MIN_REQUEST_AMOUNT, MAX_REQUEST_AMOUNT));
        D18 shareToPoolQuote = d18(uint128(bound(navPerShare, 1e14, type(uint128).max / 1e18)));
        D18 approvalRatio = d18(uint128(bound(approvalRatio_, 1e14, 1e18)));
        uint128 approvedRedeem = approvalRatio.mulUint128(redeemAmount);
        uint128 poolAmount = shareToPoolQuote.mulUint128(approvedRedeem);
        uint128 assetAmount = poolToUsdc(poolAmount);

        // Mock total issuance to equal redeemAmount
        vm.store(
            address(shareClass),
            keccak256(abi.encode(scId, uint256(STORAGE_INDEX_TOTAL_ISSUANCE))),
            bytes32(uint256(redeemAmount))
        );
        assertEq(shareClass.totalIssuance(scId), redeemAmount);

        shareClass.requestRedeem(poolId, scId, redeemAmount, investor, USDC);
        shareClass.approveRedeems(poolId, scId, approvalRatio, USDC);

        assertEq(shareClass.totalIssuance(scId), redeemAmount);
        _assertEpochPointersEq(scId, USDC, EpochPointers(0, 1, 0, 0));

        (uint128 payoutAssetAmount, uint128 payoutPoolAmount) =
            shareClass.revokeShares(poolId, scId, USDC, shareToPoolQuote, oracleMock);
        assertEq(assetAmount, payoutAssetAmount, "payout asset amount mismatch");
        assertEq(poolAmount, payoutPoolAmount, "payout pool amount mismatch");

        assertEq(shareClass.totalIssuance(scId), redeemAmount - approvedRedeem);
        _assertEpochPointersEq(scId, USDC, EpochPointers(0, 1, 0, 1));

        _assertEpochAmountsEq(scId, USDC, 1, EpochAmounts(d18(0), approvalRatio, 0, 0, 0, assetAmount, approvedRedeem));
    }

    function testClaimRedeemSingleEpoch(uint128 redeemAmount, uint128 navPerShare, uint128 approvalRatio_)
        public
        notThisContract(poolRegistryAddress)
    {
        redeemAmount = uint128(bound(redeemAmount, MIN_REQUEST_AMOUNT, type(uint128).max) / 1e18);
        D18 shareToPoolQuote = d18(uint128(bound(navPerShare, 1e10, type(uint128).max / 1e18)));
        D18 approvalRatio = d18(uint128(bound(approvalRatio_, 1e14, 1e18)));
        uint128 approvedRedeem = approvalRatio.mulUint128(redeemAmount);
        uint128 pendingRedeem = redeemAmount - approvedRedeem;
        uint128 payout = poolToUsdc(shareToPoolQuote.mulUint128(approvedRedeem));

        // Mock total issuance to equal redeemAmount
        vm.store(
            address(shareClass),
            keccak256(abi.encode(scId, uint256(STORAGE_INDEX_TOTAL_ISSUANCE))),
            bytes32(uint256(redeemAmount))
        );
        assertEq(shareClass.totalIssuance(scId), redeemAmount);

        shareClass.requestRedeem(poolId, scId, redeemAmount, investor, USDC);
        shareClass.approveRedeems(poolId, scId, approvalRatio, USDC);
        shareClass.revokeShares(poolId, scId, USDC, shareToPoolQuote, oracleMock);
        assertEq(shareClass.totalIssuance(scId), pendingRedeem);
        _assertRedeemRequestEq(scId, USDC, investor, UserOrder(redeemAmount, 1));

        if (payout > 0) {
            vm.expectEmit(true, true, true, true);
            emit IShareClassManager.ClaimedRedeem(
                poolId, scId, 1, investor, USDC, approvedRedeem, pendingRedeem, payout
            );
        }
        (uint128 payoutAssetAmount, uint128 paymentShareAmount) = shareClass.claimRedeem(poolId, scId, investor, USDC);

        assertEq(payout, payoutAssetAmount, "payout asset amount mismatch");
        assertEq(payout > 0 ? approvedRedeem : 0, paymentShareAmount, "payment shares mismatch");
        _assertRedeemRequestEq(
            scId, USDC, investor, UserOrder(payout > 0 ? pendingRedeem : pendingRedeem + approvedRedeem, 2)
        );

        // Ensure another claim has no impact
        (payoutAssetAmount, paymentShareAmount) = shareClass.claimRedeem(poolId, scId, investor, USDC);
        assertEq(payoutAssetAmount + paymentShareAmount, 0, "replay must not be possible");
    }

    function testClaimRedeemSkipped() public notThisContract(poolRegistryAddress) {
        uint128 pending = MAX_REQUEST_AMOUNT;
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

        (uint128 payout, uint128 payment) = shareClass.claimRedeem(poolId, scId, investor, USDC);
        assertEq(payout + payment, 0);
        _assertRedeemRequestEq(scId, USDC, investor, UserOrder(pending, mockEpochId));
    }
}

///@dev Contains all tests which require transient storage to reset between calls
contract SingleShareClassTransientTest is SingleShareClassBaseTest {
    using MathLib for uint128;

    function testIssueSharesManyEpochs(
        uint128 depositAmount,
        uint128 navPerShare_,
        uint128 approvalRatio_,
        uint8 maxEpochId
    ) public notThisContract(poolRegistryAddress) {
        depositAmount = uint128(bound(depositAmount, MIN_REQUEST_AMOUNT, MAX_REQUEST_AMOUNT / 100));
        D18 shareToPoolQuote = d18(uint128(bound(navPerShare_, 1e10, type(uint128).max / 1e18)));
        maxEpochId = uint8(bound(maxEpochId, 3, 50));
        D18 approvalRatio = d18(uint128(bound(approvalRatio_, 1e14, 1e18)));
        uint128 shares = 0;
        uint128 pendingUSDC = depositAmount;

        // Bump up latestApproval epochs
        for (uint8 i = 1; i < maxEpochId; i++) {
            bytes32 investor = bytes32(uint256(keccak256(abi.encodePacked("investor_", i))));
            _resetTransientEpochIncrement();
            shareClass.requestDeposit(poolId, scId, depositAmount, investor, USDC);
            shareClass.approveDeposits(poolId, scId, approvalRatio, USDC, oracleMock);
        }
        assertEq(shareClass.totalIssuance(scId), 0);

        // Assert issued events
        uint128 totalIssuance_;
        for (uint8 i = 1; i < maxEpochId; i++) {
            uint128 approvedUSDC = approvalRatio.mulUint128(pendingUSDC);
            pendingUSDC += depositAmount - approvedUSDC;
            uint128 epochShares = shareToPoolQuote.reciprocalMulUint128(usdcToPool(approvedUSDC));
            totalIssuance_ += epochShares;
            uint128 nav = shareToPoolQuote.mulUint128(totalIssuance_);

            vm.expectEmit(true, true, true, true);
            emit IShareClassManager.IssuedShares(poolId, scId, i, shareToPoolQuote, nav, epochShares);
        }

        shareClass.issueShares(poolId, scId, USDC, shareToPoolQuote);
        _assertEpochPointersEq(scId, USDC, EpochPointers(maxEpochId - 1, 0, maxEpochId - 1, 0));

        // Ensure each epoch is issued separately
        pendingUSDC = depositAmount;
        for (uint8 i = 1; i < maxEpochId; i++) {
            uint128 approvedUSDC = approvalRatio.mulUint128(pendingUSDC);
            pendingUSDC += depositAmount - approvedUSDC;
            uint128 approvedPool = usdcToPool(approvedUSDC);
            uint128 epochShares = shareToPoolQuote.reciprocalMulUint128(approvedPool);
            shares += epochShares;

            _assertEpochAmountsEq(
                scId, USDC, i, EpochAmounts(approvalRatio, d18(0), approvedUSDC, approvedPool, epochShares, 0, 0)
            );
        }
        assertEq(shareClass.totalIssuance(scId), shares, "totalIssuance mismatch");
        (D18 navPerShare, uint128 issuance) = shareClass.shareClassNavPerShare(poolId, scId);
        assertEq(navPerShare.inner(), shareToPoolQuote.inner());
        assertEq(issuance, shares, "totalIssuance mismatch");

        // Ensure another issuance reverts
        vm.expectRevert(abi.encodeWithSelector(ISingleShareClass.ApprovalRequired.selector));
        shareClass.issueShares(poolId, scId, USDC, shareToPoolQuote);
    }

    function testClaimDepositManyEpochs(
        uint128 depositAmount,
        uint128 navPerShare,
        uint128 approvalRatio_,
        uint8 maxEpochId
    ) public notThisContract(poolRegistryAddress) {
        D18 shareToPoolQuote = d18(uint128(bound(navPerShare, 1e10, type(uint128).max / 1e18)));
        maxEpochId = uint8(bound(maxEpochId, 3, 50));
        depositAmount = maxEpochId * uint128(bound(depositAmount, MIN_REQUEST_AMOUNT, MAX_REQUEST_AMOUNT / 100));
        D18 approvalRatio = d18(uint128(bound(approvalRatio_, 1e10, 1e16)));
        uint128 approvedUSDC = 0;
        uint128 pending = depositAmount;
        uint128 shares = 0;

        shareClass.requestDeposit(poolId, scId, depositAmount, investor, USDC);

        // Approve many epochs and issue shares
        for (uint8 i = 1; i < maxEpochId; i++) {
            shareClass.approveDeposits(poolId, scId, approvalRatio, USDC, oracleMock);
            shares += shareToPoolQuote.reciprocalMulUint128(usdcToPool(approvalRatio.mulUint128(pending)));
            approvedUSDC += approvalRatio.mulUint128(pending);
            pending = depositAmount - approvedUSDC;
            _resetTransientEpochIncrement();
        }
        shareClass.issueShares(poolId, scId, USDC, shareToPoolQuote);
        assertEq(shareClass.totalIssuance(scId), shares, "totalIssuance mismatch");

        // Ensure each epoch is claimed separately
        approvedUSDC = 0;
        pending = depositAmount;
        for (uint8 i = 1; i < maxEpochId; i++) {
            uint128 epochShares = shareToPoolQuote.reciprocalMulUint128(usdcToPool(approvalRatio.mulUint128(pending)));
            uint128 epochApprovedUSDC = approvalRatio.mulUint128(pending);

            if (epochShares > 0) {
                approvedUSDC += epochApprovedUSDC;
                pending -= epochApprovedUSDC;
            }
            vm.expectEmit(true, true, true, true);
            emit IShareClassManager.ClaimedDeposit(
                poolId, scId, i, investor, USDC, epochApprovedUSDC, pending, epochShares
            );
        }
        (uint128 userShares, uint128 payment) = shareClass.claimDeposit(poolId, scId, investor, USDC);

        assertEq(approvedUSDC + pending, depositAmount, "approved + pending must equal request amount");
        assertEq(shares, userShares, "shares mismatch");
        assertEq(approvedUSDC, payment, "payment mismatch");
        _assertDepositRequestEq(scId, USDC, investor, UserOrder(pending, maxEpochId));
    }

    function testRevokeSharesManyEpochs(
        uint128 redeemAmount,
        uint128 navPerShare_,
        uint128 approvalRatio_,
        uint8 maxEpochId
    ) public notThisContract(poolRegistryAddress) {
        redeemAmount = uint128(bound(redeemAmount, MIN_REQUEST_AMOUNT, MAX_REQUEST_AMOUNT));
        D18 shareToPoolQuote = d18(uint128(bound(navPerShare_, 1e10, type(uint128).max / 1e18)));
        maxEpochId = uint8(bound(maxEpochId, 3, 50));
        D18 approvalRatio = d18(uint128(bound(approvalRatio_, 1e14, 1e18)));
        uint128 totalIssuance_ = maxEpochId * redeemAmount;
        uint128 redeemedShares = 0;
        uint128 pendingRedeems = redeemAmount;

        // Mock total issuance to equal total redeemAmount
        vm.store(
            address(shareClass),
            keccak256(abi.encode(scId, uint256(STORAGE_INDEX_TOTAL_ISSUANCE))),
            bytes32(uint256(totalIssuance_))
        );

        // Bump up latestApproval epochs
        for (uint8 i = 1; i < maxEpochId; i++) {
            bytes32 investor = bytes32(uint256(keccak256(abi.encodePacked("investor_", i))));
            _resetTransientEpochIncrement();
            shareClass.requestRedeem(poolId, scId, redeemAmount, investor, USDC);
            shareClass.approveRedeems(poolId, scId, approvalRatio, USDC);
        }
        assertEq(shareClass.totalIssuance(scId), totalIssuance_);

        // Assert revoked events
        for (uint8 i = 1; i < maxEpochId; i++) {
            uint128 approvedRedeems = approvalRatio.mulUint128(pendingRedeems);
            totalIssuance_ -= approvedRedeems;
            uint128 nav = shareToPoolQuote.mulUint128(totalIssuance_);
            pendingRedeems += redeemAmount - approvedRedeems;
            uint128 revokedAssetAmount = poolToUsdc(shareToPoolQuote.mulUint128(approvedRedeems));

            vm.expectEmit(true, true, true, true);
            emit IShareClassManager.RevokedShares(
                poolId, scId, i, shareToPoolQuote, nav, approvedRedeems, revokedAssetAmount
            );
        }

        shareClass.revokeShares(poolId, scId, USDC, shareToPoolQuote, oracleMock);
        _assertEpochPointersEq(scId, USDC, EpochPointers(0, maxEpochId - 1, 0, maxEpochId - 1));

        // Ensure each epoch was revoked separately
        pendingRedeems = redeemAmount;
        for (uint8 i = 1; i < maxEpochId; i++) {
            uint128 approvedRedeems = approvalRatio.mulUint128(pendingRedeems);
            pendingRedeems += redeemAmount - approvedRedeems;
            redeemedShares += approvedRedeems;
            uint128 revokedAssetAmount = poolToUsdc(shareToPoolQuote.mulUint128(approvedRedeems));

            _assertEpochAmountsEq(
                scId, USDC, i, EpochAmounts(d18(0), approvalRatio, 0, 0, 0, revokedAssetAmount, approvedRedeems)
            );
        }
        assertEq(shareClass.totalIssuance(scId), totalIssuance_);
        (D18 navPerShare, uint128 issuance) = shareClass.shareClassNavPerShare(poolId, scId);
        assertEq(navPerShare.inner(), shareToPoolQuote.inner());
        assertEq(issuance, totalIssuance_);

        // Ensure another issuance reverts
        vm.expectRevert(abi.encodeWithSelector(ISingleShareClass.ApprovalRequired.selector));
        shareClass.revokeShares(poolId, scId, USDC, shareToPoolQuote, oracleMock);
    }

    function testClaimRedeemManyEpochs(
        uint128 redeemAmount,
        uint128 navPerShare_,
        uint128 approvalRatio_,
        uint8 maxEpochId
    ) public notThisContract(poolRegistryAddress) {
        D18 shareToPoolQuote = d18(uint128(bound(navPerShare_, 1e10, type(uint128).max / 1e18)));
        maxEpochId = uint8(bound(maxEpochId, 3, 50));
        redeemAmount = maxEpochId * uint128(bound(redeemAmount, MIN_REQUEST_AMOUNT, MAX_REQUEST_AMOUNT));
        D18 approvalRatio = d18(uint128(bound(approvalRatio_, 1e10, 1e16)));
        uint128 pendingRedeem = redeemAmount;
        uint128 payout = 0;
        uint128 approvedRedeem = 0;

        // Mock total issuance to equal total redeemAmount
        vm.store(
            address(shareClass),
            keccak256(abi.encode(scId, uint256(STORAGE_INDEX_TOTAL_ISSUANCE))),
            bytes32(uint256(redeemAmount))
        );

        shareClass.requestRedeem(poolId, scId, redeemAmount, investor, USDC);

        // Approve many epochs and revoke shares
        for (uint8 i = 1; i < maxEpochId; i++) {
            _resetTransientEpochIncrement();
            shareClass.approveRedeems(poolId, scId, approvalRatio, USDC);
            pendingRedeem -= approvalRatio.mulUint128(pendingRedeem);
        }
        shareClass.revokeShares(poolId, scId, USDC, shareToPoolQuote, oracleMock);
        assertEq(shareClass.totalIssuance(scId), pendingRedeem, "totalIssuance mismatch");

        // Ensure each epoch is claimed separately
        pendingRedeem = redeemAmount;
        for (uint8 i = 1; i < maxEpochId; i++) {
            uint128 epochApproved = approvalRatio.mulUint128(pendingRedeem);
            uint128 epochPayout = poolToUsdc(shareToPoolQuote.mulUint128(epochApproved));

            if (epochPayout > 0) {
                pendingRedeem -= approvalRatio.mulUint128(pendingRedeem);
                payout += epochPayout;
                approvedRedeem += epochApproved;
            }
            vm.expectEmit(true, true, true, true);
            emit IShareClassManager.ClaimedRedeem(
                poolId, scId, i, investor, USDC, epochApproved, pendingRedeem, epochPayout
            );
        }
        (uint128 payoutAssetAmount, uint128 paymentShareAmount) = shareClass.claimRedeem(poolId, scId, investor, USDC);

        assertEq(approvedRedeem + pendingRedeem, redeemAmount, "approved + pending must equal request amount");
        assertEq(payout, payoutAssetAmount, "payout asset amount mismatch");
        assertEq(approvedRedeem, paymentShareAmount, "payment shares mismatch");
        _assertRedeemRequestEq(scId, USDC, investor, UserOrder(pendingRedeem, maxEpochId));
    }

    function testDepositsWithRedeemsFullFlow(uint128 amount, uint128 approvalRatio, uint128 navPerShare_)
        public
        notThisContract(poolRegistryAddress)
    {
        D18 shareToPoolQuote = d18(uint128(bound(navPerShare_, 1e10, type(uint128).max / 1e18)));
        D18 navPerShareRedeem = shareToPoolQuote - d18(1e6);
        uint128 depositAmount = uint128(bound(amount, MIN_REQUEST_AMOUNT, MAX_REQUEST_AMOUNT));
        uint128 redeemAmount = uint128(bound(amount, MIN_REQUEST_AMOUNT, MAX_REQUEST_AMOUNT));
        EpochAmounts memory epochAmounts =
            EpochAmounts(d18(uint128(bound(approvalRatio, 1e10, 1e16))), d18(0), 0, 0, 0, 0, 0);

        // Step 1: Do initial deposit flow with 100% deposit approval rate to add sufficient shares for later redemption
        uint32 epochId = 2;
        shareClass.requestDeposit(poolId, scId, MAX_REQUEST_AMOUNT, investor, USDC);
        shareClass.approveDeposits(poolId, scId, d18(1e18), USDC, oracleMock);
        shareClass.issueShares(poolId, scId, USDC, shareToPoolQuote);
        shareClass.claimDeposit(poolId, scId, investor, USDC);

        uint128 shares = shareToPoolQuote.reciprocalMulUint128(usdcToPool(MAX_REQUEST_AMOUNT));
        assertEq(shareClass.totalIssuance(scId), shares);
        assertEq(shareClass.epochId(poolId), 2);
        _assertDepositRequestEq(scId, USDC, investor, UserOrder(0, 2));
        _assertEpochAmountsEq(
            scId,
            USDC,
            1,
            EpochAmounts(d18(1e18), d18(0), MAX_REQUEST_AMOUNT, usdcToPool(MAX_REQUEST_AMOUNT), shares, 0, 0)
        );
        _assertDepositRequestEq(scId, USDC, investor, UserOrder(0, 2));

        // Step 2a: Deposit + redeem at same
        _resetTransientEpochIncrement();
        shareClass.requestDeposit(poolId, scId, depositAmount, investor, USDC);
        shareClass.requestRedeem(poolId, scId, redeemAmount, investor, USDC);
        uint128 pendingDepositUSDC = depositAmount;
        _assertDepositRequestEq(scId, USDC, investor, UserOrder(pendingDepositUSDC, epochId));
        _assertRedeemRequestEq(scId, USDC, investor, UserOrder(redeemAmount, epochId));

        // Step 2b: Approve deposits
        shareClass.approveDeposits(poolId, scId, epochAmounts.depositApprovalRate, USDC, oracleMock);
        epochAmounts.depositAssetAmount = epochAmounts.depositApprovalRate.mulUint128(pendingDepositUSDC);
        epochAmounts.depositPoolAmount = usdcToPool(epochAmounts.depositAssetAmount);
        _assertEpochAmountsEq(scId, USDC, epochId, epochAmounts);

        // Step 2c: Approve redeems
        epochAmounts.redeemApprovalRate =
            d18(uint128(bound(approvalRatio, 1e10, epochAmounts.depositApprovalRate.inner())));
        shareClass.approveRedeems(poolId, scId, epochAmounts.redeemApprovalRate, USDC);
        epochAmounts.redeemSharesRevoked = epochAmounts.redeemApprovalRate.mulUint128(redeemAmount);
        _assertDepositRequestEq(scId, USDC, investor, UserOrder(depositAmount, epochId));
        _assertRedeemRequestEq(scId, USDC, investor, UserOrder(redeemAmount, epochId));
        _assertEpochAmountsEq(scId, USDC, epochId, epochAmounts);

        // Step 2d: Issue shares
        shareClass.issueShares(poolId, scId, USDC, shareToPoolQuote);
        epochAmounts.depositSharesIssued =
            shareToPoolQuote.reciprocalMulUint128(usdcToPool(epochAmounts.depositAssetAmount));
        shares += epochAmounts.depositSharesIssued;
        assertEq(shareClass.totalIssuance(scId), shares);
        _assertEpochAmountsEq(scId, USDC, epochId, epochAmounts);

        // Step 2e: Revoke shares
        shareClass.revokeShares(poolId, scId, USDC, navPerShareRedeem, oracleMock);
        shares -= epochAmounts.redeemSharesRevoked;
        (D18 navPerShare, uint128 issuance) = shareClass.shareClassNavPerShare(poolId, scId);
        assertEq(issuance, shares);
        assertEq(navPerShare.inner(), navPerShareRedeem.inner());
        epochAmounts.redeemAssetAmount = poolToUsdc(navPerShareRedeem.mulUint128(epochAmounts.redeemSharesRevoked));
        _assertEpochAmountsEq(scId, USDC, epochId, epochAmounts);

        // Step 2f: Claim deposit and redeem
        epochId += 1;
        (, uint128 claimDepositAssetPaymentAmount) = shareClass.claimDeposit(poolId, scId, investor, USDC);
        (, uint128 claimRedeemSharePayementAmount) = shareClass.claimRedeem(poolId, scId, investor, USDC);
        pendingDepositUSDC -= claimDepositAssetPaymentAmount == 0 ? 0 : epochAmounts.depositAssetAmount;
        _assertDepositRequestEq(scId, USDC, investor, UserOrder(pendingDepositUSDC, epochId));
        uint128 pendingRedeem =
            claimRedeemSharePayementAmount == 0 ? redeemAmount : redeemAmount - epochAmounts.redeemSharesRevoked;
        _assertRedeemRequestEq(scId, USDC, investor, UserOrder(pendingRedeem, epochId));
        _assertEpochAmountsEq(scId, USDC, 2, epochAmounts);
        _assertEpochAmountsEq(scId, USDC, epochId, EpochAmounts(d18(0), d18(0), 0, 0, 0, 0, 0));
    }
}

///@dev Contains all deposit tests which deal with rounding edge cases
contract SingleShareClassRoundingEdgeCasesDeposit is SingleShareClassBaseTest {
    using MathLib for uint128;

    bytes32 constant INVESTOR_A = bytes32("investorA");
    bytes32 constant INVESTOR_B = bytes32("investorB");
    bytes32 constant INVESTOR_C = bytes32("investorC");

    function _approveAllDepositsAndIssue(uint128 expectedShareIssuance, D18 navPerShare) private {
        shareClass.approveDeposits(poolId, scId, d18(1e18), USDC, oracleMock);
        shareClass.issueShares(poolId, scId, USDC, navPerShare);
        assertEq(shareClass.totalIssuance(scId), expectedShareIssuance, "Mismatch in expected shares");
    }

    /// @dev Investors cannot claim the single issued share atom (one of smallest denomination of share)
    function testClaimDepositSingleShareAtom() public notThisContract(poolRegistryAddress) {
        uint128 approvedAssetAmount = 100 * DENO_USDC;
        uint128 issuedShares = 1;
        D18 navPerShare = d18(usdcToPool(approvedAssetAmount) / issuedShares * 1e18);

        shareClass.requestDeposit(poolId, scId, 1, INVESTOR_A, USDC);
        shareClass.requestDeposit(poolId, scId, approvedAssetAmount - 1, INVESTOR_B, USDC);
        _approveAllDepositsAndIssue(issuedShares, navPerShare);

        (uint128 claimedA, uint128 paymentA) = shareClass.claimDeposit(poolId, scId, INVESTOR_A, USDC);
        (uint128 claimedB, uint128 paymentB) = shareClass.claimDeposit(poolId, scId, INVESTOR_B, USDC);

        assertEq(claimedA, claimedB, "Claimed shares should be equal");
        assertEq(claimedA + claimedB + 1, issuedShares, "System should have 1 share class token atom surplus");
        assertEq(paymentA + paymentB, 0, "Payment should be zero since neither investor could claim single share atom");

        _assertDepositRequestEq(scId, USDC, INVESTOR_A, UserOrder(1, 2));
        _assertDepositRequestEq(scId, USDC, INVESTOR_B, UserOrder(approvedAssetAmount - 1, 2));
    }

    /// @dev Investors can claim 50% rounded down of an uneven number of shares => 1 share atom surplus in system
    function testClaimDepositEvenInvestorsUnevenClaimable() public notThisContract(poolRegistryAddress) {
        uint128 approvedAssetAmount = 100 * DENO_USDC;
        uint128 issuedShares = 11;
        D18 navPerShare = d18(usdcToPool(approvedAssetAmount) / issuedShares * 1e18);

        shareClass.requestDeposit(poolId, scId, 49 * approvedAssetAmount / 100, INVESTOR_A, USDC);
        shareClass.requestDeposit(poolId, scId, 51 * approvedAssetAmount / 100, INVESTOR_B, USDC);
        _approveAllDepositsAndIssue(issuedShares, navPerShare);

        (uint128 claimedA, uint128 paymentA) = shareClass.claimDeposit(poolId, scId, INVESTOR_A, USDC);
        (uint128 claimedB, uint128 paymentB) = shareClass.claimDeposit(poolId, scId, INVESTOR_B, USDC);

        assertEq(claimedA, claimedB, "Claimed shares should be equal");
        assertEq(claimedA + claimedB + 1, issuedShares, "System should have 1 share class token atom surplus");
        assert(paymentA != paymentB);
    }

    /// @dev Investors can claim 1/3 of an even number of shares => 1 share atom surplus in system
    function testClaimDepositUnevenInvestorsEvenClaimable() public notThisContract(poolRegistryAddress) {
        uint128 approvedAssetAmount = 100 * DENO_USDC;
        uint128 issuedShares = 10;
        D18 navPerShare = d18(usdcToPool(approvedAssetAmount) / issuedShares * 1e18);

        shareClass.requestDeposit(poolId, scId, 30 * approvedAssetAmount / 100, INVESTOR_A, USDC);
        shareClass.requestDeposit(poolId, scId, 31 * approvedAssetAmount / 100, INVESTOR_B, USDC);
        shareClass.requestDeposit(poolId, scId, 39 * approvedAssetAmount / 100, INVESTOR_C, USDC);
        _approveAllDepositsAndIssue(issuedShares, navPerShare);

        (uint128 claimedA, uint128 paymentA) = shareClass.claimDeposit(poolId, scId, INVESTOR_A, USDC);
        (uint128 claimedB, uint128 paymentB) = shareClass.claimDeposit(poolId, scId, INVESTOR_B, USDC);
        (uint128 claimedC, uint128 paymentC) = shareClass.claimDeposit(poolId, scId, INVESTOR_C, USDC);

        assertEq(claimedA, claimedB, "Claimed shares should be equal");
        assertEq(claimedB, claimedC, "Claimed shares should be equal");
        assertEq(
            claimedA + claimedB + claimedC + 1, issuedShares, "System should have 1 share class token atom surplus"
        );
        assert(paymentA != paymentB && paymentB != paymentC && paymentC != paymentA);
    }
}

///@dev Contains all deposit tests which deal with rounding edge cases
contract SingleShareClassRoundingEdgeCasesRedeem is SingleShareClassBaseTest {
    using MathLib for uint128;
    using MathLib for uint256;

    bytes32 constant INVESTOR_A = bytes32("investorA");
    bytes32 constant INVESTOR_B = bytes32("investorB");
    bytes32 constant INVESTOR_C = bytes32("investorC");
    uint128 TOTAL_ISSUANCE = 1000 * DENO_POOL;

    function setUp() public override {
        SingleShareClassBaseTest.setUp();

        // Mock total issuance such that we can redeem
        vm.store(
            address(shareClass),
            keccak256(abi.encode(scId, uint256(STORAGE_INDEX_TOTAL_ISSUANCE))),
            bytes32(uint256(TOTAL_ISSUANCE))
        );
    }

    function _approveAllRedeemsAndRevoke(uint128 approvedShareAmount, uint128 expectedAssetPayout, D18 navPerShare)
        private
    {
        shareClass.approveRedeems(poolId, scId, d18(1e18), USDC);
        (uint128 assetPayout,) = shareClass.revokeShares(poolId, scId, USDC, navPerShare, oracleMock);
        assertEq(shareClass.totalIssuance(scId), TOTAL_ISSUANCE - approvedShareAmount, "Mismatch in expected shares");
        assertEq(shareClass.pendingRedeem(scId, USDC), 0, "Pending redeem should have decreased");
        assertEq(assetPayout, expectedAssetPayout, "Mismatch in expected asset payout");
    }

    /// @dev Investors cannot claim anything despite
    function testClaimRedeemSingleAssetAtom() public notThisContract(poolRegistryAddress) {
        uint128 approvedShareAmount = DENO_POOL / DENO_USDC;
        uint128 assetPayout = 1;
        uint128 poolPayout = usdcToPool(assetPayout);
        D18 navPerShare = d18(poolPayout * 1e18 / approvedShareAmount); // = 1e18

        shareClass.requestRedeem(poolId, scId, 1, INVESTOR_A, USDC);
        shareClass.requestRedeem(poolId, scId, approvedShareAmount - 1, INVESTOR_B, USDC);
        _approveAllRedeemsAndRevoke(approvedShareAmount, assetPayout, navPerShare);

        (uint128 claimedA, uint128 paymentA) = shareClass.claimRedeem(poolId, scId, INVESTOR_A, USDC);
        (uint128 claimedB, uint128 paymentB) = shareClass.claimRedeem(poolId, scId, INVESTOR_B, USDC);

        assertEq(claimedA, claimedB, "Both investors should have claimed same amount");
        assertEq(claimedA + claimedB, 0, "Claimed amount should be zero for both investors");
        assertEq(paymentA + paymentB, 0, "Payment should be zero since neither investor could claim anything");
        assertEq(shareClass.pendingRedeem(scId, USDC), approvedShareAmount, "Pending redeem should have reset");

        _assertRedeemRequestEq(scId, USDC, INVESTOR_A, UserOrder(1, 2));
        _assertRedeemRequestEq(scId, USDC, INVESTOR_B, UserOrder(approvedShareAmount - 1, 2));
    }

    /// @dev Investors can claim 50% rounded down of an uneven number of asset amount => 1 asset amount surplus in
    /// system
    function testClaimRedeemEvenInvestorsUnevenClaimable() public notThisContract(poolRegistryAddress) {
        uint128 approvedShareAmount = DENO_POOL / DENO_USDC;
        uint128 assetPayout = 11;
        uint128 poolPayout = usdcToPool(assetPayout);
        D18 navPerShare = d18(poolPayout * 1e18 / approvedShareAmount);

        shareClass.requestRedeem(poolId, scId, 49 * approvedShareAmount / 100, INVESTOR_A, USDC);
        shareClass.requestRedeem(poolId, scId, 51 * approvedShareAmount / 100, INVESTOR_B, USDC);
        _approveAllRedeemsAndRevoke(approvedShareAmount, assetPayout, navPerShare);

        (uint128 claimedA, uint128 paymentA) = shareClass.claimRedeem(poolId, scId, INVESTOR_A, USDC);
        (uint128 claimedB, uint128 paymentB) = shareClass.claimRedeem(poolId, scId, INVESTOR_B, USDC);

        assertEq(claimedA, claimedB, "Claimed asset amount should be equal");
        assertEq(claimedA + claimedB + 1, assetPayout, "System should have 1 asset amount atom surplus");
        assert(paymentA != paymentB);
        assertEq(shareClass.pendingRedeem(scId, USDC), 0, "Pending redeem should not have reset");

        _assertRedeemRequestEq(scId, USDC, INVESTOR_A, UserOrder(0, 2));
        _assertRedeemRequestEq(scId, USDC, INVESTOR_B, UserOrder(0, 2));
    }

    /// @dev Investors can claim 50% rounded down of an uneven number of asset amount => 1 asset amount surplus in
    /// system
    function testClaimRedeemUnevenInvestorsEvenClaimable() public notThisContract(poolRegistryAddress) {
        uint128 approvedShareAmount = DENO_POOL / DENO_USDC;
        uint128 assetPayout = 10;
        uint128 poolPayout = usdcToPool(assetPayout);
        D18 navPerShare = d18(poolPayout * 1e18 / approvedShareAmount);

        shareClass.requestRedeem(poolId, scId, 30 * approvedShareAmount / 100, INVESTOR_A, USDC);
        shareClass.requestRedeem(poolId, scId, 31 * approvedShareAmount / 100, INVESTOR_B, USDC);
        shareClass.requestRedeem(poolId, scId, 39 * approvedShareAmount / 100, INVESTOR_C, USDC);
        _approveAllRedeemsAndRevoke(approvedShareAmount, assetPayout, navPerShare);

        (uint128 claimedA, uint128 paymentA) = shareClass.claimRedeem(poolId, scId, INVESTOR_A, USDC);
        (uint128 claimedB, uint128 paymentB) = shareClass.claimRedeem(poolId, scId, INVESTOR_B, USDC);
        (uint128 claimedC, uint128 paymentC) = shareClass.claimRedeem(poolId, scId, INVESTOR_C, USDC);

        assertEq(claimedA, claimedB, "Claimed asset amount should be equal");
        assertEq(claimedB, claimedC, "Claimed asset amount should be equal");
        assertEq(claimedA + claimedB + claimedC + 1, assetPayout, "System should have 1 asset amount atom surplus");
        assert(paymentA != paymentB && paymentB != paymentC && paymentC != paymentA);
        assertEq(shareClass.pendingRedeem(scId, USDC), 0, "Pending redeem should not have reset");

        _assertRedeemRequestEq(scId, USDC, INVESTOR_A, UserOrder(0, 2));
        _assertRedeemRequestEq(scId, USDC, INVESTOR_B, UserOrder(0, 2));
        _assertRedeemRequestEq(scId, USDC, INVESTOR_C, UserOrder(0, 2));
    }
}

///@dev Contains all tests which are expected to revert
contract SingleShareClassRevertsTest is SingleShareClassBaseTest {
    using MathLib for uint128;

    ShareClassId wrongShareClassId = ShareClassId.wrap(bytes16(uint128(POOL_ID + 1)));
    address unauthorized = makeAddr("unauthorizedAddress");

    function testFile(bytes32 what) public {
        vm.assume(what != "poolRegistry");
        vm.expectRevert(abi.encodeWithSelector(ISingleShareClass.UnrecognizedFileParam.selector));
        shareClass.file(what, address(0));
    }

    function testSetShareClassIdAlreadySet() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.MaxShareClassNumberExceeded.selector, 1));
        shareClass.addShareClass(poolId, bytes(""));
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
        shareClass.approveDeposits(poolId, wrongShareClassId, d18(1), USDC, IERC7726(address(this)));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        shareClass.approveDeposits(poolId, wrongShareClassId, d18(1), USDC, IERC7726(address(this)));
    }

    function testApproveRedeemsWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassNotFound.selector));
        shareClass.approveRedeems(poolId, wrongShareClassId, d18(1), USDC);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        shareClass.approveRedeems(poolId, wrongShareClassId, d18(1), USDC);
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

    function testUpdateShareClassNavWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassNotFound.selector));
        shareClass.updateShareClassNav(poolId, wrongShareClassId);
    }

    function testGetShareClassNavWrongShareClassId() public {
        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ShareClassNotFound.selector));
        shareClass.shareClassNavPerShare(poolId, wrongShareClassId);
    }

    function testIssueSharesBeforeApproval() public {
        vm.expectRevert(abi.encodeWithSelector(ISingleShareClass.ApprovalRequired.selector));
        shareClass.issueShares(poolId, scId, USDC, d18(1));
    }

    function testRevokeSharesBeforeApproval() public {
        vm.expectRevert(abi.encodeWithSelector(ISingleShareClass.ApprovalRequired.selector));
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

    function testUpdateShareClassUnsupported() public {
        vm.expectRevert(bytes("unsupported"));
        shareClass.updateShareClassNav(poolId, scId);
    }

    function testUpdateUnsupported() public {
        vm.expectRevert(bytes("unsupported"));
        shareClass.update(poolId, bytes(""));
    }

    function testRequestDepositRequiresClaim() public {
        shareClass.requestDeposit(poolId, scId, 1, investor, USDC);
        shareClass.approveDeposits(poolId, scId, d18(1), USDC, oracleMock);

        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ClaimDepositRequired.selector));
        shareClass.requestDeposit(poolId, scId, 1, investor, USDC);
    }

    function testRequestRedeemRequiresClaim() public {
        shareClass.requestRedeem(poolId, scId, 1, investor, USDC);
        shareClass.approveRedeems(poolId, scId, d18(1), USDC);

        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.ClaimRedeemRequired.selector));
        shareClass.requestRedeem(poolId, scId, 1, investor, USDC);
    }

    function testApproveDepositsAlreadyApproved() public {
        shareClass.approveDeposits(poolId, scId, d18(1), USDC, oracleMock);

        vm.expectRevert(ISingleShareClass.AlreadyApproved.selector);
        shareClass.approveDeposits(poolId, scId, d18(1), USDC, oracleMock);
    }

    function testApproveRedeemsAlreadyApproved() public {
        shareClass.approveRedeems(poolId, scId, d18(1), USDC);

        vm.expectRevert(ISingleShareClass.AlreadyApproved.selector);
        shareClass.approveRedeems(poolId, scId, d18(1), USDC);
    }

    function testApproveDepositsRatioExcess() public {
        vm.expectRevert(ISingleShareClass.ApprovalRatioOutOfBounds.selector);
        shareClass.approveDeposits(poolId, scId, d18(1e18 + 1), USDC, oracleMock);
    }

    function testApproveRedeemsRatioExcess() public {
        vm.expectRevert(ISingleShareClass.ApprovalRatioOutOfBounds.selector);
        shareClass.approveRedeems(poolId, scId, d18(1e18 + 1), USDC);
    }

    function testApproveDepositsRatioInsufficient() public {
        vm.expectRevert(ISingleShareClass.ApprovalRatioOutOfBounds.selector);
        shareClass.approveDeposits(poolId, scId, d18(0), USDC, oracleMock);
    }

    function testApproveRedeemsRatioInsufficient() public {
        vm.expectRevert(ISingleShareClass.ApprovalRatioOutOfBounds.selector);
        shareClass.approveRedeems(poolId, scId, d18(0), USDC);
    }

    function testAddShareClassInvalidMetadata(bytes memory metadata) public {
        vm.assume(metadata.length < 128 + 128 + 32);

        vm.expectRevert(ISingleShareClass.InvalidMetadataSize.selector);
        shareClass.addShareClass(PoolId.wrap(POOL_ID + 1), metadata);
    }

    function testAddShareClassInvalidName() public {
        vm.expectRevert(ISingleShareClass.InvalidMetadataName.selector);
        shareClass.addShareClass(PoolId.wrap(POOL_ID + 1), _encodeMetadata("", SC_META_SYMBOL, SC_META_HOOK));
    }

    function testAddShareClassInvalidSymbol() public {
        vm.expectRevert(ISingleShareClass.InvalidMetadataSymbol.selector);
        shareClass.addShareClass(PoolId.wrap(POOL_ID + 1), _encodeMetadata(SC_META_NAME, "", SC_META_HOOK));
    }

    function testAddShareClassInvalidHook() public {
        vm.expectRevert(ISingleShareClass.InvalidMetadataHook.selector);
        shareClass.addShareClass(PoolId.wrap(POOL_ID + 1), _encodeMetadata(SC_META_NAME, SC_META_SYMBOL, bytes32("")));
    }

    function testSetMetadataInvalidScId() public {
        vm.expectRevert(IShareClassManager.ShareClassNotFound.selector);
        shareClass.setMetadata(poolId, wrongShareClassId, bytes(""));
    }

    function testSetMetadataInvalidMetadata(bytes memory metadata) public {
        vm.assume(metadata.length < 128 + 128 + 32);

        vm.expectRevert(ISingleShareClass.InvalidMetadataSize.selector);
        shareClass.setMetadata(poolId, scId, metadata);
    }

    function testSetMetadataInvalidName() public {
        vm.expectRevert(ISingleShareClass.InvalidMetadataName.selector);
        shareClass.setMetadata(poolId, scId, _encodeMetadata("", SC_META_SYMBOL, SC_META_HOOK));
    }

    function testSetMetadataInvalidSymbol() public {
        vm.expectRevert(ISingleShareClass.InvalidMetadataSymbol.selector);
        shareClass.setMetadata(poolId, scId, _encodeMetadata(SC_META_NAME, "", SC_META_HOOK));
    }

    function testSetMetadataInvalidHook() public {
        vm.expectRevert(ISingleShareClass.InvalidMetadataHook.selector);
        shareClass.setMetadata(poolId, scId, _encodeMetadata(SC_META_NAME, SC_META_SYMBOL, bytes32("")));
    }
}
