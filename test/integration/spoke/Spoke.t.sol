// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ERC20} from "../../../src/misc/ERC20.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../src/core/types/AssetId.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";
import {IGateway} from "../../../src/core/messaging/interfaces/IGateway.sol";
import {MessageLib} from "../../../src/core/messaging/libraries/MessageLib.sol";
import {ISpokeHandler} from "../../../src/core/spoke/interfaces/ISpokeHandler.sol";

import {UpdateRestrictionMessageLib} from "../../../src/token/hooks/libraries/UpdateRestrictionMessageLib.sol";

import {USD_ID} from "../../../src/deployment/Currencies.sol";
import {CentrifugeIntegrationTest} from "../Integration.t.sol";
import {IntegrationConstants} from "../utils/IntegrationConstants.sol";
import {IShareToken} from "../../../src/token/interfaces/IShareToken.sol";
import {IShareTokenRegistrar} from "../../../src/token/interfaces/IShareTokenRegistrar.sol";

contract SpokeRestrictionTest is CentrifugeIntegrationTest {
    using CastLib for *;
    using UpdateRestrictionMessageLib for *;

    PoolId POOL_A;
    ShareClassId SC_1;

    address immutable randomUser = makeAddr("randomUser");
    address immutable secondUser = makeAddr("secondUser");

    function setUp() public override {
        super.setUp();
        // address(this) is FM
        POOL_A = hubRegistry.poolId(LOCAL_CENTRIFUGE_ID, 1);
        vm.prank(address(opsGuardian.opsSafe()));
        opsGuardian.createPool(POOL_A, address(this), USD_ID);

        SC_1 = shareClassManager.previewNextShareClassId(POOL_A);
        hub.addShareClass(POOL_A, "TestShare", "TST", bytes32(bytes8(POOL_A.raw())));

        // Push pool and share class to spoke
        hub.notifyPool{value: 0}(POOL_A, LOCAL_CENTRIFUGE_ID, address(this));
        hub.notifyShareClass{value: 0}(
            POOL_A, SC_1, LOCAL_CENTRIFUGE_ID, bytes32(bytes20(address(shareTokenRegistrar))), "", 0, address(this)
        );

        // Token deploys hookless (v3.1+); set the restriction hook via the registrar's Envoy path
        hub.managerCall{value: 0}(
            POOL_A,
            LOCAL_CENTRIFUGE_ID,
            address(shareTokenRegistrar).toBytes32(),
            abi.encode(uint8(IShareTokenRegistrar.RegistrarCall.SetHook), SC_1, address(fullRestrictionsHook)),
            0,
            0,
            address(this)
        );
    }

    /// forge-config: default.isolate = true
    function testFreezeAndUnfreeze() public {
        IShareToken shareToken = IShareToken(address(spokeRegistry.shareToken(POOL_A, SC_1)));
        uint64 validUntil = uint64(block.timestamp + 7 days);

        hub.updateRestriction{value: 0}(
            POOL_A,
            SC_1,
            LOCAL_CENTRIFUGE_ID,
            UpdateRestrictionMessageLib.UpdateRestrictionMember(randomUser.toBytes32(), validUntil).serialize(),
            0,
            address(this)
        );
        hub.updateRestriction{value: 0}(
            POOL_A,
            SC_1,
            LOCAL_CENTRIFUGE_ID,
            UpdateRestrictionMessageLib.UpdateRestrictionMember(secondUser.toBytes32(), validUntil).serialize(),
            0,
            address(this)
        );
        assertTrue(shareToken.checkTransferRestriction(randomUser, secondUser, 0));

        hub.updateRestriction{value: 0}(
            POOL_A,
            SC_1,
            LOCAL_CENTRIFUGE_ID,
            UpdateRestrictionMessageLib.UpdateRestrictionFreeze(randomUser.toBytes32()).serialize(),
            0,
            address(this)
        );
        assertFalse(shareToken.checkTransferRestriction(randomUser, secondUser, 0));

        hub.updateRestriction{value: 0}(
            POOL_A,
            SC_1,
            LOCAL_CENTRIFUGE_ID,
            UpdateRestrictionMessageLib.UpdateRestrictionUnfreeze(randomUser.toBytes32()).serialize(),
            0,
            address(this)
        );
        assertTrue(shareToken.checkTransferRestriction(randomUser, secondUser, 0));

        hub.updateRestriction{value: 0}(
            POOL_A,
            SC_1,
            LOCAL_CENTRIFUGE_ID,
            UpdateRestrictionMessageLib.UpdateRestrictionFreeze(secondUser.toBytes32()).serialize(),
            0,
            address(this)
        );
        assertFalse(shareToken.checkTransferRestriction(randomUser, secondUser, 0));

        hub.updateRestriction{value: 0}(
            POOL_A,
            SC_1,
            LOCAL_CENTRIFUGE_ID,
            UpdateRestrictionMessageLib.UpdateRestrictionUnfreeze(secondUser.toBytes32()).serialize(),
            0,
            address(this)
        );
        assertTrue(shareToken.checkTransferRestriction(randomUser, secondUser, 0));
    }
}

contract SpokeRegisterAssetTest is CentrifugeIntegrationTest {
    using MessageLib for *;

    AssetId assetId;
    ERC20 asset;

    function _registerErc20Asset(uint8 decimals_) internal {
        asset = new ERC20(decimals_);

        // Same-chain short-circuit: also registers the assetId on the hub
        assetId = spoke.registerAsset{value: 0}(LOCAL_CENTRIFUGE_ID, address(asset), 0, address(this));
    }

    function testRegisterAssetRefreshesHubDecimals() public {
        // Registration is permissionless, so a token whose issuer has not set its decimals yet can be
        // bound to an asset id reporting 0 decimals.
        _registerErc20Asset(0);
        assertEq(hubRegistry.decimals(assetId), 0, "hub decimals before refresh");

        // Registering it again once the token is initialized corrects the hub entry, keeping the asset id.
        vm.mockCall(address(asset), abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        AssetId refreshed = spoke.registerAsset{value: 0}(LOCAL_CENTRIFUGE_ID, address(asset), 0, address(this));

        assertEq(refreshed.raw(), assetId.raw(), "asset id must be stable across re-registration");
        assertEq(hubRegistry.decimals(assetId), 6, "hub decimals after refresh");
    }

    function testRegisterAssetRefreshRejectedFromAnotherChain() public {
        _registerErc20Asset(6);

        // Registration being an upsert makes a forged refresh worth attempting. An asset id names the chain
        // that minted it and the gateway holds every message to that chain, so another chain's lane cannot
        // rewrite this asset's decimals.
        bytes memory message = MessageLib.RegisterAsset({assetId: assetId.raw(), decimals: 18}).serialize();

        vm.prank(address(multiAdapter));
        vm.expectRevert(IGateway.SourceMismatch.selector);
        gateway.handle(IntegrationConstants.CENTRIFUGE_ID_A, message);

        assertEq(hubRegistry.decimals(assetId), 6, "decimals unchanged");
    }
}

/// @dev Share tokens are deployed from a registrar shared by every pool, so the spoke re-checks that a
///      salt carries the pool id it arrived under. Without it, a pool forging its own inbound message
///      could deploy at another pool's deterministic token address and lock it out of that chain.
contract SpokeShareClassSaltTest is CentrifugeIntegrationTest {
    using CastLib for *;

    PoolId victim;
    PoolId attacker;

    function setUp() public override {
        super.setUp();
        victim = hubRegistry.poolId(LOCAL_CENTRIFUGE_ID, 1);
        attacker = hubRegistry.poolId(LOCAL_CENTRIFUGE_ID, 2);

        vm.startPrank(address(opsGuardian.opsSafe()));
        opsGuardian.createPool(victim, address(this), USD_ID);
        opsGuardian.createPool(attacker, address(this), USD_ID);
        vm.stopPrank();

        hub.notifyPool{value: 0}(victim, LOCAL_CENTRIFUGE_ID, address(this));
        hub.notifyPool{value: 0}(attacker, LOCAL_CENTRIFUGE_ID, address(this));
    }

    function testCannotDeployAtAnotherPoolsAddress() public {
        bytes32 victimSalt = bytes32(bytes8(victim.raw()));
        ShareClassId victimScId = shareClassManager.previewNextShareClassId(victim);
        hub.addShareClass(victim, "Victim Share", "VIC", victimSalt);

        // The registrar's address depends only on decimals and salt, so a deploy with the victim's salt
        // would land on the victim's address regardless of which pool it arrives under
        address victimToken = shareTokenRegistrar.previewTokenAddress("Victim Share", "VIC", 18, victimSalt, "");
        assertEq(victimToken, shareTokenRegistrar.previewTokenAddress("Attacker Share", "ATK", 18, victimSalt, ""));
        assertEq(victimToken.code.length, 0, "not yet deployed");

        // The attacker's own inbound path, carrying the victim's salt
        vm.prank(address(messageProcessor));
        vm.expectRevert(ISpokeHandler.InvalidSalt.selector);
        spokeHandler.addShareClass(
            attacker,
            ShareClassId.wrap(bytes16(uint128(1))),
            "Victim Share",
            "VIC",
            18,
            victimSalt,
            shareTokenRegistrar,
            ""
        );

        // The victim still reaches its own deterministic address
        hub.notifyShareClass{value: 0}(
            victim, victimScId, LOCAL_CENTRIFUGE_ID, address(shareTokenRegistrar).toBytes32(), "", 0, address(this)
        );
        assertEq(address(spokeRegistry.shareToken(victim, victimScId)), victimToken);
    }
}
