// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {EndToEndFlows} from "./EndToEnd.t.sol";
import {EvilVaultFactory} from "./recon-end-to-end/mocks/EvilVaultFactory.sol";

import {IAuth} from "../../src/misc/interfaces/IAuth.sol";
import {CastLib} from "../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {ISpokeRegistry} from "../../src/core/spoke/interfaces/ISpokeRegistry.sol";
import {MessageLib, VaultUpdateKind} from "../../src/core/messaging/libraries/MessageLib.sol";

import {IVaultDeployFactory} from "../../src/vaults/factories/interfaces/IVaultDeployFactory.sol";

/// @dev A vault is deployed by a transaction on its spoke, ahead of the hub's `UpdateVault.DeployAndLink`,
///      which only registers and links it. These deliver the message to a spoke the way a relayer does, so a
///      message arriving before the vault fails into the Gateway rather than reverting the delivery.
contract VaultLocalDeployTest is EndToEndFlows {
    using CastLib for *;
    using MessageLib for *;

    address immutable OUTSIDER = makeAddr("OUTSIDER");

    function _payload() internal view returns (bytes memory) {
        return abi.encode(_defaultPlugins(), uint64(0), uint256(0));
    }

    function _deployMessage() internal view returns (bytes memory) {
        return MessageLib.UpdateVault({
            poolId: POOL_A.raw(),
            scId: SC_1.raw(),
            assetId: s.usdcId.raw(),
            vaultOrFactory: address(s.vaultFactory).toBytes32(),
            kind: uint8(VaultUpdateKind.DeployAndLink),
            extraGasLimit: 0,
            payload: _payload()
        }).serialize();
    }

    function _deploy(address deployer) internal returns (address) {
        vm.prank(deployer);
        return s.vaultFactory.deploy(POOL_A, SC_1, address(s.usdc), 0, _payload());
    }

    /// @dev Returns whether the message executed rather than failed.
    function _deliver(bytes memory message) internal returns (bool) {
        vm.prank(address(s.multiAdapter));
        s.gateway.handle(h.centrifugeId, message);

        return s.gateway.failedMessages(h.centrifugeId, keccak256(message)) == 0;
    }

    function testDeployThenLink() public {
        _configurePool(false);
        address vault = _deploy(OUTSIDER);

        assertTrue(_deliver(_deployMessage()), "the link failed");
        assertTrue(s.spokeRegistry.isLinked(vault), "vault not linked");
        assertEq(IAuth(vault).wards(address(s.root)), 1, "root is the vault's ward");
        assertEq(IAuth(vault).wards(OUTSIDER), 0, "the deployer keeps nothing");
    }

    /// @dev Nothing is deployed inside the message: it fails, and a retry after the deploy links the vault.
    function testLinkBeforeDeployFailsRetryably() public {
        _configurePool(false);
        bytes memory message = _deployMessage();

        assertFalse(_deliver(message), "linked a vault that was never deployed");
        assertEq(s.gateway.failedMessages(h.centrifugeId, keccak256(message)), 1);

        vm.prank(OUTSIDER);
        vm.expectRevert(IVaultDeployFactory.VaultNotDeployed.selector);
        s.gateway.retry(h.centrifugeId, message);

        address vault = _deploy(OUTSIDER);
        vm.prank(OUTSIDER);
        s.gateway.retry(h.centrifugeId, message);

        assertTrue(s.spokeRegistry.isLinked(vault), "vault not linked after the retry");
        assertEq(s.gateway.failedMessages(h.centrifugeId, keccak256(message)), 0);
    }

    /// @dev Whoever deploys first, the vault is the one the pool's payload names, and the pool's own deploy
    ///      returns it.
    function testFrontRunDeployIsHarmless() public {
        _configurePool(false);
        address vault = _deploy(OUTSIDER);

        assertEq(_deploy(FM), vault, "the pool's deploy found another vault");
        assertTrue(_deliver(_deployMessage()), "the link failed");
        assertTrue(s.spokeRegistry.isLinked(vault), "vault not linked");
    }

    /// @dev `VaultFactory.deploy` is permissionless, so a vault exists at its address before the pool's message
    ///      arrives. Another pool's admin names a factory of their own that returns that address, and the registry
    ///      refuses it: the vault says it was built for pool A, whatever factory returned it. The owning pool's own
    ///      message then still links it.
    function testAnotherPoolCannotRegisterAPreDeployedVault() public {
        _configurePool(false);
        address vault = _deploy(OUTSIDER);

        // Pool B is on the spoke, as the hub's own notifications would put it there
        PoolId poolB = h.hubRegistry.poolId(CENTRIFUGE_ID_A, 2);
        ShareClassId scB = h.shareClassManager.previewNextShareClassId(poolB);
        assertTrue(_deliver(MessageLib.NotifyPool({poolId: poolB.raw()}).serialize()), "pool B was not added");
        assertTrue(
            _deliver(
                MessageLib.NotifyShareClass({
                    poolId: poolB.raw(),
                    scId: scB.raw(),
                    name: "B",
                    symbol: bytes32("B"),
                    decimals: 18,
                    salt: bytes32(bytes8(poolB.raw())),
                    registrar: address(s.shareTokenRegistrar).toBytes32(),
                    extraGasLimit: 0,
                    payload: ""
                }).serialize()
            ),
            "pool B's share class was not added"
        );
        require(s.spokeRegistry.hasShareClass(poolB, scB), "pool B is not on the spoke");

        EvilVaultFactory evil = new EvilVaultFactory();
        evil.set(vault);
        bytes memory squat = MessageLib.UpdateVault({
            poolId: poolB.raw(),
            scId: scB.raw(),
            assetId: s.usdcId.raw(),
            vaultOrFactory: address(evil).toBytes32(),
            kind: uint8(VaultUpdateKind.DeployAndLink),
            extraGasLimit: 0,
            payload: ""
        }).serialize();

        assertFalse(_deliver(squat), "pool B registered a vault built for pool A");
        vm.prank(OUTSIDER);
        vm.expectRevert(ISpokeRegistry.InvalidVault.selector);
        s.gateway.retry(h.centrifugeId, squat);
        assertFalse(s.spokeRegistry.isVaultRegistered(vault), "the vault is registered");

        assertTrue(_deliver(_deployMessage()), "the owning pool's link failed");
        assertTrue(s.spokeRegistry.isLinked(vault), "vault not linked");
        assertEq(s.spokeRegistry.vaultDetails(vault).poolId.raw(), POOL_A.raw(), "registered under another pool");
    }

    /// @dev On a hub's own chain the message runs inside the hub call, which then reverts as a whole.
    function testSameChainLinkBeforeDeployReverts() public {
        _configurePool(true);

        vm.prank(FM);
        vm.expectRevert(IVaultDeployFactory.VaultNotDeployed.selector);
        h.hub.updateVault{value: GAS}(
            POOL_A,
            SC_1,
            s.usdcId,
            address(s.vaultFactory).toBytes32(),
            VaultUpdateKind.DeployAndLink,
            _payload(),
            EXTRA_GAS,
            REFUND
        );
    }
}
