// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "../../../../src/misc/types/D18.sol";
import {Multicall} from "../../../../src/misc/Multicall.sol";
import {IAuth} from "../../../../src/misc/interfaces/IAuth.sol";

import {PoolId} from "../../../../src/common/types/PoolId.sol";
import {IGateway} from "../../../../src/common/interfaces/IGateway.sol";
import {AssetId, newAssetId} from "../../../../src/common/types/AssetId.sol";
import {ICrosschainBatcher} from "../../../../src/common/interfaces/ICrosschainBatcher.sol";
import {ShareClassId, newShareClassId} from "../../../../src/common/types/ShareClassId.sol";

import {IHub} from "../../../../src/hub/interfaces/IHub.sol";
import {IHubRegistry} from "../../../../src/hub/interfaces/IHubRegistry.sol";
import {BatchSimplePriceManager} from "../../../../src/managers/hub/BatchSimplePriceManager.sol";
import {IShareClassManager} from "../../../../src/hub/interfaces/IShareClassManager.sol";
import {IBatchSimplePriceManager} from "../../../../src/managers/hub/interfaces/IBatchSimplePriceManager.sol";
import {ISimplePriceManager} from "../../../../src/managers/hub/interfaces/ISimplePriceManager.sol";

import {IBatchRequestManager} from "../../../../src/vaults/interfaces/IBatchRequestManager.sol";

import "forge-std/Test.sol";

contract IsContract {}

contract MockCrosschainBatcher {
    function execute(bytes memory data) external payable returns (uint256 cost) {
        (bool success, bytes memory returnData) = msg.sender.call{value: msg.value}(data);
        if (!success) {
            uint256 length = returnData.length;
            require(length != 0, "Empty revert");

            assembly ("memory-safe") {
                revert(add(32, returnData), length)
            }
        }
        return 0;
    }
}

contract MockHub is Multicall {
    function notifySharePrice(PoolId poolId, ShareClassId scId, uint16 centrifugeId) external payable {}
}

contract BatchSimplePriceManagerTest is Test {
    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId immutable SC_1 = newShareClassId(POOL_A, 1);
    ShareClassId immutable SC_2 = newShareClassId(POOL_A, 2);
    uint16 constant CENTRIFUGE_ID_1 = 1;

    AssetId asset1 = newAssetId(1, 1);

    address hub = address(new MockHub());
    address hubRegistry = address(new IsContract());
    address shareClassManager = address(new IsContract());
    address batchRequestManager = address(new IsContract());
    address crosschainBatcher = address(new MockCrosschainBatcher());

    address unauthorized = makeAddr("unauthorized");
    address hubManager = makeAddr("hubManager");
    address manager = makeAddr("manager");
    address caller = makeAddr("caller");
    address auth = makeAddr("auth");

    BatchSimplePriceManager priceManager;

    function setUp() public virtual {
        _setupMocks();
        _deployManager();
    }

    function _setupMocks() internal {
        vm.mockCall(hub, abi.encodeWithSelector(IHub.shareClassManager.selector), abi.encode(shareClassManager));
        vm.mockCall(hub, abi.encodeWithSelector(IHub.hubRegistry.selector), abi.encode(hubRegistry));
        vm.mockCall(hub, abi.encodeWithSelector(IHub.updateSharePrice.selector), abi.encode());
        vm.mockCall(hub, abi.encodeWithSelector(IHub.notifySharePrice.selector), abi.encode(uint256(0)));
        vm.mockCall(
            hub, abi.encodeWithSelector(IHub.pricePoolPerAsset.selector, POOL_A, SC_1, asset1), abi.encode(d18(1, 1))
        );

        vm.mockCall(
            hubRegistry,
            abi.encodeWithSelector(IHubRegistry.hubRequestManager.selector),
            abi.encode(batchRequestManager)
        );
        vm.mockCall(hubRegistry, abi.encodeWithSelector(IHubRegistry.manager.selector), abi.encode(false));
        vm.mockCall(
            hubRegistry, abi.encodeWithSelector(IHubRegistry.manager.selector, POOL_A, hubManager), abi.encode(true)
        );

        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.issuance.selector, SC_1, CENTRIFUGE_ID_1),
            abi.encode(100)
        );

        vm.mockCall(
            batchRequestManager,
            abi.encodeWithSelector(IBatchRequestManager.nowDepositEpoch.selector, SC_1, asset1),
            abi.encode(1)
        );
        vm.mockCall(
            batchRequestManager,
            abi.encodeWithSelector(IBatchRequestManager.nowIssueEpoch.selector, SC_1, asset1),
            abi.encode(1)
        );
        vm.mockCall(
            batchRequestManager,
            abi.encodeWithSelector(IBatchRequestManager.nowRedeemEpoch.selector, SC_1, asset1),
            abi.encode(2)
        );
        vm.mockCall(
            batchRequestManager,
            abi.encodeWithSelector(IBatchRequestManager.nowRevokeEpoch.selector, SC_1, asset1),
            abi.encode(2)
        );
        vm.mockCall(
            batchRequestManager,
            abi.encodeWithSelector(IBatchRequestManager.approveDeposits.selector),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            batchRequestManager,
            abi.encodeWithSelector(IBatchRequestManager.issueShares.selector),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            batchRequestManager, abi.encodeWithSelector(IBatchRequestManager.approveRedeems.selector), abi.encode()
        );
        vm.mockCall(
            batchRequestManager,
            abi.encodeWithSelector(IBatchRequestManager.revokeShares.selector),
            abi.encode(uint256(0))
        );
    }

    function _deployManager() internal {
        priceManager = new BatchSimplePriceManager(IHub(hub), ICrosschainBatcher(crosschainBatcher), auth);
        vm.prank(auth);
        priceManager.rely(caller);
        vm.prank(auth);
        priceManager.rely(crosschainBatcher);

        vm.prank(hubManager);
        priceManager.updateManager(POOL_A, manager, true);

        vm.deal(address(priceManager), 1 ether);
    }
}

contract BatchSimplePriceManagerInvestorActionsTest is BatchSimplePriceManagerTest {
    D18 expectedNavPerShare = d18(10, 1); // 1000/100 = 10

    function setUp() public override {
        super.setUp();

        vm.prank(caller);
        priceManager.onUpdate(POOL_A, SC_1, CENTRIFUGE_ID_1, 1000);
    }

    function testApproveDepositsAndIssueSharesSuccess() public {
        uint128 approvedAssetAmount = 500;
        uint128 extraGasLimit = 100000;

        vm.expectCall(
            address(batchRequestManager),
            abi.encodeWithSelector(
                IBatchRequestManager.approveDeposits.selector, POOL_A, SC_1, asset1, 1, approvedAssetAmount, d18(1, 1)
            )
        );
        vm.expectCall(
            address(batchRequestManager),
            abi.encodeWithSelector(
                IBatchRequestManager.issueShares.selector,
                POOL_A,
                SC_1,
                asset1,
                uint32(1),
                expectedNavPerShare,
                extraGasLimit
            )
        );

        vm.prank(manager);
        priceManager.approveDepositsAndIssueShares(POOL_A, SC_1, asset1, approvedAssetAmount, extraGasLimit);
    }

    function testApproveDepositsAndIssueSharesUnauthorized() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        priceManager.approveDepositsAndIssueShares(POOL_A, SC_1, asset1, 500, 100000);
    }

    function testApproveDepositsAndIssueSharesMismatchedEpochs() public {
        vm.mockCall(
            batchRequestManager,
            abi.encodeWithSelector(IBatchRequestManager.nowDepositEpoch.selector, SC_1, asset1),
            abi.encode(1)
        );
        vm.mockCall(
            batchRequestManager,
            abi.encodeWithSelector(IBatchRequestManager.nowIssueEpoch.selector, SC_1, asset1),
            abi.encode(2)
        );

        vm.expectRevert(ISimplePriceManager.MismatchedEpochs.selector);
        vm.prank(manager);
        priceManager.approveDepositsAndIssueShares(POOL_A, SC_1, asset1, 500, 100000);
    }

    function testApproveRedeemsAndRevokeSharesSuccess() public {
        uint128 approvedShareAmount = 50;
        uint128 extraGasLimit = 100000;

        vm.expectCall(
            address(batchRequestManager),
            abi.encodeWithSelector(
                IBatchRequestManager.approveRedeems.selector,
                POOL_A,
                SC_1,
                asset1,
                uint32(2),
                approvedShareAmount,
                d18(1, 1)
            )
        );
        vm.expectCall(
            address(batchRequestManager),
            abi.encodeWithSelector(
                IBatchRequestManager.revokeShares.selector,
                POOL_A,
                SC_1,
                asset1,
                uint32(2),
                expectedNavPerShare,
                extraGasLimit
            )
        );

        vm.prank(manager);
        priceManager.approveRedeemsAndRevokeShares(POOL_A, SC_1, asset1, approvedShareAmount, extraGasLimit);
    }

    function testApproveRedeemsAndRevokeSharesUnauthorized() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        priceManager.approveRedeemsAndRevokeShares(POOL_A, SC_1, asset1, 50, 100000);
    }

    function testApproveRedeemsAndRevokeSharesMismatchedEpochs() public {
        vm.mockCall(
            batchRequestManager,
            abi.encodeWithSelector(IBatchRequestManager.nowRedeemEpoch.selector, SC_1, asset1),
            abi.encode(2)
        );
        vm.mockCall(
            batchRequestManager,
            abi.encodeWithSelector(IBatchRequestManager.nowRevokeEpoch.selector, SC_1, asset1),
            abi.encode(3)
        );

        vm.expectRevert(ISimplePriceManager.MismatchedEpochs.selector);
        vm.prank(manager);
        priceManager.approveRedeemsAndRevokeShares(POOL_A, SC_1, asset1, 50, 100000);
    }

    function testApproveRedeemsSuccess() public {
        uint128 approvedShareAmount = 50;

        vm.expectCall(
            address(batchRequestManager),
            abi.encodeWithSelector(
                IBatchRequestManager.approveRedeems.selector,
                POOL_A,
                SC_1,
                asset1,
                uint32(2),
                approvedShareAmount,
                d18(1, 1)
            )
        );

        vm.prank(manager);
        priceManager.approveRedeems(POOL_A, SC_1, asset1, approvedShareAmount);

        (,, uint32 issueEpochsBehind, uint32 revokeEpochsBehind) = priceManager.networkMetrics(POOL_A, CENTRIFUGE_ID_1);
        assertEq(revokeEpochsBehind, 1);
        assertEq(issueEpochsBehind, 0);
    }

    function testApproveRedeemsUnauthorized() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        priceManager.approveRedeems(POOL_A, SC_1, asset1, 50);
    }

    function testRevokeSharesSuccess() public {
        uint128 extraGasLimit = 100000;

        vm.prank(manager);
        priceManager.approveRedeems(POOL_A, SC_1, asset1, 50);

        vm.expectCall(
            address(batchRequestManager),
            abi.encodeWithSelector(
                IBatchRequestManager.revokeShares.selector, POOL_A, SC_1, asset1, uint32(2), d18(10, 1), extraGasLimit
            )
        );

        vm.prank(manager);
        priceManager.revokeShares(POOL_A, SC_1, asset1, extraGasLimit);

        (,, uint32 issueEpochsBehind, uint32 revokeEpochsBehind) = priceManager.networkMetrics(POOL_A, CENTRIFUGE_ID_1);
        assertEq(revokeEpochsBehind, 0);
        assertEq(issueEpochsBehind, 0);
    }

    function testRevokeSharesUnauthorized() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        priceManager.revokeShares(POOL_A, SC_1, asset1, 100000);
    }

    function testRevokeSharesWithoutPendingEpochs() public {
        vm.expectRevert(ISimplePriceManager.MismatchedEpochs.selector);
        vm.prank(manager);
        priceManager.revokeShares(POOL_A, SC_1, asset1, 100000);
    }

    function testApproveDepositsSuccess() public {
        uint128 approvedAssetAmount = 500;

        vm.expectCall(
            address(batchRequestManager),
            abi.encodeWithSelector(
                IBatchRequestManager.approveDeposits.selector,
                POOL_A,
                SC_1,
                asset1,
                uint32(1),
                approvedAssetAmount,
                d18(1, 1)
            )
        );

        vm.prank(manager);
        priceManager.approveDeposits(POOL_A, SC_1, asset1, approvedAssetAmount);

        (,, uint32 issueEpochsBehind, uint32 revokeEpochsBehind) = priceManager.networkMetrics(POOL_A, CENTRIFUGE_ID_1);
        assertEq(issueEpochsBehind, 1);
        assertEq(revokeEpochsBehind, 0);
    }

    function testIssueSharesSuccess() public {
        uint128 extraGasLimit = 100000;

        vm.prank(manager);
        priceManager.approveDeposits(POOL_A, SC_1, asset1, 500);

        vm.expectCall(
            address(batchRequestManager),
            abi.encodeWithSelector(
                IBatchRequestManager.issueShares.selector,
                POOL_A,
                SC_1,
                asset1,
                uint32(1),
                expectedNavPerShare,
                extraGasLimit
            )
        );

        vm.prank(manager);
        priceManager.issueShares(POOL_A, SC_1, asset1, extraGasLimit);

        (,, uint32 issueEpochsBehind, uint32 revokeEpochsBehind) = priceManager.networkMetrics(POOL_A, CENTRIFUGE_ID_1);
        assertEq(issueEpochsBehind, 0);
        assertEq(revokeEpochsBehind, 0);
    }

    function testIssueSharesWithoutPendingEpochs() public {
        vm.expectRevert(ISimplePriceManager.MismatchedEpochs.selector);
        vm.prank(manager);
        priceManager.issueShares(POOL_A, SC_1, asset1, 100000);
    }

    function testInvalidShareClass() public {
        vm.expectRevert(ISimplePriceManager.InvalidShareClass.selector);
        vm.prank(manager);
        priceManager.approveDeposits(POOL_A, SC_2, asset1, 1);

        vm.expectRevert(ISimplePriceManager.InvalidShareClass.selector);
        vm.prank(manager);
        priceManager.issueShares(POOL_A, SC_2, asset1, 1);

        vm.expectRevert(ISimplePriceManager.InvalidShareClass.selector);
        vm.prank(manager);
        priceManager.approveRedeems(POOL_A, SC_2, asset1, 1);

        vm.expectRevert(ISimplePriceManager.InvalidShareClass.selector);
        vm.prank(manager);
        priceManager.revokeShares(POOL_A, SC_2, asset1, 1);

        vm.expectRevert(ISimplePriceManager.InvalidShareClass.selector);
        vm.prank(manager);
        priceManager.approveDepositsAndIssueShares(POOL_A, SC_2, asset1, 1, 1);

        vm.expectRevert(ISimplePriceManager.InvalidShareClass.selector);
        vm.prank(manager);
        priceManager.approveRedeemsAndRevokeShares(POOL_A, SC_2, asset1, 1, 1);
    }
}
