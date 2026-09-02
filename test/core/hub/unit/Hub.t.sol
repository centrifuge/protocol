// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {d18, D18} from "../../../../src/misc/types/D18.sol";
import {IAuth} from "../../../../src/misc/interfaces/IAuth.sol";
import {CastLib} from "../../../../src/misc/libraries/CastLib.sol";

import {Hub} from "../../../../src/core/hub/Hub.sol";
import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../../src/core/types/AssetId.sol";
import {AccountId} from "../../../../src/core/types/AccountId.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {IHoldings} from "../../../../src/core/hub/interfaces/IHoldings.sol";
import {IValuation} from "../../../../src/core/hub/interfaces/IValuation.sol";
import {IAdapter} from "../../../../src/core/messaging/interfaces/IAdapter.sol";
import {IFeeAccrual} from "../../../../src/core/hub/interfaces/IFeeAccrual.sol";
import {IGateway} from "../../../../src/core/messaging/interfaces/IGateway.sol";
import {IHubRegistry} from "../../../../src/core/hub/interfaces/IHubRegistry.sol";
import {ISnapshotHook} from "../../../../src/core/hub/interfaces/ISnapshotHook.sol";
import {IMultiAdapter} from "../../../../src/core/messaging/interfaces/IMultiAdapter.sol";
import {IAccounting, JournalEntry} from "../../../../src/core/hub/interfaces/IAccounting.sol";
import {IShareClassManager} from "../../../../src/core/hub/interfaces/IShareClassManager.sol";
import {IHub, VaultUpdateKind, ManagerKind} from "../../../../src/core/hub/interfaces/IHub.sol";
import {IHubMessageSender} from "../../../../src/core/messaging/interfaces/IGatewaySenders.sol";

import "forge-std/Test.sol";

contract MockFeeAccrual is IFeeAccrual {
    mapping(PoolId => mapping(ShareClassId => uint32)) public calls;

    function accrue(PoolId poolId, ShareClassId scId) external {
        calls[poolId][scId]++;
    }

    function accrued(PoolId, ShareClassId) external pure returns (uint128 poolAmount) {
        return 0;
    }
}

contract TestCommon is Test {
    uint16 constant CHAIN_A = 23;
    uint16 constant CHAIN_B = 24;
    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_A = ShareClassId.wrap(bytes16(uint128(2)));
    AssetId constant ASSET_A = AssetId.wrap(3);
    address constant ADMIN = address(1);
    address immutable REFUND = makeAddr("REFUND");
    JournalEntry[] EMPTY;

    IHubRegistry immutable hubRegistry = IHubRegistry(makeAddr("HubRegistry"));
    IHoldings immutable holdings = IHoldings(makeAddr("Holdings"));
    IAccounting immutable accounting = IAccounting(makeAddr("Accounting"));
    IMultiAdapter immutable multiAdapter = IMultiAdapter(makeAddr("MultiAdapter"));
    IShareClassManager immutable scm = IShareClassManager(makeAddr("ShareClassManager"));
    IGateway immutable gateway = IGateway(makeAddr("Gateway"));
    IHubMessageSender immutable sender = IHubMessageSender(makeAddr("Sender"));
    MockFeeAccrual immutable feeAccrual = new MockFeeAccrual();

    Hub hub = new Hub(gateway, holdings, accounting, hubRegistry, multiAdapter, scm, address(this));

    function setUp() public {
        vm.mockCall(
            address(hubRegistry), abi.encodeWithSelector(hubRegistry.manager.selector, POOL_A, ADMIN), abi.encode(true)
        );

        // `_enforce` (supervisor work) reads the pool policy; default it to none so policy
        // enforcement is a no-op in these unit tests (they exercise the manager check + business logic).
        vm.mockCall(address(hubRegistry), abi.encodeWithSelector(hubRegistry.policy.selector), abi.encode(address(0)));

        vm.mockCall(address(accounting), abi.encodeWithSelector(accounting.unlock.selector, POOL_A), abi.encode(true));

        vm.mockCall(address(sender), abi.encodeWithSelector(sender.localCentrifugeId.selector), abi.encode(CHAIN_A));

        hub.file("feeAccrual", address(feeAccrual));
        hub.file("sender", address(sender));
    }

    function _holdingAccounts(AccountId asset, AccountId equity, AccountId gain, AccountId loss)
        internal
        pure
        returns (AccountId[4] memory accounts)
    {
        accounts[0] = asset;
        accounts[1] = equity;
        accounts[2] = gain;
        accounts[3] = loss;
    }
}

contract TestMainMethodsChecks is TestCommon {
    function testErrNotAuthorized() public {
        vm.startPrank(makeAddr("noGateway"));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        hub.file(bytes32(""), address(0));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        hub.createPool(PoolId.wrap(0), address(0), AssetId.wrap(0));

        vm.stopPrank();
    }

    function testErrNotManager() public {
        vm.startPrank(makeAddr("noPoolAdmin"));
        vm.mockCall(
            address(hubRegistry),
            abi.encodeWithSelector(hubRegistry.manager.selector, POOL_A, makeAddr("noPoolAdmin")),
            abi.encode(false)
        );

        vm.expectRevert(IHub.NotManager.selector);
        hub.notifyPool(POOL_A, 0, REFUND);

        vm.expectRevert(IHub.NotManager.selector);
        hub.notifyShareClass(POOL_A, ShareClassId.wrap(0), 0, bytes32(""), "", 0, REFUND);

        vm.expectRevert(IHub.NotManager.selector);
        hub.notifyShareMetadata(POOL_A, ShareClassId.wrap(0), 0, 0, REFUND);

        vm.expectRevert(IHub.NotManager.selector);
        hub.notifySharePrice(POOL_A, ShareClassId.wrap(0), 0, REFUND);

        vm.expectRevert(IHub.NotManager.selector);
        hub.notifyAssetPrice(POOL_A, ShareClassId.wrap(0), AssetId.wrap(0), REFUND);

        vm.expectRevert(IHub.NotManager.selector);
        hub.setPoolMetadata(POOL_A, bytes(""));

        vm.expectRevert(IHub.NotManager.selector);
        hub.updateCurrency(POOL_A, AssetId.wrap(0));

        vm.expectRevert(IHub.NotManager.selector);
        hub.setSnapshotHook(POOL_A, ISnapshotHook(address(0)));

        vm.expectRevert(IHub.NotManager.selector);
        hub.updateHubManager(POOL_A, address(0), false);

        vm.expectRevert(IHub.NotManager.selector);
        hub.updateManager(POOL_A, 0, ManagerKind.Spoke, bytes32(0), false, REFUND);

        vm.expectRevert(IHub.NotManager.selector);
        hub.addShareClass(POOL_A, "", "", bytes32(0));

        vm.expectRevert(IHub.NotManager.selector);
        hub.updateRestriction(POOL_A, ShareClassId.wrap(0), 0, bytes(""), 0, REFUND);

        vm.expectRevert(IHub.NotManager.selector);
        hub.updateVault(
            POOL_A,
            ShareClassId.wrap(0),
            AssetId.wrap(0),
            bytes32(0),
            VaultUpdateKind.DeployAndLink,
            bytes(""),
            0,
            REFUND
        );

        vm.expectRevert(IHub.NotManager.selector);
        hub.managerCall(POOL_A, 0, bytes32(0), bytes(""), 0, 0, REFUND);

        vm.expectRevert(IHub.NotManager.selector);
        hub.updateSharePrice(POOL_A, ShareClassId.wrap(0), D18.wrap(0), uint64(block.timestamp));

        vm.expectRevert(IHub.NotManager.selector);
        hub.initializeHolding(
            POOL_A,
            ShareClassId.wrap(0),
            AssetId.wrap(0),
            IValuation(address(0)),
            _holdingAccounts(AccountId.wrap(0), AccountId.wrap(0), AccountId.wrap(0), AccountId.wrap(0))
        );

        vm.expectRevert(IHub.NotManager.selector);
        hub.updateHoldingValue(POOL_A, ShareClassId.wrap(0), AssetId.wrap(0));

        vm.expectRevert(IHub.NotManager.selector);
        hub.updateHoldingValuation(POOL_A, ShareClassId.wrap(0), AssetId.wrap(0), IValuation(address(0)));

        vm.expectRevert(IHub.NotManager.selector);
        hub.setHoldingAccountId(POOL_A, ShareClassId.wrap(0), AssetId.wrap(0), 0, AccountId.wrap(0));

        vm.expectRevert(IHub.NotManager.selector);
        hub.createAccount(POOL_A, AccountId.wrap(0), false);

        vm.expectRevert(IHub.NotManager.selector);
        hub.setAccountMetadata(POOL_A, AccountId.wrap(0), bytes(""));

        vm.expectRevert(IHub.NotManager.selector);
        hub.updateJournal(POOL_A, EMPTY, EMPTY);

        vm.expectRevert(IHub.NotManager.selector);
        hub.setAdapters(POOL_A, 0, new IAdapter[](0), new bytes32[](0), 0, REFUND);

        vm.expectRevert(IHub.NotManager.selector);
        hub.updateManager(POOL_A, 0, ManagerKind.Adapter, bytes32(0), false, REFUND);

        vm.expectRevert(IHub.NotManager.selector);
        hub.initiateAuthorization(POOL_A, bytes(""));

        vm.expectRevert(IHub.NotManager.selector);
        hub.cancelAuthorization(POOL_A, bytes(""));

        vm.stopPrank();
    }
}

contract TestAuthorize is TestCommon {
    function testAuthorizeForwardsToHubRegistry() public {
        bytes memory data = abi.encode("some-authorization");
        vm.mockCall(
            address(hubRegistry),
            abi.encodeWithSelector(hubRegistry.initiateAuthorization.selector, POOL_A, ADMIN, data),
            ""
        );
        vm.expectCall(
            address(hubRegistry),
            abi.encodeWithSelector(hubRegistry.initiateAuthorization.selector, POOL_A, ADMIN, data)
        );

        vm.prank(ADMIN);
        hub.initiateAuthorization(POOL_A, data);
    }

    function testCancelAuthorizationForwardsToHubRegistry() public {
        bytes memory data = abi.encode("some-authorization");
        vm.mockCall(
            address(hubRegistry),
            abi.encodeWithSelector(hubRegistry.cancelAuthorization.selector, POOL_A, ADMIN, data),
            ""
        );
        vm.expectCall(
            address(hubRegistry), abi.encodeWithSelector(hubRegistry.cancelAuthorization.selector, POOL_A, ADMIN, data)
        );

        vm.prank(ADMIN);
        hub.cancelAuthorization(POOL_A, data);
    }
}

contract TestUpdateCurrency is TestCommon {
    function testUpdateCurrencyForwardsToHubRegistry() public {
        vm.mockCall(
            address(hubRegistry), abi.encodeWithSelector(hubRegistry.updateCurrency.selector, POOL_A, ASSET_A), ""
        );
        vm.expectCall(
            address(hubRegistry), abi.encodeWithSelector(hubRegistry.updateCurrency.selector, POOL_A, ASSET_A)
        );

        vm.prank(ADMIN);
        hub.updateCurrency(POOL_A, ASSET_A);
    }

    // The decimals-mismatch guard lives in HubRegistry; the Hub wrapper must not swallow its revert.
    function testUpdateCurrencyPropagatesMismatchRevert() public {
        vm.mockCallRevert(
            address(hubRegistry),
            abi.encodeWithSelector(hubRegistry.updateCurrency.selector, POOL_A, ASSET_A),
            abi.encodeWithSelector(IHubRegistry.CurrencyDecimalsMismatch.selector)
        );

        vm.prank(ADMIN);
        vm.expectRevert(IHubRegistry.CurrencyDecimalsMismatch.selector);
        hub.updateCurrency(POOL_A, ASSET_A);
    }
}

contract TestNotifyShareClass is TestCommon {
    function testErrShareClassNotFound() public {
        vm.mockCall(address(scm), abi.encodeWithSelector(scm.exists.selector, POOL_A, SC_A), abi.encode(false));

        vm.prank(ADMIN);
        vm.expectRevert(IShareClassManager.ShareClassNotFound.selector);
        hub.notifyShareClass(POOL_A, SC_A, 23, bytes32(""), "", 0, REFUND);
    }
}

contract TestInitializeHolding is TestCommon {
    function testErrAssetNotFound() public {
        vm.mockCall(address(scm), abi.encodeWithSelector(scm.exists.selector, POOL_A, SC_A), abi.encode(true));
        vm.mockCall(
            address(hubRegistry), abi.encodeWithSelector(hubRegistry.isRegistered.selector, ASSET_A), abi.encode(false)
        );

        vm.prank(ADMIN);
        vm.expectRevert(IHubRegistry.AssetNotFound.selector);
        hub.initializeHolding(
            POOL_A,
            SC_A,
            ASSET_A,
            IValuation(address(1)),
            _holdingAccounts(AccountId.wrap(1), AccountId.wrap(1), AccountId.wrap(1), AccountId.wrap(1))
        );
    }
}

contract TestUpdateSharePrice is TestCommon {
    function testUpdateSharePriceAccruesFees() public {
        vm.mockCall(
            address(scm),
            abi.encodeWithSelector(IShareClassManager.updateSharePrice.selector, POOL_A, SC_A, d18(1, 1)),
            abi.encode(false)
        );

        assertEq(feeAccrual.calls(POOL_A, SC_A), 0);

        vm.prank(ADMIN);
        hub.updateSharePrice(POOL_A, SC_A, d18(1, 1), uint64(block.timestamp));

        assertEq(feeAccrual.calls(POOL_A, SC_A), 1);
    }
}

contract TestNotifyAssetPrice is TestCommon {
    function testNotifyAssetPriceSendsIdentityPriceWhenNoHolding() public {
        vm.mockCall(
            address(holdings),
            abi.encodeWithSelector(IHoldings.isInitialized.selector, POOL_A, SC_A, ASSET_A),
            abi.encode(false)
        );

        vm.mockCall(
            address(sender),
            abi.encodeWithSelector(
                IHubMessageSender.sendNotifyPricePoolPerAsset.selector, POOL_A, SC_A, ASSET_A, d18(1, 1), REFUND
            ),
            abi.encode()
        );

        assertEq(feeAccrual.calls(POOL_A, SC_A), 0);

        vm.prank(ADMIN);
        hub.notifyAssetPrice(POOL_A, SC_A, ASSET_A, REFUND);

        assertEq(feeAccrual.calls(POOL_A, SC_A), 1);
    }

    function testNotifyAssetPriceSendsValuationPriceWhenHoldingInitialized() public {
        D18 valuationPrice = d18(4, 1);
        IValuation mockValuation = IValuation(makeAddr("mockValuation"));

        vm.mockCall(
            address(holdings),
            abi.encodeWithSelector(IHoldings.isInitialized.selector, POOL_A, SC_A, ASSET_A),
            abi.encode(true)
        );
        vm.mockCall(
            address(holdings),
            abi.encodeWithSelector(IHoldings.valuation.selector, POOL_A, SC_A, ASSET_A),
            abi.encode(mockValuation)
        );
        vm.mockCall(
            address(mockValuation),
            abi.encodeWithSelector(IValuation.getPrice.selector, POOL_A, SC_A, ASSET_A),
            abi.encode(valuationPrice)
        );
        vm.mockCall(
            address(sender),
            abi.encodeWithSelector(
                IHubMessageSender.sendNotifyPricePoolPerAsset.selector, POOL_A, SC_A, ASSET_A, valuationPrice, REFUND
            ),
            abi.encode()
        );

        vm.prank(ADMIN);
        hub.notifyAssetPrice(POOL_A, SC_A, ASSET_A, REFUND);

        assertEq(feeAccrual.calls(POOL_A, SC_A), 1);
    }
}

contract TestPricePoolPerAsset is TestCommon {
    function testPriceWithoutHoldings() public {
        vm.mockCall(
            address(holdings),
            abi.encodeWithSelector(IHoldings.isInitialized.selector, POOL_A, SC_A, ASSET_A),
            abi.encode(false)
        );

        assertEq(hub.pricePoolPerAsset(POOL_A, SC_A, ASSET_A).raw(), d18(1, 1).raw());
    }

    function testPriceWithHoldings() public {
        D18 valuationPrice = d18(4, 1);
        IValuation mockValuation = IValuation(makeAddr("mockValuation"));

        vm.mockCall(
            address(holdings),
            abi.encodeWithSelector(IHoldings.isInitialized.selector, POOL_A, SC_A, ASSET_A),
            abi.encode(true)
        );
        vm.mockCall(
            address(holdings),
            abi.encodeWithSelector(IHoldings.valuation.selector, POOL_A, SC_A, ASSET_A),
            abi.encode(mockValuation)
        );
        vm.mockCall(
            address(mockValuation),
            abi.encodeWithSelector(IValuation.getPrice.selector, POOL_A, SC_A, ASSET_A),
            abi.encode(valuationPrice)
        );

        assertEq(hub.pricePoolPerAsset(POOL_A, SC_A, ASSET_A).raw(), valuationPrice.raw());
    }
}

contract TestUpdateHoldingValuation is TestCommon {
    function testUpdateHoldingValuationSuccess() public {
        IValuation newValuation = IValuation(makeAddr("NewValuation"));

        vm.mockCall(
            address(holdings),
            abi.encodeWithSelector(IHoldings.updateValuation.selector, POOL_A, SC_A, ASSET_A, newValuation),
            abi.encode()
        );

        vm.prank(ADMIN);
        hub.updateHoldingValuation(POOL_A, SC_A, ASSET_A, newValuation);
    }

    function testUpdateHoldingValuationNotManager() public {
        IValuation newValuation = IValuation(makeAddr("NewValuation"));
        address notManager = makeAddr("notManager");

        vm.mockCall(
            address(hubRegistry),
            abi.encodeWithSelector(hubRegistry.manager.selector, POOL_A, notManager),
            abi.encode(false)
        );

        vm.prank(notManager);
        vm.expectRevert(IHub.NotManager.selector);
        hub.updateHoldingValuation(POOL_A, SC_A, ASSET_A, newValuation);
    }
}

contract TestSetHoldingAccountId is TestCommon {
    function testSetHoldingAccountIdSuccess() public {
        uint8 kind = 1;
        AccountId accountId = AccountId.wrap(42);

        vm.mockCall(
            address(accounting),
            abi.encodeWithSelector(IAccounting.exists.selector, POOL_A, accountId),
            abi.encode(true)
        );

        vm.mockCall(
            address(holdings),
            abi.encodeWithSelector(IHoldings.setAccountId.selector, POOL_A, SC_A, ASSET_A, kind, accountId),
            abi.encode()
        );

        vm.prank(ADMIN);
        hub.setHoldingAccountId(POOL_A, SC_A, ASSET_A, kind, accountId);
    }

    function testSetHoldingAccountIdNotManager() public {
        uint8 kind = 1;
        AccountId accountId = AccountId.wrap(42);
        address notManager = makeAddr("notManager");

        vm.mockCall(
            address(hubRegistry),
            abi.encodeWithSelector(hubRegistry.manager.selector, POOL_A, notManager),
            abi.encode(false)
        );

        vm.prank(notManager);
        vm.expectRevert(IHub.NotManager.selector);
        hub.setHoldingAccountId(POOL_A, SC_A, ASSET_A, kind, accountId);
    }

    function testSetHoldingAccountIdAccountDoesNotExist() public {
        uint8 kind = 1;
        AccountId accountId = AccountId.wrap(42);

        vm.mockCall(
            address(accounting),
            abi.encodeWithSelector(IAccounting.exists.selector, POOL_A, accountId),
            abi.encode(false)
        );

        vm.prank(ADMIN);
        vm.expectRevert(IAccounting.AccountDoesNotExist.selector);
        hub.setHoldingAccountId(POOL_A, SC_A, ASSET_A, kind, accountId);
    }
}

contract TestSetAccountMetadata is TestCommon {
    function testSetAccountMetadataSuccess() public {
        AccountId accountId = AccountId.wrap(42);
        bytes memory metadata = "test metadata";

        vm.mockCall(
            address(accounting),
            abi.encodeWithSelector(IAccounting.setAccountMetadata.selector, POOL_A, accountId, metadata),
            abi.encode()
        );

        vm.prank(ADMIN);
        hub.setAccountMetadata(POOL_A, accountId, metadata);
    }

    function testSetAccountMetadataNotManager() public {
        AccountId accountId = AccountId.wrap(42);
        bytes memory metadata = "test metadata";
        address notManager = makeAddr("notManager");

        vm.mockCall(
            address(hubRegistry),
            abi.encodeWithSelector(hubRegistry.manager.selector, POOL_A, notManager),
            abi.encode(false)
        );

        vm.prank(notManager);
        vm.expectRevert(IHub.NotManager.selector);
        hub.setAccountMetadata(POOL_A, accountId, metadata);
    }

    function testSetAccountMetadataEmptyBytes() public {
        AccountId accountId = AccountId.wrap(42);
        bytes memory metadata = "";

        vm.mockCall(
            address(accounting),
            abi.encodeWithSelector(IAccounting.setAccountMetadata.selector, POOL_A, accountId, metadata),
            abi.encode()
        );

        vm.prank(ADMIN);
        hub.setAccountMetadata(POOL_A, accountId, metadata);
    }
}

contract TestManagerCall is TestCommon {
    using CastLib for address;

    uint128 constant EXTRA_GAS = 42;
    uint256 constant VALUE = 7;

    /// @dev `managerCall` is the hub direction: pool-scoped, opaque payload, no probe. It forwards to
    ///      `sendManagerCallFromHub` and emits the scId-less `ManagerCall`. On the local branch (`CHAIN_A` is the
    ///      mocked `localCentrifugeId`) the whole `msg.value` funds the call, so `value` must equal it.
    function testManagerCallHubRoute() public {
        address target = makeAddr("hubTarget");
        bytes memory payload = hex"1234";

        vm.mockCall(
            address(sender),
            abi.encodeWithSelector(
                IHubMessageSender.sendManagerCallFromHub.selector,
                CHAIN_A,
                POOL_A,
                target,
                payload,
                EXTRA_GAS,
                VALUE,
                REFUND
            ),
            abi.encode()
        );

        vm.expectEmit();
        emit IHub.ManagerCall(CHAIN_A, POOL_A, target.toBytes32(), payload);

        vm.deal(ADMIN, VALUE);
        vm.prank(ADMIN);
        hub.managerCall{value: VALUE}(POOL_A, CHAIN_A, target.toBytes32(), payload, EXTRA_GAS, VALUE, REFUND);
    }

    /// @dev Local branch: `value` must equal `msg.value` (here `msg.value` is 0 but `value` is not).
    function testManagerCallLocalValueMismatchReverts() public {
        vm.expectRevert(IHub.ManagerCallUnexpectedValue.selector);
        vm.prank(ADMIN);
        hub.managerCall(POOL_A, CHAIN_A, makeAddr("t").toBytes32(), hex"1234", EXTRA_GAS, VALUE, REFUND);
    }

    /// @dev Remote branch (`CHAIN_B` != `localCentrifugeId`): `value` must be 0.
    function testManagerCallRemoteNonZeroValueReverts() public {
        vm.expectRevert(IHub.ManagerCallUnexpectedValue.selector);
        vm.prank(ADMIN);
        hub.managerCall(POOL_A, CHAIN_B, makeAddr("t").toBytes32(), hex"1234", EXTRA_GAS, VALUE, REFUND);
    }

    /// @dev Remote branch (`CHAIN_B` != `localCentrifugeId`) success route: `value` must be 0 and the payload
    ///      is forwarded opaquely.
    function testManagerCallRemoteRoute() public {
        address target = makeAddr("remoteSpokeTarget");
        bytes memory payload = hex"1234";

        vm.mockCall(
            address(sender),
            abi.encodeWithSelector(
                IHubMessageSender.sendManagerCallFromHub.selector,
                CHAIN_B,
                POOL_A,
                target,
                payload,
                EXTRA_GAS,
                uint256(0),
                REFUND
            ),
            abi.encode()
        );

        vm.expectEmit();
        emit IHub.ManagerCall(CHAIN_B, POOL_A, target.toBytes32(), payload);

        vm.prank(ADMIN);
        hub.managerCall(POOL_A, CHAIN_B, target.toBytes32(), payload, EXTRA_GAS, 0, REFUND);
    }

    function testManagerCallOnlyManager() public {
        address notManager = makeAddr("notManager");
        vm.mockCall(
            address(hubRegistry),
            abi.encodeWithSelector(hubRegistry.manager.selector, POOL_A, notManager),
            abi.encode(false)
        );

        vm.expectRevert(IHub.NotManager.selector);
        vm.prank(notManager);
        hub.managerCall(POOL_A, CHAIN_A, makeAddr("t").toBytes32(), hex"1234", 0, 0, REFUND);
    }
}

contract TestHubFile is TestCommon {
    function testFileGateway() public {
        IGateway newGateway = IGateway(makeAddr("NewGateway"));

        vm.expectEmit(true, true, true, true);
        emit IHub.File("gateway", address(newGateway));

        hub.file("gateway", address(newGateway));
        assertEq(address(hub.gateway()), address(newGateway));
    }

    function testFileFeeAccrual() public {
        IFeeAccrual newFeeAccrual = IFeeAccrual(makeAddr("NewFeeAccrual"));

        vm.expectEmit(true, true, true, true);
        emit IHub.File("feeAccrual", address(newFeeAccrual));

        hub.file("feeAccrual", address(newFeeAccrual));
        assertEq(address(hub.feeAccrual()), address(newFeeAccrual));
    }

    function testFileSender() public {
        IHubMessageSender newSender = IHubMessageSender(makeAddr("NewSender"));

        vm.expectEmit(true, true, true, true);
        emit IHub.File("sender", address(newSender));

        hub.file("sender", address(newSender));
        assertEq(address(hub.sender()), address(newSender));
    }

    function testFileMultiAdapter() public {
        IMultiAdapter newMultiAdapter = IMultiAdapter(makeAddr("NewMultiAdapter"));

        vm.expectEmit(true, true, true, true);
        emit IHub.File("multiAdapter", address(newMultiAdapter));

        hub.file("multiAdapter", address(newMultiAdapter));
        assertEq(address(hub.multiAdapter()), address(newMultiAdapter));
    }

    function testFileUnrecognizedParam() public {
        vm.expectRevert(IHub.FileUnrecognizedParam.selector);
        hub.file("unknown", address(0));
    }

    function testFileNotAuthorized() public {
        vm.prank(makeAddr("notAuthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        hub.file("gateway", address(0));
    }
}
