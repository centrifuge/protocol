// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {d18} from "../../../../src/misc/types/D18.sol";
import {CastLib} from "../../../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {AccountId} from "../../../../src/core/types/AccountId.sol";
import {RequestId} from "../../../../src/core/types/RequestId.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {IHubRequestManager} from "../../../../src/core/hub/interfaces/IHubRequestManager.sol";
import {ManagerKind, VaultUpdateKind} from "../../../../src/core/messaging/libraries/MessageLib.sol";

import {IShareTokenHook} from "../../../../src/token/hooks/interfaces/IShareTokenHook.sol";
import {UpdateRestrictionMessageLib} from "../../../../src/token/hooks/libraries/UpdateRestrictionMessageLib.sol";

import {VaultRequestIdLib} from "../../../../src/vaults/libraries/VaultRequestIdLib.sol";
import {IReserveInstantPolicy} from "../../../../src/vaults/policies/interfaces/IVaultPlugins.sol";
import {IVaultLiquidityRoute} from "../../../../src/vaults/liquidity/interfaces/IVaultLiquidityRoute.sol";

import {vm} from "@chimera/Hevm.sol";
import {OpType} from "../BeforeAfter.sol";
import {Properties} from "../properties/Properties.sol";
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {IShareTokenRegistrar} from "../../../../src/token/interfaces/IShareTokenRegistrar.sol";

/// @notice Pool isolation against an adversary. Pool D has its own manager and holds real deposits, pool B is
///         handed to a manager of its own, and FM and the BSM manage pool A (and C) only, so every call below
///         is made by someone with authority over one pool and aims it at another. A cross-pool guarantee is
///         then something a handler can try to break instead of something that holds because nobody tried.
/// @dev    Two kinds of check. A call that must be refused (the caller holds no role on the pool it names, or
///         the share class it names is not in that pool) is asserted to revert. A manager call that routes
///         through the Envoy, where the target decides, is asserted by what it leaves behind: the footprint of
///         every pool it was not entitled to touch is the same after as before (`Setup._footprint`).
abstract contract PoolIsolationTargets is BaseTargetFunctions, Properties {
    using CastLib for *;
    using UpdateRestrictionMessageLib for *;

    /// @dev One hash per pool, zero for a pool a handler did not snapshot.
    struct Snap {
        bytes32 a;
        bytes32 b;
        bytes32 c;
        bytes32 d;
    }

    //----------------------------------------------------------------------------------------------
    // Manager payloads that name another pool's objects
    //----------------------------------------------------------------------------------------------

    /// @dev Pool D's manager sends a configuration payload through the Hub and the Envoy to a shared singleton
    ///      (the instant policy, the liquidity routes, the share token hook, the registrar) naming a vault or
    ///      share class of pool A, B or C: terms with the attacker as fee recipient, an allowlisted caller, a
    ///      route to or consent from another pool's vault, a limit on its line, a trusted call on its hook, a
    ///      ward or hook or vault pointer on its share token. The singleton must refuse each, since the pool id
    ///      the Envoy authenticated is D's. Nothing of A, B or C may move. D's manager is no manager of them,
    ///      so a change anywhere in their footprint is a boundary crossing.
    function isolation_dManagerCall(uint256 variantSeed, uint256 victimSeed) public updateGhosts(OpType.MANAGER) {
        uint256 pick = victimSeed % (vaults.length + 2);
        (address victim, ShareClassId victimSc) = pick < vaults.length
            ? (address(vaults[pick]), scA)
            : pick == vaults.length ? (address(vaultB), scB) : (address(vaultC), scC);

        Snap memory before = _snap(true, true, true, false);
        bool success = _crossManagerCall(MALLORY, poolD, variantSeed, victim, victimSc, address(vaultD));
        t(!success, "pool D's manager call naming another pool's object went through");
        _assertSame(before, true, true, true, false, "pool D's manager call moved another pool");
        _count("isolation_dManagerCall", success);
    }

    /// @dev The same from pool A's own manager, which also manages pool C: a payload sent under pool A's id
    ///      that names a vault or share class of pool B, C or D. The manager's authority over pool C does not
    ///      carry into a call authenticated as pool A, so pools B, C and D must be as they were.
    function isolation_aManagerCall(uint256 variantSeed, uint256 victimSeed) public updateGhosts(OpType.MANAGER) {
        uint256 pick = victimSeed % 3;
        (address victim, ShareClassId victimSc) =
            pick == 0 ? (address(vaultB), scB) : pick == 1 ? (address(vaultC), scC) : (address(vaultD), scD);

        Snap memory before = _snap(false, true, true, true);
        bool success = _crossManagerCall(FM, poolA, variantSeed, victim, victimSc, address(vaults[2]));
        // Pool A routing its own vault to pool C's, which pool C consented to in setup, is its own business
        bool ownRoute = variantSeed % 11 == 5 && victim == address(vaultC);
        t(!success || ownRoute, "pool A's manager call naming another pool's object went through");
        _assertSame(before, false, true, true, true, "pool A's manager call moved another pool");
        _count("isolation_aManagerCall", success);
    }

    //----------------------------------------------------------------------------------------------
    // Hub entry points
    //----------------------------------------------------------------------------------------------

    /// @dev A manager of one pool calls a Hub, FeeRequestManager or oracle entry point with another pool's id:
    ///      prices, restrictions, manager roles, accounts, the request manager, vault links, manager calls,
    ///      fills, cancellations, request callbacks, policies, holdings. The caller holds no role there, so each
    ///      must revert. Callers are FM (pools A and C), D's manager and B's manager.
    function isolation_hubCross(uint256 callerSeed, uint256 poolSeed, uint256 variantSeed)
        public
        updateGhosts(OpType.MANAGER)
    {
        address caller = callerSeed % 3 == 0 ? FM : callerSeed % 3 == 1 ? MALLORY : MANAGER_B;
        (PoolId pool, ShareClassId sc, address vault) = _tenant(poolSeed);
        uint256 variant = variantSeed % 17;
        if (hubRegistry.manager(pool, caller)) return;
        if (variant == 16 && oracleValuation.feeder(pool, 0, caller.toBytes32())) return;

        (address target, bytes memory data) = _hubCall(variant, caller, pool, sc, vault);
        (bool success,) = _callAs(caller, target, data);
        t(!success, "a manager without a role on the pool called a hub entry point of it");
        _count("isolation_hubCross", success);
    }

    /// @dev Pool A's manager, and D's, send a fill or a cancellation through the FeeRequestManager for a request
    ///      id owned by another pool's vault. Request ids carry their vault, and the hub's order book is keyed
    ///      by pool, so the order does not exist under the acting pool and the call may not settle anything of
    ///      the vault the id names. Nothing of any pool may change.
    function isolation_settleCross(uint256 sideSeed, uint256 victimSeed, uint256 idSeed, uint256 amount, bool isDeposit)
        public
        updateGhosts(OpType.MANAGER)
    {
        bool asD = sideSeed % 2 == 0;
        address[5] memory victims =
            [address(vaultB), address(vaultC), address(vaultD), address(vaults[0]), address(vaults[1])];
        address victim = victims[victimSeed % (asD ? 5 : 3)];
        if (asD && victim == address(vaultD)) victim = address(vaultB);

        Snap memory before = _snap(true, true, true, true);
        RequestId rid = VaultRequestIdLib.from(victim, uint96(between(idSeed, 0, 4)));
        bool success = _settle(asD, sideSeed % 4 >= 2, rid, isDeposit, amount);
        t(!success, "a settlement named another pool's vault and went through");
        _assertSame(before, true, true, true, true, "a settlement named another pool's vault and moved a pool");
        _count("isolation_settleCross", success);
    }

    function _settle(bool asD, bool cancel, RequestId rid, bool isDeposit, uint256 amount)
        internal
        returns (bool success)
    {
        (PoolId pool, ShareClassId sc) = asD ? (poolD, scD) : (poolA, scA);
        uint128 fill = uint128(between(amount, 1, 1e12));
        bytes memory data = cancel
            ? abi.encodeCall(feeRequestManager.cancel, (pool, sc, usdcId, rid, isDeposit, fill, 0, REFUND))
            : abi.encodeCall(feeRequestManager.fulfill, (pool, sc, usdcId, rid, isDeposit, fill, 0, REFUND));
        (success,) = _callAs(asD ? MALLORY : FM, address(feeRequestManager), data);
    }

    /// @dev Vault links and the factory a pool names. Pool D's manager links, unlinks or deploys-and-links (through
    ///      a factory that returns the address it is told to) a vault or contract of another pool under D's
    ///      position, and pool A's manager links or unlinks a vault of B, C or D under A's. The registry keys a
    ///      vault to the pool it was registered for, so none of it may change that vault's record or reach
    ///      anything else of the pool that owns it.
    function isolation_linkCross(uint256 modeSeed, uint256 victimSeed) public updateGhosts(OpType.MANAGER) {
        uint256 mode = modeSeed % 4;
        bool asD = mode != 3;
        address[9] memory victims = [
            address(vaults[0]),
            address(vaults[1]),
            address(vaults[2]),
            address(vaults[3]),
            address(vaultB),
            address(vaultC),
            address(_escrow(poolA)),
            address(shareA),
            address(vaultRoute)
        ];
        address victim = asD ? victims[victimSeed % victims.length] : victims[4 + victimSeed % 2];
        if (!asD && victimSeed % 3 == 2) victim = address(vaultD);
        (PoolId pool, ShareClassId sc) = asD ? (poolD, scD) : (poolA, scA);
        bytes32 target = victim.toBytes32();
        VaultUpdateKind kind = VaultUpdateKind.Link;
        if (mode == 0) {
            evilFactory.set(victim);
            target = address(evilFactory).toBytes32();
            kind = VaultUpdateKind.DeployAndLink;
        } else if (mode == 2 || (mode == 3 && victimSeed % 2 == 1)) {
            kind = VaultUpdateKind.Unlink;
        }

        // A vault the registry keeps for another pool is never this pool's to deploy, link or unlink. A contract
        // nobody registered can be, through a factory the pool names: linked is pool identity, not code
        bool refused = spokeRegistry.isVaultRegistered(victim)
            && (mode == 0 || spokeRegistry.vaultDetails(victim).poolId.raw() != pool.raw());

        Snap memory before = _snap(asD, true, true, !asD);
        bytes memory data = abi.encodeCall(hub.updateVault, (pool, sc, usdcId, target, kind, "", 0, REFUND));
        _authorize(pool, data);
        (bool success,) = _callAs(asD ? MALLORY : FM, address(hub), data);
        t(!(refused && success), "a pool linked or registered a vault of another pool");
        _assertSame(before, asD, true, true, !asD, "a vault link named another pool's vault and moved a pool");
        _count("isolation_linkCross", success);
    }

    //----------------------------------------------------------------------------------------------
    // Spoke entry points
    //----------------------------------------------------------------------------------------------

    /// @dev A balance-sheet caller aims a Spoke, oracle, route or remote-call entry point at a pool it holds no
    ///      role on: the BSM, the auxiliary manager, a vault, the liquidity routes, D's manager, FM, an outsider.
    ///      Each must revert. D's manager also names pool D with a share class of another pool for the calls that
    ///      need that share class to exist in the pool (shares, withdrawals): the escrow and the registry key
    ///      them by the pool, so the share class of A does not resolve inside D.
    function isolation_spokeCross(
        uint256 callerSeed,
        uint256 poolSeed,
        uint256 scSeed,
        uint256 opSeed,
        uint256 amountSeed
    ) public updateGhosts(OpType.MANAGER) {
        address caller = _spokeCaller(callerSeed);
        (PoolId pool,,) = _tenant(poolSeed);
        ShareClassId sc = _scOfTenant(scSeed);
        uint256 op = opSeed % 15;
        uint128 amount = uint128(between(amountSeed, 1, 1e6));

        // What the caller may do in its own pool is not this handler's business, but a pool D call with another
        // pool's share class is, for the operations that cannot succeed on a share class the pool does not have
        bool foreign = pool.raw() == poolD.raw() && sc.raw() != scD.raw();
        bool refused = op == 2 || op == 3 || (op >= 7 && op <= 9) || op == 11;
        if (spokeRegistry.manager(pool, caller) && !(foreign && refused)) return;
        if (op == 14 && oracleValuation.feeder(pool, CENTRIFUGE_ID, caller.toBytes32())) return;

        (address target, bytes memory data) = _spokeCall(op, caller, pool, sc, amount);
        (bool success,) = _callAs(caller, target, data);
        t(!success, "a caller without a role on the pool called a spoke entry point of it");
        _count("isolation_spokeCross", success);
    }

    //----------------------------------------------------------------------------------------------
    // Payload and call builders
    //----------------------------------------------------------------------------------------------

    function _crossManagerCall(
        address caller,
        PoolId pool,
        uint256 variantSeed,
        address victim,
        ShareClassId victimSc,
        address own
    ) internal returns (bool success) {
        (address target, bytes memory payload) = _managerPayload(variantSeed % 11, victim, victimSc, own);
        bytes memory data =
            abi.encodeCall(hub.managerCall, (pool, CENTRIFUGE_ID, target.toBytes32(), payload, 0, 0, REFUND));
        _authorize(pool, data);
        vm.deal(caller, 1 ether);
        (success,) = _callAs(caller, address(hub), data);
    }

    function _managerPayload(uint256 variant, address victim, ShareClassId victimSc, address own)
        internal
        view
        returns (address target, bytes memory payload)
    {
        bytes memory terms = abi.encode(MALLORY, uint16(9000), uint16(9000), true, false, false, type(uint128).max);
        address[] memory ownRoute = new address[](1);
        ownRoute[0] = own;
        address[] memory victimRoute = new address[](1);
        victimRoute[0] = victim;
        if (variant == 0) {
            return (address(reserveInstantPolicy), abi.encode(IReserveInstantPolicy.ConfigKind.Terms, victim, terms));
        }
        if (variant == 1) {
            return (
                address(reserveInstantPolicy),
                abi.encode(IReserveInstantPolicy.ConfigKind.Depositor, victim, abi.encode(MALLORY, true))
            );
        }
        if (variant == 2) {
            return (
                address(reserveInstantPolicy),
                abi.encode(IReserveInstantPolicy.ConfigKind.Redeemer, victim, abi.encode(MALLORY, true))
            );
        }
        if (variant == 3) {
            return
                (address(vaultRoute), abi.encode(IVaultLiquidityRoute.ConfigKind.Routes, victim, abi.encode(ownRoute)));
        }
        if (variant == 4) {
            return
                (
                    address(vaultRoute),
                    abi.encode(IVaultLiquidityRoute.ConfigKind.Consent, victim, abi.encode(own, true))
                );
        }
        if (variant == 5) {
            return
                (address(vaultRoute), abi.encode(IVaultLiquidityRoute.ConfigKind.Routes, own, abi.encode(victimRoute)));
        }
        if (variant == 6) return (address(basinRoute), abi.encode(victim, type(uint128).max));
        if (variant == 7) {
            return (
                address(fullRestrictions),
                abi.encode(
                    victimSc.raw(), uint8(IShareTokenHook.TrustedCall.UpdateHookManager), MALLORY.toBytes32(), true
                )
            );
        }
        if (variant == 8) {
            return (
                address(shareTokenRegistrar),
                abi.encode(uint8(IShareTokenRegistrar.RegistrarCall.SetHook), victimSc, MALLORY)
            );
        }
        if (variant == 9) {
            return (
                address(shareTokenRegistrar),
                abi.encode(uint8(IShareTokenRegistrar.RegistrarCall.UpdateWard), victimSc, MALLORY, true)
            );
        }
        return (
            address(shareTokenRegistrar),
            abi.encode(uint8(IShareTokenRegistrar.RegistrarCall.SetVault), victimSc, usdcId.raw(), victim)
        );
    }

    function _hubCall(uint256 variant, address caller, PoolId pool, ShareClassId sc, address vault)
        internal
        view
        returns (address target, bytes memory data)
    {
        target = address(hub);
        RequestId rid = VaultRequestIdLib.from(vault, 1);
        if (variant == 0) {
            data = abi.encodeWithSignature(
                "updateSharePrice(uint64,bytes16,uint128)", pool.raw(), sc.raw(), uint128(2e18)
            );
        } else if (variant == 1) {
            data = abi.encodeCall(hub.updateRestriction, (pool, sc, CENTRIFUGE_ID, _memberMsg(caller), 0, REFUND));
        } else if (variant == 2) {
            data = abi.encodeCall(hub.updateHubManager, (pool, caller, true));
        } else if (variant == 3) {
            data = abi.encodeCall(
                hub.updateManager, (pool, CENTRIFUGE_ID, ManagerKind.Spoke, caller.toBytes32(), true, REFUND)
            );
        } else if (variant == 4) {
            data = abi.encodeCall(hub.createAccount, (pool, AccountId.wrap(9), true));
        } else if (variant == 5) {
            data = abi.encodeCall(
                hub.setRequestManager,
                (pool, CENTRIFUGE_ID, IHubRequestManager(address(orderBook)), address(vaultRouter).toBytes32(), REFUND)
            );
        } else if (variant == 6) {
            data = abi.encodeCall(
                hub.updateVault, (pool, sc, usdcId, vault.toBytes32(), VaultUpdateKind.Unlink, "", 0, REFUND)
            );
        } else if (variant == 7) {
            (, bytes memory payload) = _managerPayload(0, vault, sc, vault);
            data = abi.encodeCall(
                hub.managerCall, (pool, CENTRIFUGE_ID, address(reserveInstantPolicy).toBytes32(), payload, 0, 0, REFUND)
            );
        } else if (variant == 8) {
            target = address(feeRequestManager);
            data = abi.encodeCall(feeRequestManager.fulfill, (pool, sc, usdcId, rid, true, 1, 0, REFUND));
        } else if (variant == 9) {
            target = address(feeRequestManager);
            data = abi.encodeCall(feeRequestManager.cancel, (pool, sc, usdcId, rid, true, 1, 0, REFUND));
        } else if (variant == 10) {
            data = abi.encodeCall(hub.notifySharePrice, (pool, sc, CENTRIFUGE_ID, REFUND));
        } else if (variant == 11) {
            data = abi.encodeCall(hub.setPolicy, (pool, hubPolicy));
        } else if (variant == 12) {
            data = abi.encodeCall(hub.requestCallback, (pool, sc, usdcId, "", 0, false, REFUND));
        } else if (variant == 13) {
            data = abi.encodeCall(hub.updateHoldingValuation, (pool, sc, usdcId, identityValuation));
        } else if (variant == 14) {
            data = abi.encodeCall(hub.setPoolMetadata, (pool, "x"));
        } else if (variant == 15) {
            data = abi.encodeCall(hub.updateCurrency, (pool, usdcId));
        } else {
            target = address(oracleValuation);
            data = abi.encodeCall(oracleValuation.setPrice, (pool, sc, usdcId, d18(2, 1)));
        }
    }

    function _spokeCall(uint256 op, address caller, PoolId pool, ShareClassId sc, uint128 amount)
        internal
        view
        returns (address target, bytes memory data)
    {
        target = address(spoke);
        address usdcAddress = address(usdc);
        if (op == 0) {
            data = abi.encodeCall(spoke.deposit, (pool, sc, usdcAddress, 0, amount));
        } else if (op == 1) {
            data = abi.encodeCall(spoke.noteDeposit, (pool, sc, usdcAddress, 0, amount));
        } else if (op == 2) {
            data = abi.encodeCall(spoke.withdraw, (pool, sc, usdcAddress, 0, caller, amount));
        } else if (op == 3) {
            data =
                abi.encodeCall(spoke.withdrawReserved, (pool, sc, usdcAddress, 0, caller, amount, caller, bytes32(0)));
        } else if (op == 4) {
            data = abi.encodeCall(spoke.reserve, (pool, sc, usdcAddress, 0, amount, caller, bytes32(0)));
        } else if (op == 5) {
            data = abi.encodeCall(spoke.unreserve, (pool, sc, usdcAddress, 0, amount, caller, bytes32(0)));
        } else if (op == 6) {
            data = abi.encodeCall(spoke.submitQueuedAssets, (pool, sc, usdcId, 0, REFUND));
        } else if (op == 7) {
            data = abi.encodeCall(spoke.issue, (pool, sc, caller, amount));
        } else if (op == 8) {
            data = abi.encodeCall(spoke.revoke, (pool, sc, amount));
        } else if (op == 9) {
            data = abi.encodeCall(spoke.withdrawShares, (pool, sc, caller, amount));
        } else if (op == 10) {
            data = abi.encodeCall(spoke.submitQueuedShares, (pool, sc, 0, REFUND));
        } else if (op == 11) {
            data = abi.encodeCall(spoke.transferSharesFrom, (pool, sc, caller, actors[0], caller, amount));
        } else if (op == 12) {
            target = address(spokeOracle);
            data = abi.encodeCall(spokeOracle.pause, (pool));
        } else if (op == 13) {
            target = address(basinRoute);
            data = abi.encodeCall(basinRoute.repay, (_vaultOfPool(pool), amount));
        } else {
            // The remote-call path: the price feeder's call, which only a registered feeder of the pool may make
            data = abi.encodeCall(
                spoke.managerCall,
                (
                    pool,
                    address(oracleValuation).toBytes32(),
                    abi.encode(sc.raw(), usdcId, uint128(2e18), uint64(block.timestamp)),
                    0,
                    REFUND
                )
            );
        }
    }

    function _vaultOfPool(PoolId pool) internal view returns (address) {
        if (pool.raw() == poolA.raw()) return address(vaults[3]);
        if (pool.raw() == poolB.raw()) return address(vaultB);
        if (pool.raw() == poolC.raw()) return address(vaultC);
        return address(vaultD);
    }

    function _tenant(uint256 seed) internal view returns (PoolId pool, ShareClassId sc, address vault) {
        uint256 i = seed % 4;
        if (i == 0) return (poolA, scA, address(vaults[0]));
        if (i == 1) return (poolB, scB, address(vaultB));
        if (i == 2) return (poolC, scC, address(vaultC));
        return (poolD, scD, address(vaultD));
    }

    function _scOfTenant(uint256 seed) internal view returns (ShareClassId sc) {
        (, sc,) = _tenant(seed);
    }

    function _spokeCaller(uint256 seed) internal view returns (address) {
        uint256 i = seed % 12;
        if (i == 0) return BSM;
        if (i == 1) return AUX_MANAGER;
        if (i == 2) return MALLORY;
        if (i == 3) return FM;
        if (i == 4) return MANAGER_B;
        if (i == 5) return address(vaultRoute);
        if (i == 6) return address(basinRoute);
        if (i == 7) return OUTSIDER;
        if (i == 8) return address(vaultB);
        if (i == 9) return address(vaultC);
        if (i == 10) return address(vaultD);
        return address(vaults[(seed / 12) % vaults.length]);
    }

    //----------------------------------------------------------------------------------------------
    // Footprints
    //----------------------------------------------------------------------------------------------

    /// @dev Reachability: a call that got through and one that was refused are both counted, so the reachability
    ///      test sees that a handler runs and that its refusals are the ones meant.
    function _count(bytes32 action, bool success) internal {
        if (success) _ok(action);
        else _reverted(action);
    }

    function _snap(bool a, bool b, bool c, bool d) internal view returns (Snap memory s) {
        if (a) s.a = _footprintA();
        if (b) s.b = _footprintB();
        if (c) s.c = _footprintC();
        if (d) s.d = _footprintD();
    }

    function _assertSame(Snap memory before, bool a, bool b, bool c, bool d, string memory what) internal {
        if (a) t(_footprintA() == before.a, string.concat(what, " (A)"));
        if (b) t(_footprintB() == before.b, string.concat(what, " (B)"));
        if (c) t(_footprintC() == before.c, string.concat(what, " (C)"));
        if (d) t(_footprintD() == before.d, string.concat(what, " (D)"));
    }
}
