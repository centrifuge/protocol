// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ERC20} from "../../../src/misc/ERC20.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../src/core/types/AssetId.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";
import {ISpokeHandler} from "../../../src/core/spoke/interfaces/ISpokeHandler.sol";
import {VaultDetails} from "../../../src/core/spoke/interfaces/ISpokeRegistry.sol";
import {VaultUpdateKind} from "../../../src/core/messaging/libraries/MessageLib.sol";

import {UpdateRestrictionMessageLib} from "../../../src/token/hooks/libraries/UpdateRestrictionMessageLib.sol";

import {AsyncVault} from "../../../src/vaults/AsyncVault.sol";

import {ShareToken} from "../../../src/token/ShareToken.sol";
import {CentrifugeIntegrationTest} from "../Integration.t.sol";
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

contract SpokeDeployVaultTest is CentrifugeIntegrationTest {
    using CastLib for *;

    PoolId POOL_A;
    ShareClassId SC_1;
    AssetId assetId;
    ERC20 asset;
    uint8 shareDecimals;
    string tokenName;
    string tokenSymbol;

    function setUp() public override {
        super.setUp();
        // address(this) is FM
        POOL_A = hubRegistry.poolId(LOCAL_CENTRIFUGE_ID, 1);
        vm.prank(address(opsGuardian.opsSafe()));
        opsGuardian.createPool(POOL_A, address(this), USD_ID);
    }

    function _setUpPoolAndShare() internal {
        // Share token decimals are determined by the pool currency (USD = 18 decimals in deployment)
        shareDecimals = 18;
        tokenName = "TestToken";
        tokenSymbol = "TT";

        SC_1 = shareClassManager.previewNextShareClassId(POOL_A);
        hub.addShareClass(POOL_A, tokenName, tokenSymbol, bytes32(bytes8(POOL_A.raw())));

        hub.notifyPool{value: 0}(POOL_A, LOCAL_CENTRIFUGE_ID, address(this));
        hub.notifyShareClass{value: 0}(
            POOL_A, SC_1, LOCAL_CENTRIFUGE_ID, bytes32(bytes20(address(shareTokenRegistrar))), "", 0, address(this)
        );
    }

    function _registerErc20Asset(uint8 decimals_) internal {
        asset = new ERC20(decimals_);
        asset.file("name", tokenName);
        asset.file("symbol", tokenSymbol);

        // Same-chain short-circuit: also registers the assetId on the hub
        assetId = spoke.registerAsset{value: 0}(LOCAL_CENTRIFUGE_ID, address(asset), 0, address(this));
    }

    function _assertVaultSetup(address vaultAddress, bool isLinked) internal view {
        address token_ = address(spokeRegistry.shareToken(POOL_A, SC_1));

        assertTrue(spokeRegistry.isPoolActive(POOL_A));

        VaultDetails memory vaultDetails = spokeRegistry.vaultDetails(address(vaultAddress));
        assertEq(assetId.raw(), vaultDetails.assetId.raw(), "vault assetId mismatch");
        assertEq(address(asset), vaultDetails.asset, "vault asset mismatch");
        assertEq(uint256(0), vaultDetails.tokenId, "vault tokenId mismatch");
        assertEq(isLinked, vaultDetails.isLinked, "vault isLinked mismatch");

        if (isLinked) {
            assertTrue(spokeRegistry.isLinked(address(vaultAddress)));

            AsyncVault vault = AsyncVault(vaultAddress);
            assertEq(vault.asset(), address(asset), "asset mismatch");
            assertEq(vault.poolId().raw(), POOL_A.raw(), "poolId mismatch");
            assertEq(vault.scId().raw(), SC_1.raw(), "scId mismatch");
            assertEq(address(vault.share()), address(token_), "share class token mismatch");

            assertEq(vault.wards(address(asyncRequestManager)), 1);
            assertEq(vault.wards(address(this)), 0);
            assertEq(asyncRequestManager.wards(vaultAddress), 1);
        } else {
            assertFalse(spokeRegistry.isLinked(address(vaultAddress)));
        }
    }

    function _assertShareSetup() internal view {
        ShareToken shareToken = ShareToken(address(spokeRegistry.shareToken(POOL_A, SC_1)));

        assertEq(shareToken.wards(address(shareTokenRegistrar)), 1);
        assertEq(shareToken.wards(address(root)), 1);
        assertEq(shareToken.wards(address(spoke)), 0);
        assertEq(shareToken.wards(address(this)), 0);

        assertEq(shareToken.name(), tokenName, "share class token name mismatch");
        assertEq(shareToken.symbol(), tokenSymbol, "share class token symbol mismatch");
        assertEq(shareToken.decimals(), shareDecimals, "share class token decimals mismatch");
    }

    /// forge-config: default.isolate = true
    function testDeployVaultWithoutLinkERC20(uint8 assetDecimals_) public {
        assetDecimals_ = uint8(bound(assetDecimals_, 0, 18));
        _setUpPoolAndShare();
        _registerErc20Asset(assetDecimals_);

        vm.prank(address(messageProcessor));
        spokeHandler.setRequestManager(POOL_A, asyncRequestManager);

        // Deploy and link via SpokeHandler (the only entry point for factory calls), then unlink to reach
        // the deployed-but-unlinked state (there is no standalone deploy-without-link operation).
        vm.recordLogs();
        vm.prank(address(messageProcessor));
        spokeHandler.updateVault(
            POOL_A, SC_1, assetId, address(asyncVaultFactory), VaultUpdateKind.DeployAndLink, bytes("")
        );
        address vaultAddr = _deployedVaultFromLogs();

        vm.prank(address(messageProcessor));
        spokeHandler.updateVault(POOL_A, SC_1, assetId, vaultAddr, VaultUpdateKind.Unlink, bytes(""));

        _assertVaultSetup(vaultAddr, false);
        _assertShareSetup();
    }

    /// forge-config: default.isolate = true
    function testDeployVaultWithLinkERC20(uint8 assetDecimals_) public {
        assetDecimals_ = uint8(bound(assetDecimals_, 0, 18));
        _setUpPoolAndShare();
        _registerErc20Asset(assetDecimals_);

        vm.prank(address(messageProcessor));
        spokeHandler.setRequestManager(POOL_A, asyncRequestManager);

        // Deploy and link via SpokeHandler (the only entry point for factory calls)
        vm.recordLogs();
        vm.prank(address(messageProcessor));
        spokeHandler.updateVault(
            POOL_A, SC_1, assetId, address(asyncVaultFactory), VaultUpdateKind.DeployAndLink, bytes("")
        );
        address vaultAddr = _deployedVaultFromLogs();

        _assertVaultSetup(vaultAddr, true);
        _assertShareSetup();
    }

    /// forge-config: default.isolate = true
    function testDeployVaultForwardsPayload() public {
        _setUpPoolAndShare();
        _registerErc20Asset(6);

        vm.prank(address(messageProcessor));
        spokeHandler.setRequestManager(POOL_A, asyncRequestManager);

        RecordingVaultFactory recordingFactory = new RecordingVaultFactory();

        // A >256-byte payload so the exact bytes (not just a small prefix) must be forwarded verbatim.
        bytes memory payload = new bytes(300);
        for (uint256 i; i < payload.length; i++) {
            payload[i] = bytes1(uint8(i));
        }

        vm.prank(address(messageProcessor));
        spokeHandler.updateVault(
            POOL_A, SC_1, assetId, address(recordingFactory), VaultUpdateKind.DeployAndLink, payload
        );

        assertEq(recordingFactory.lastPayload(), payload, "factory did not receive the forwarded payload");
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

/// @dev Minimal vault that satisfies the register/link checks for payload-forwarding tests.
contract RecordingVault {
    PoolId public immutable poolId;
    ShareClassId public immutable scId;

    constructor(PoolId poolId_, ShareClassId scId_) {
        poolId = poolId_;
        scId = scId_;
    }
}

/// @dev Factory that records the deployment payload the spoke forwards to `newVault`.
contract RecordingVaultFactory {
    bytes public lastPayload;

    function newVault(PoolId poolId, ShareClassId scId, address, uint256, address, bytes calldata payload)
        external
        returns (address)
    {
        lastPayload = payload;
        return address(new RecordingVault(poolId, scId));
    }
}
