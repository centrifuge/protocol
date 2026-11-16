// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IsContract} from "./Vault.t.sol";

import {IAuth} from "../../src/misc/interfaces/IAuth.sol";

import {RequestId} from "../../src/core/types/RequestId.sol";
import {ISpoke} from "../../src/core/spoke/interfaces/ISpoke.sol";
import {PoolId, newPoolId} from "../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../src/core/types/AssetId.sol";
import {IGateway} from "../../src/core/messaging/interfaces/IGateway.sol";
import {IRequestRouter} from "../../src/core/spoke/interfaces/IRequestRouter.sol";
import {IBatchedMulticall} from "../../src/core/utils/interfaces/IBatchedMulticall.sol";
import {VaultDetails, ISpokeRegistry} from "../../src/core/spoke/interfaces/ISpokeRegistry.sol";

import {VaultRequestRouter} from "../../src/vaults/messaging/VaultRequestRouter.sol";
import {RequestMessageLib} from "../../src/vaults/messaging/libraries/RequestMessageLib.sol";
import {IVaultRequestRouter} from "../../src/vaults/messaging/interfaces/IVaultRequestRouter.sol";
import {RequestCallbackMessageLib} from "../../src/vaults/messaging/libraries/RequestCallbackMessageLib.sol";
import {
    IVaultDepositCallbacks,
    IVaultRedeemCallbacks
} from "../../src/vaults/messaging/interfaces/IVaultRequestManager.sol";

import {IVault} from "../../src/vaults/interfaces/IVault.sol";
import {VaultRequestIdLib} from "../../src/vaults/libraries/VaultRequestIdLib.sol";

import "forge-std/Test.sol";

import {ISubsidyManager} from "../../src/utils/interfaces/ISubsidyManager.sol";

/// @dev The router is the only vaults contract that speaks the request wire, and it is a per-network
///      singleton registered as *every* pool's request manager — so what matters here is that it
///      routes each callback to the vault named by the request id, and that it refuses to apply a
///      callback for a position that is not that vault's own.
contract VaultRequestRouterTest is Test {
    using RequestCallbackMessageLib for *;

    uint16 constant LOCAL_CENTRIFUGE_ID = 1;
    uint16 constant REMOTE_CENTRIFUGE_ID = 2;

    PoolId immutable POOL = newPoolId(LOCAL_CENTRIFUGE_ID, 1);
    ShareClassId constant SC = ShareClassId.wrap(bytes16("sc1"));
    AssetId immutable LOCAL_ASSET = newAssetId(LOCAL_CENTRIFUGE_ID, 1);
    AssetId immutable REMOTE_ASSET = newAssetId(REMOTE_CENTRIFUGE_ID, 1);

    address spoke = address(new IsContract());
    address spokeRegistry = address(new IsContract());
    address subsidyManager = address(new IsContract());
    address gateway = address(new IsContract());
    address vault = address(new IsContract());
    address otherVault = address(new IsContract());
    address handler = makeAddr("spokeHandler");
    address refundAddr = makeAddr("refund");
    address envoy = makeAddr("envoy");

    VaultRequestRouter router;

    function setUp() public {
        router = new VaultRequestRouter(
            ISpoke(spoke), ISpokeRegistry(spokeRegistry), ISubsidyManager(subsidyManager), envoy, address(this)
        );
        router.rely(handler);
        router.deny(address(this));

        _details(vault, POOL, SC, LOCAL_ASSET, true);
        vm.mockCall(spoke, abi.encodeWithSelector(IBatchedMulticall.gateway.selector), abi.encode(gateway));
        vm.mockCall(gateway, abi.encodeWithSelector(IGateway.isBatching.selector), abi.encode(false));
        vm.mockCall(spoke, abi.encodeWithSelector(IRequestRouter.request.selector), "");
        vm.mockCall(
            subsidyManager, abi.encodeWithSelector(ISubsidyManager.withdrawAll.selector), abi.encode(refundAddr, 42)
        );
        // The mocked withdrawAll reports a payment without moving the ether it names, so the router is
        // funded here for the amount it then forwards to the spoke.
        vm.deal(address(router), 42);

        // Every typed vault callback is mocked; the tests assert which one is reached.
        bytes4[7] memory callbacks = [
            IVaultDepositCallbacks.approveDeposits.selector,
            IVaultDepositCallbacks.issueShares.selector,
            IVaultDepositCallbacks.fulfillDepositRequest.selector,
            IVaultDepositCallbacks.cancelDeposit.selector,
            IVaultRedeemCallbacks.revokeShares.selector,
            IVaultRedeemCallbacks.fulfillRedeemRequest.selector,
            IVaultRedeemCallbacks.cancelRedeem.selector
        ];
        for (uint256 i; i < callbacks.length; i++) {
            vm.mockCall(vault, abi.encodeWithSelector(callbacks[i]), "");
        }
    }

    function _details(address vault_, PoolId poolId, ShareClassId scId, AssetId assetId, bool isLinked) internal {
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.vaultDetails.selector, vault_),
            abi.encode(VaultDetails(poolId, scId, assetId, address(0), uint256(0), isLinked))
        );
        vm.mockCall(vault_, abi.encodeWithSelector(IVault.poolId.selector), abi.encode(poolId));
        vm.mockCall(vault_, abi.encodeWithSelector(IVault.scId.selector), abi.encode(scId));
    }

    function _requestId(address vault_, uint96 localId) internal pure returns (RequestId) {
        return VaultRequestIdLib.from(vault_, localId);
    }

    function _callback(bytes memory payload) internal {
        vm.prank(handler);
        router.callback(POOL, SC, LOCAL_ASSET, payload);
    }

    //----------------------------------------------------------------------------------------------
    // Inbound: hub callbacks
    //----------------------------------------------------------------------------------------------

    function testCallbackIsWardGated() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        router.callback(
            POOL, SC, LOCAL_ASSET, RequestCallbackMessageLib.SettledDeposit(_requestId(vault, 1), 1, 1).serialize()
        );
    }

    /// @dev One `SettledDeposit` or `SettledRedeem` message is applied as its legs, in order
    function testASettledMessageIsAppliedAsItsLegs(uint96 localId, uint128 a, uint128 b) public {
        RequestId id = _requestId(vault, localId);

        vm.expectCall(vault, abi.encodeCall(IVaultDepositCallbacks.approveDeposits, (localId, a)));
        vm.expectCall(vault, abi.encodeCall(IVaultDepositCallbacks.issueShares, (localId, b)));
        vm.expectCall(vault, abi.encodeCall(IVaultDepositCallbacks.fulfillDepositRequest, (localId, a, b)));
        _callback(RequestCallbackMessageLib.SettledDeposit(id, a, b).serialize());

        vm.expectCall(vault, abi.encodeCall(IVaultRedeemCallbacks.revokeShares, (localId, a, b)));
        vm.expectCall(vault, abi.encodeCall(IVaultRedeemCallbacks.fulfillRedeemRequest, (localId, a, b)));
        _callback(RequestCallbackMessageLib.SettledRedeem(id, a, b).serialize());
    }

    function testACancellationReachesItsTypedHandler(uint96 localId, uint128 a, uint128 b) public {
        RequestId id = _requestId(vault, localId);

        vm.expectCall(vault, abi.encodeCall(IVaultDepositCallbacks.cancelDeposit, (localId, a, b)));
        _callback(RequestCallbackMessageLib.CancelledDeposit(id, a, b).serialize());

        vm.expectCall(vault, abi.encodeCall(IVaultRedeemCallbacks.cancelRedeem, (localId, a, b)));
        _callback(RequestCallbackMessageLib.CancelledRedeem(id, a, b).serialize());
    }

    /// @dev The router is registered as every pool's request manager, so the vault's own caller check
    ///      resolves to this same address for every pool and says nothing about which pool authorised
    ///      the settlement. Without the registry check, a pool running its own hub-side manager could
    ///      send a callback naming another pool's vault and have it applied there.
    function testCallbackRejectsAVaultFromAnotherPool() public {
        _details(vault, newPoolId(LOCAL_CENTRIFUGE_ID, 99), SC, LOCAL_ASSET, true);

        vm.prank(handler);
        vm.expectRevert(IVaultRequestRouter.WrongPool.selector);
        router.callback(
            POOL, SC, LOCAL_ASSET, RequestCallbackMessageLib.SettledDeposit(_requestId(vault, 1), 1, 1).serialize()
        );
    }

    /// @dev The registry records whatever a `DeployAndLink` factory returned, so a pool can register a vault another
    ///      pool built. The vault's own pool differs from the record, and the router refuses it.
    function testCallbackRejectsAVaultBuiltForAnotherPool() public {
        vm.mockCall(
            vault, abi.encodeWithSelector(IVault.poolId.selector), abi.encode(newPoolId(LOCAL_CENTRIFUGE_ID, 99))
        );

        vm.prank(handler);
        vm.expectRevert(IVaultRequestRouter.WrongPool.selector);
        router.callback(
            POOL, SC, LOCAL_ASSET, RequestCallbackMessageLib.SettledDeposit(_requestId(vault, 1), 1, 1).serialize()
        );
    }

    function testAVaultBuiltForAnotherPoolCannotSend() public {
        vm.mockCall(
            vault, abi.encodeWithSelector(IVault.poolId.selector), abi.encode(newPoolId(LOCAL_CENTRIFUGE_ID, 99))
        );

        vm.prank(vault);
        vm.expectRevert(IVaultRequestRouter.WrongPool.selector);
        router.sendDepositRequest(1, 1e6);
    }

    function testCallbackRejectsAMismatchedShareClass() public {
        _details(vault, POOL, ShareClassId.wrap(bytes16("other")), LOCAL_ASSET, true);

        vm.prank(handler);
        vm.expectRevert(IVaultRequestRouter.WrongLane.selector);
        router.callback(
            POOL, SC, LOCAL_ASSET, RequestCallbackMessageLib.SettledDeposit(_requestId(vault, 1), 1, 1).serialize()
        );
    }

    function testCallbackRejectsAMismatchedAsset() public {
        _details(vault, POOL, SC, REMOTE_ASSET, true);

        vm.prank(handler);
        vm.expectRevert(IVaultRequestRouter.WrongLane.selector);
        router.callback(
            POOL, SC, LOCAL_ASSET, RequestCallbackMessageLib.SettledDeposit(_requestId(vault, 1), 1, 1).serialize()
        );
    }

    function testCallbackRejectsAnUnlinkedVault() public {
        _details(vault, POOL, SC, LOCAL_ASSET, false);

        vm.prank(handler);
        vm.expectRevert(IVaultRequestRouter.NotLinked.selector);
        router.callback(
            POOL, SC, LOCAL_ASSET, RequestCallbackMessageLib.SettledDeposit(_requestId(vault, 1), 1, 1).serialize()
        );
    }

    function testCallbackRejectsAnUnknownType() public {
        bytes memory payload = abi.encodePacked(uint8(0), _requestId(vault, 1).raw(), uint128(1));

        vm.prank(handler);
        vm.expectRevert(RequestCallbackMessageLib.UnknownRequestCallbackType.selector);
        router.callback(POOL, SC, LOCAL_ASSET, payload);
    }

    //----------------------------------------------------------------------------------------------
    // Outbound: vault requests
    //----------------------------------------------------------------------------------------------

    function testOnlyALinkedVaultMaySend() public {
        _details(otherVault, POOL, SC, LOCAL_ASSET, false);

        vm.prank(otherVault);
        vm.expectRevert(IVaultRequestRouter.NotLinked.selector);
        router.sendDepositRequest(1, 1e6);
    }

    /// @dev The id is derived from the caller, so a vault structurally cannot emit a sibling's request
    ///      id — which is what makes the inbound routing above safe without a registry of ids.
    function testRequestCarriesTheCallersOwnId(uint96 localId, uint128 amount) public {
        bytes memory expected =
            RequestMessageLib.serialize(RequestMessageLib.DepositRequest(_requestId(vault, localId), amount));

        vm.expectCall(
            spoke, abi.encodeCall(IRequestRouter.request, (POOL, SC, LOCAL_ASSET, expected, 0, true, address(0)))
        );
        vm.prank(vault);
        router.sendDepositRequest(localId, amount);
    }

    function testRedeemRequestSerializesTheRedeemSide(uint96 localId, uint128 amount) public {
        bytes memory expected =
            RequestMessageLib.serialize(RequestMessageLib.RedeemRequest(_requestId(vault, localId), amount));

        vm.expectCall(
            spoke, abi.encodeCall(IRequestRouter.request, (POOL, SC, LOCAL_ASSET, expected, 0, true, address(0)))
        );
        vm.prank(vault);
        router.sendRedeemRequest(localId, amount);
    }

    /// @dev A same-chain pool needs no cross-chain message, so no subsidy is drawn.
    function testSameChainRequestDrawsNoSubsidy() public {
        vm.expectCall(subsidyManager, abi.encodeWithSelector(ISubsidyManager.withdrawAll.selector), 0);

        vm.prank(vault);
        router.sendDepositRequest(1, 1e6);
    }

    function testCrossChainRequestWithdrawsTheSubsidy() public {
        _details(vault, POOL, SC, REMOTE_ASSET, true);

        vm.expectCall(subsidyManager, abi.encodeCall(ISubsidyManager.withdrawAll, (POOL, address(router))));
        vm.prank(vault);
        router.sendDepositRequest(1, 1e6);
    }

    /// @dev Inside a batch the gateway settles payment once for the whole batch, so drawing a
    ///      per-request subsidy would be paying twice.
    function testCrossChainRequestInsideABatchDrawsNoSubsidy() public {
        _details(vault, POOL, SC, REMOTE_ASSET, true);
        vm.mockCall(gateway, abi.encodeWithSelector(IGateway.isBatching.selector), abi.encode(true));

        vm.expectCall(subsidyManager, abi.encodeWithSelector(ISubsidyManager.withdrawAll.selector), 0);
        vm.prank(vault);
        router.sendDepositRequest(1, 1e6);
    }

    /// @dev A pool whose hub request manager runs more than the benchmark can fund it: the pool's
    ///      extra gas rides every request its vaults send.
    function testRequestCarriesThePoolsExtraGas() public {
        vm.expectEmit(address(router));
        emit IVaultRequestRouter.SetExtraGasLimit(POOL, 150_000);
        vm.prank(envoy);
        router.fromHub(POOL, abi.encode(uint128(150_000)));
        assertEq(router.extraGasLimit(POOL), 150_000);

        RequestId id = _requestId(vault, 1);
        bytes memory expected = RequestMessageLib.serialize(RequestMessageLib.DepositRequest(id, 1e6));
        vm.expectCall(
            spoke, abi.encodeCall(IRequestRouter.request, (POOL, SC, LOCAL_ASSET, expected, 150_000, true, address(0)))
        );
        vm.prank(vault);
        router.sendDepositRequest(1, 1e6);
    }

    /// @dev Set through the Envoy like every other piece of VDK configuration, so the pool's hub policy
    ///      classifies it: no spoke manager can set it directly.
    function testExtraGasIsSetOnlyThroughTheEnvoy() public {
        address poolManager = makeAddr("poolManager");
        vm.mockCall(spokeRegistry, abi.encodeCall(ISpokeRegistry.manager, (POOL, poolManager)), abi.encode(true));

        vm.prank(poolManager);
        vm.expectRevert(IVaultRequestRouter.NotEnvoy.selector);
        router.fromHub(POOL, abi.encode(uint128(1)));
    }

    function testExtraGasRejectsValue() public {
        vm.deal(envoy, 1);
        vm.prank(envoy);
        vm.expectRevert(IVaultRequestRouter.UnexpectedValue.selector);
        router.fromHub{value: 1}(POOL, abi.encode(uint128(1)));
    }

    /// @dev Indexers key the setting by pool: each change is emitted under its own pool, a large value and a
    ///      reset to zero included.
    function testExtraGasEmitsPerPoolOnEveryChange() public {
        PoolId other = newPoolId(LOCAL_CENTRIFUGE_ID, 2);
        uint128 big = 5_000_000;

        vm.startPrank(envoy);
        vm.expectEmit(true, false, false, true, address(router));
        emit IVaultRequestRouter.SetExtraGasLimit(POOL, big);
        router.fromHub(POOL, abi.encode(big));

        vm.expectEmit(true, false, false, true, address(router));
        emit IVaultRequestRouter.SetExtraGasLimit(other, 1);
        router.fromHub(other, abi.encode(uint128(1)));

        vm.expectEmit(true, false, false, true, address(router));
        emit IVaultRequestRouter.SetExtraGasLimit(POOL, 0);
        router.fromHub(POOL, abi.encode(uint128(0)));
        vm.stopPrank();

        assertEq(router.extraGasLimit(POOL), 0);
        assertEq(router.extraGasLimit(other), 1);
    }
}
