// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {d18} from "../../../../src/misc/types/D18.sol";
import {IAuth} from "../../../../src/misc/interfaces/IAuth.sol";
import {CastLib} from "../../../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {AccountId} from "../../../../src/core/types/AccountId.sol";
import {RequestId} from "../../../../src/core/types/RequestId.sol";
import {IAdapter} from "../../../../src/core/messaging/interfaces/IAdapter.sol";
import {IRegistrar} from "../../../../src/core/spoke/interfaces/IRegistrar.sol";
import {JournalEntry} from "../../../../src/core/hub/interfaces/IAccounting.sol";
import {IBridgingHook} from "../../../../src/core/hub/interfaces/IBridgingHook.sol";
import {ISnapshotHook} from "../../../../src/core/hub/interfaces/ISnapshotHook.sol";
import {IPolicy, IHubPolicy} from "../../../../src/core/utils/interfaces/IPolicy.sol";
import {IHubRequestManager} from "../../../../src/core/hub/interfaces/IHubRequestManager.sol";
import {IVaultFactory} from "../../../../src/core/spoke/factories/interfaces/IVaultFactory.sol";
import {ISpokeRequestManager} from "../../../../src/core/spoke/interfaces/ISpokeRequestManager.sol";
import {ManagerKind, VaultUpdateKind} from "../../../../src/core/messaging/libraries/MessageLib.sol";

import {Fulfillment} from "../../../../src/vaults/hub/interfaces/IOrderBook.sol";
import {IVaultLiquidityRoute} from "../../../../src/vaults/liquidity/interfaces/IVaultLiquidityRoute.sol";

import {vm} from "@chimera/Hevm.sol";
import {OpType} from "../BeforeAfter.sol";
import {Properties} from "../properties/Properties.sol";
import {USD_ID} from "../../../../src/deployment/Currencies.sol";
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";

/// @notice Access-control negatives for the privileged entry points, called by an account that does not hold the
///         role the entry point asks for. The tester is warded on every protocol contract (and `FM`, `BSM` hold
///         the pool's manager roles), so a call made without a prank passes `auth` and proves nothing: every call
///         here is pranked as a stranger or as the holder of a DIFFERENT role (the pool B manager, the balance-sheet
///         manager, the auxiliary manager, a feeder, the liquidity provider, a vault, a request manager, another
///         protocol contract), and must revert. Where the contract's error is knowable the revert is asserted to be
///         THAT error, so a call refused for a bad argument instead of for the role does not count.
///
/// @dev    The list is derived from `src` by grepping the modifiers and guards (`auth`, `onlyManager`, `enforced`,
///         `onlyRequestManager`, `onlyEnvoy`, `onlyMinter`, `authOrHook`, `authOrManager`, `msg.sender == ...`
///         requires, `NotEnforcer`, `CallerNotPolicy`), not from memory. Each entry records who IS allowed in
///         `mask`, and the caller drawn is never one of them (a ward, a manager of that pool, the fixed address, a
///         linked vault, a minter, a feeder, a hook manager), so a success is always a missing or broken guard.
///
///         Swept (entry points per contract; `ENTRIES` below counts them):
///         - Hub: every `enforced`/`onlyManager` function, `setPolicy`, `requestCallback`, the `auth` accounting
///           posts, `file` and `createPool`.
///         - HubHandler, HubRegistry (incl. `consumeAuthorization`), ShareClassManager, Holdings, Accounting.
///         - Spoke: every `enforced` balance-sheet function (incl. `transferSharesFrom`, which the
///           `BalanceSheetTargets` sweep does not reach), the owner-gated `crosschainTransferShares`, `request`.
///         - SpokeRegistry (incl. `consumeAuthorization`), SpokeHandler, Escrow, SnapshotQueue, EscrowFactory, Envoy.
///         - ShareTokenRegistrar, ShareToken, ShareTokenHook: `auth`, `authOrHook`, `authOrManager`, `fromHub`.
///         - Vault `onlyRequestManager` callbacks, OrderBook (`request`, `fromHub`, `fulfillCallback`),
///           FeeRequestManager (`fulfill`, `cancel`, `fromHub`), VaultRequestRouter (`callback`, `fromHub`,
///           `send*Request`), investor VaultRouter owner gate, both liquidity routes, ReserveInstantPolicy,
///           SpokeOracle, OracleValuation, AccountingToken, SubsidyManager, StdHubPolicy `enforce`, Root's `auth`
///           functions, and `rely`/`deny` on every warded contract.
///
///         Deliberately excluded (permissionless by design, or covered elsewhere):
///         - `Spoke.registerAsset`, `Spoke.managerCall`, `Spoke.crosschainTransferShares` (6-arg, the caller's own
///           shares), `Hub.updateSharePrice` 3-arg (forwards to the manager-gated 4-arg one, swept as that), the
///           vault's investor functions (`StandardsTargets` covers `onlyController`), `flushRequest`/`foldRequest`,
///           `claim` on the liquidity routes, `VaultFactory.deploy`, `StdHubPolicy.newHubPolicy`,
///           `SubsidyManager.deposit`, `Root.executeScheduledRely` (timelocked), `ShareTokenHook` transfer checks.
///         - Gateway, MultiAdapter, MessageProcessor, MessageDispatcher entry points: `recon-messaging` owns them.
///         - Guardians, Supervisor, AdapterFailover, OnchainPM and its guards, BridgeCircuitBreaker, NAV and price
///           managers: not deployed by `Setup`.
///         - `ERC20.mint/burn` of the test USDC: a test token.
abstract contract StrangerTargets is BaseTargetFunctions, Properties {
    using CastLib for *;

    /// @dev Who is allowed, as a bit set on the entry: a ward of the target, a hub manager of the pool, a spoke
    ///      manager of the pool, the fixed address `who`, a linked vault, a hook manager of token `who`, an
    ///      accounting-token minter, a local price feeder.
    uint8 internal constant W = 1;
    uint8 internal constant H = 2;
    uint8 internal constant S = 4;
    uint8 internal constant F = 8;
    uint8 internal constant L = 16;
    uint8 internal constant K = 32;
    uint8 internal constant M = 64;
    uint8 internal constant P = 128;

    /// @dev Error selectors by signature, since an interface error is not a constant expression. The sweep in
    ///      `StrangerTargets.t.sol` fails on a signature that matches nothing, as the refused call then reverts with
    ///      another selector.
    bytes4 internal constant NOT_AUTHORIZED = bytes4(keccak256("NotAuthorized()"));
    bytes4 internal constant NOT_LINKED = bytes4(keccak256("NotLinked()"));
    bytes4 internal constant NOT_MANAGER = bytes4(keccak256("NotManager()"));
    bytes4 internal constant NOT_ENVOY = bytes4(keccak256("NotEnvoy()"));
    bytes4 internal constant NOT_VAULT = bytes4(keccak256("NotVault()"));
    bytes4 internal constant NOT_ENFORCER = bytes4(keccak256("NotEnforcer()"));
    bytes4 internal constant CALLER_NOT_POLICY = bytes4(keccak256("CallerNotPolicy()"));
    bytes4 internal constant NOT_AUTH_OR_HOOK = bytes4(keccak256("NotAuthorizedOrHook()"));
    bytes4 internal constant INVALID_OWNER = bytes4(keccak256("InvalidOwner()"));
    bytes4 internal constant INVALID_CONTROLLER = bytes4(keccak256("InvalidController()"));
    bytes4 internal constant NOT_MINTER = bytes4(keccak256("NotMinter()"));
    bytes4 internal constant NOT_FEEDER = bytes4(keccak256("NotFeeder()"));
    bytes4 internal constant NOT_LP = bytes4(keccak256("NotLiquidityProvider()"));
    bytes4 internal constant CALLBACK_LOCKED = bytes4(keccak256("CallbackIsLocked()"));

    /// @dev Entries with no error named (`Root.relyContract/denyContract`: the refusal can come from Root or from the
    ///      target it relays to, with one selector) are only asserted to revert. The `VaultRouter` entries name the
    ///      check that must fire: the owner check comes first, so a stranger's own controller leaves it alone.
    /// @dev The number of entries `_entry` knows; `StrangerTargets.t.sol` fails if it falls out of step.
    uint256 internal constant ENTRIES = 210;

    /// @dev Holds the manager role of pool B only: a manager, but of another pool.
    address internal constant OTHER_FM = address(0xF001);

    /// @dev What an entry is built from, kept in memory so each section stays within the stack.
    struct Ctx {
        address caller;
        uint256 salt;
        address vault;
        address requestManager;
        address envoy;
        bytes memberMsg;
        bytes anyBytes;
    }

    struct Entry {
        string name;
        address target;
        bytes data;
        bytes4 err;
        uint8 mask;
        PoolId pool;
        address who;
    }

    bool internal strangersReady;

    //----------------------------------------------------------------------------------------------
    // Handler
    //----------------------------------------------------------------------------------------------

    /// @dev Calls one privileged entry point as an account without the role and expects the contract's own
    ///      refusal. A success means a guard is missing, and is recorded in `ghost_unauthorizedSuccess`
    ///      besides failing here. `entrySeed` picks the entry point, `callerSeed` the wrong-role caller (the next
    ///      candidate is taken when the draw happens to hold the role).
    function stranger_call(uint256 entrySeed, uint256 callerSeed) public updateGhosts(OpType.MANAGER) {
        _prepareStrangers();
        uint256 i = entrySeed % ENTRIES;
        address[] memory candidates = _candidates();
        uint256 salt = callerSeed >> 16;
        for (uint256 k; k < candidates.length; k++) {
            address caller = candidates[(callerSeed + k) % candidates.length];
            Entry memory e = _entry(i, caller, salt);
            if (_authorized(e, caller)) continue;
            _strangerCall(e, caller);
            return;
        }
    }

    /// @dev Runs `e` as `caller` and asserts it is refused, with the entry's own error when it names one.
    function _strangerCall(Entry memory e, address caller) internal {
        vm.prank(caller);
        (bool success, bytes memory ret) = e.target.call(e.data);
        if (success) {
            ghost_unauthorizedSuccess++;
            t(false, string.concat("stranger call succeeded: ", e.name));
            return;
        }
        if (e.err != bytes4(0) && bytes4(ret) != e.err) {
            t(false, string.concat("refused with another error than the role check: ", e.name));
            return;
        }
        _ok("stranger_call");
    }

    /// @dev One caller of pool B's manager role, granted on first use by the tester (a ward of both registries).
    function _prepareStrangers() internal {
        if (strangersReady) return;
        strangersReady = true;
        hubRegistry.updateManager(poolB, OTHER_FM, true);
        spokeRegistry.updateManager(poolB, OTHER_FM, true);
    }

    /// @dev Accounts without a role in pool A, and accounts with a role elsewhere: another pool's manager, the
    ///      balance-sheet and auxiliary managers, vaults, request managers and protocol contracts that are wards
    ///      of other contracts but not of the target.
    function _candidates() internal view returns (address[] memory c) {
        c = new address[](34);
        uint256 n;
        c[n++] = OUTSIDER;
        c[n++] = actors[0];
        c[n++] = actors[1];
        c[n++] = actors[2];
        c[n++] = LP;
        c[n++] = FEEDER;
        c[n++] = FEE_RECIPIENT;
        c[n++] = INVESTOR_B;
        c[n++] = REFUND;
        c[n++] = BSM;
        c[n++] = AUX_MANAGER;
        c[n++] = FM;
        c[n++] = OTHER_FM;
        c[n++] = address(vaults[0]);
        c[n++] = address(vaults[1]);
        c[n++] = address(vaults[2]);
        c[n++] = address(vaults[3]);
        c[n++] = address(vaultB);
        c[n++] = address(vaultC);
        c[n++] = address(orderBook);
        c[n++] = address(feeRequestManager);
        c[n++] = address(vaultRouter);
        c[n++] = address(investorRouter);
        c[n++] = address(vaultRoute);
        c[n++] = address(basinRoute);
        c[n++] = address(oracleValuation);
        c[n++] = address(hubPolicy);
        c[n++] = address(fullRestrictions);
        c[n++] = address(shareA);
        c[n++] = address(spoke);
        c[n++] = address(hub);
        c[n++] = address(hubHandler);
        c[n++] = address(spokeHandler);
        c[n++] = address(_escrow(poolA));
    }

    function _authorized(Entry memory e, address c) internal view returns (bool) {
        if (e.mask & W != 0 && IAuth(e.target).wards(c) == 1) return true;
        if (e.mask & H != 0 && hubRegistry.manager(e.pool, c)) return true;
        if (e.mask & S != 0 && spokeRegistry.manager(e.pool, c)) return true;
        if (e.mask & F != 0 && c == e.who) return true;
        if (e.mask & L != 0 && spokeRegistry.isLinked(c)) return true;
        if (e.mask & K != 0 && fullRestrictions.manager(e.who, c)) return true;
        if (e.mask & M != 0 && accountingToken.minters(poolA, c)) return true;
        if (e.mask & P != 0 && oracleValuation.feeder(poolA, 0, c.toBytes32())) return true;
        return false;
    }

    //----------------------------------------------------------------------------------------------
    // Entry table
    //----------------------------------------------------------------------------------------------

    function _e(string memory name, address target, bytes memory data, bytes4 err, uint8 mask)
        internal
        view
        returns (Entry memory)
    {
        return Entry(name, target, data, err, mask, poolA, address(0));
    }

    function _f(string memory name, address target, bytes memory data, bytes4 err, uint8 mask, address who)
        internal
        view
        returns (Entry memory)
    {
        return Entry(name, target, data, err, mask, poolA, who);
    }

    /// @dev One call per privileged entry point, encoded for pool A with arguments that are valid for it, so the
    ///      role is the only thing the caller lacks. An index past the table returns an empty entry.
    ///      `caller` appears as the beneficiary of the escalating calls (`who` of a manager grant, the receiver of
    ///      a withdrawal), the way an attacker would name itself. `salt` picks among the vaults.
    function _entry(uint256 i, address caller, uint256 salt) internal view returns (Entry memory) {
        Ctx memory c = Ctx({
            caller: caller,
            salt: salt,
            vault: address(vaults[salt % vaults.length]),
            requestManager: address(spokeRegistry.requestManager(poolA)),
            envoy: address(envoy),
            memberMsg: _memberMsg(caller),
            anyBytes: abi.encode(uint256(1))
        });
        if (i < 37) return _section0(i - 0, c);
        if (i < 76) return _section1(i - 37, c);
        if (i < 147) return _section2(i - 76, c);
        if (i < 167) return _section3(i - 147, c);
        if (i < 213) return _section4(i - 167, c);
        return _none();
    }

    function _none() internal view returns (Entry memory) {
        return Entry("", address(0), "", bytes4(0), 0, poolA, address(0));
    }

    /// @dev Hub: manager-gated (NotManager)
    function _section0(uint256 i, Ctx memory c) internal view returns (Entry memory) {
        uint256 n;
        if (i == n++) {
            return _e(
                "Hub.setPolicy",
                address(hub),
                abi.encodeCall(hub.setPolicy, (poolA, IHubPolicy(address(hubPolicy)))),
                NOT_MANAGER,
                W | H
            );
        }
        if (i == n++) {
            return _e(
                "Hub.initiateAuthorization",
                address(hub),
                abi.encodeCall(hub.initiateAuthorization, (poolA, abi.encodeCall(hub.setPoolMetadata, (poolA, "x")))),
                NOT_MANAGER,
                H
            );
        }
        if (i == n++) {
            return _e(
                "Hub.cancelAuthorization",
                address(hub),
                abi.encodeCall(hub.cancelAuthorization, (poolA, abi.encodeCall(hub.setPoolMetadata, (poolA, "x")))),
                NOT_MANAGER,
                H
            );
        }
        if (i == n++) {
            return _e(
                "Hub.setAdapters",
                address(hub),
                abi.encodeCall(hub.setAdapters, (poolA, CENTRIFUGE_ID, new IAdapter[](0), new bytes32[](0), 0, REFUND)),
                NOT_MANAGER,
                H
            );
        }
        if (i == n++) {
            return _e(
                "Hub.setBridgingHook",
                address(hub),
                abi.encodeCall(hub.setBridgingHook, (poolA, address(0))),
                NOT_MANAGER,
                H
            );
        }
        if (i == n++) {
            return _e(
                "Hub.setSnapshotHook",
                address(hub),
                abi.encodeCall(hub.setSnapshotHook, (poolA, ISnapshotHook(address(0)))),
                NOT_MANAGER,
                H
            );
        }
        if (i == n++) {
            return
                _e(
                    "Hub.setPoolMetadata",
                    address(hub),
                    abi.encodeCall(hub.setPoolMetadata, (poolA, "x")),
                    NOT_MANAGER,
                    H
                );
        }
        if (i == n++) {
            return
                _e(
                    "Hub.updateCurrency",
                    address(hub),
                    abi.encodeCall(hub.updateCurrency, (poolA, USD_ID)),
                    NOT_MANAGER,
                    H
                );
        }
        if (i == n++) {
            return _e(
                "Hub.updateShareClassMetadata",
                address(hub),
                abi.encodeCall(hub.updateShareClassMetadata, (poolA, scA, "Share", "SHR")),
                NOT_MANAGER,
                H
            );
        }
        if (i == n++) {
            return _e(
                "Hub.updateHubManager",
                address(hub),
                abi.encodeCall(hub.updateHubManager, (poolA, c.caller, true)),
                NOT_MANAGER,
                H
            );
        }
        if (i == n++) {
            return _e(
                "Hub.updateManager",
                address(hub),
                abi.encodeCall(
                    hub.updateManager, (poolA, CENTRIFUGE_ID, ManagerKind.Spoke, c.caller.toBytes32(), true, REFUND)
                ),
                NOT_MANAGER,
                H
            );
        }
        if (i == n++) {
            return _e(
                "Hub.setRequestManager",
                address(hub),
                abi.encodeCall(
                    hub.setRequestManager,
                    (
                        poolA,
                        CENTRIFUGE_ID,
                        IHubRequestManager(address(orderBook)),
                        address(vaultRouter).toBytes32(),
                        REFUND
                    )
                ),
                NOT_MANAGER,
                H
            );
        }
        if (i == n++) {
            return _e(
                "Hub.setSpokePolicy",
                address(hub),
                abi.encodeCall(hub.setSpokePolicy, (poolA, CENTRIFUGE_ID, bytes32(0), REFUND)),
                NOT_MANAGER,
                H
            );
        }
        if (i == n++) {
            return _e(
                "Hub.authorizeSpokeCall",
                address(hub),
                abi.encodeCall(hub.authorizeSpokeCall, (poolA, CENTRIFUGE_ID, c.anyBytes, REFUND)),
                NOT_MANAGER,
                H
            );
        }
        if (i == n++) {
            return _e(
                "Hub.unauthorizeSpokeCall",
                address(hub),
                abi.encodeCall(hub.unauthorizeSpokeCall, (poolA, CENTRIFUGE_ID, c.anyBytes, REFUND)),
                NOT_MANAGER,
                H
            );
        }
        if (i == n++) {
            return _e(
                "Hub.addShareClass",
                address(hub),
                abi.encodeCall(hub.addShareClass, (poolA, "Second", "SEC", bytes32(uint256(7)))),
                NOT_MANAGER,
                H
            );
        }
        if (i == n++) {
            return _e(
                "Hub.updateRestriction",
                address(hub),
                abi.encodeCall(hub.updateRestriction, (poolA, scA, CENTRIFUGE_ID, c.memberMsg, 0, REFUND)),
                NOT_MANAGER,
                H
            );
        }
        if (i == n++) {
            return _e(
                "Hub.updateVault",
                address(hub),
                abi.encodeCall(
                    hub.updateVault, (poolA, scA, usdcId, c.vault.toBytes32(), VaultUpdateKind.Unlink, "", 0, REFUND)
                ),
                NOT_MANAGER,
                H
            );
        }
        if (i == n++) {
            return _e(
                "Hub.updateSharePrice",
                address(hub),
                abi.encodeWithSignature(
                    "updateSharePrice(uint64,bytes16,uint128,uint64)", poolA, scA, d18(2, 1), uint64(block.timestamp)
                ),
                NOT_MANAGER,
                H
            );
        }
        if (i == n++) {
            return _e(
                "Hub.createAccount",
                address(hub),
                abi.encodeCall(hub.createAccount, (poolA, AccountId.wrap(9), true)),
                NOT_MANAGER,
                H
            );
        }
        if (i == n++) {
            return _e(
                "Hub.setAccountMetadata",
                address(hub),
                abi.encodeCall(hub.setAccountMetadata, (poolA, ASSET_ACCOUNT, "x")),
                NOT_MANAGER,
                H
            );
        }
        if (i == n++) {
            return _e(
                "Hub.initializeHolding",
                address(hub),
                abi.encodeCall(hub.initializeHolding, (poolA, scA, usdcId, identityValuation, _accounts())),
                NOT_MANAGER,
                H
            );
        }
        if (i == n++) {
            return _e(
                "Hub.updateHoldingValue",
                address(hub),
                abi.encodeCall(hub.updateHoldingValue, (poolA, scA, usdcId)),
                NOT_MANAGER,
                H
            );
        }
        if (i == n++) {
            return _e(
                "Hub.updateHoldingValuation",
                address(hub),
                abi.encodeCall(hub.updateHoldingValuation, (poolA, scA, usdcId, identityValuation)),
                NOT_MANAGER,
                H
            );
        }
        if (i == n++) {
            return _e(
                "Hub.setHoldingAccountId",
                address(hub),
                abi.encodeCall(hub.setHoldingAccountId, (poolA, scA, usdcId, 0, ASSET_ACCOUNT)),
                NOT_MANAGER,
                H
            );
        }
        if (i == n++) {
            return _e(
                "Hub.updateJournal",
                address(hub),
                abi.encodeCall(hub.updateJournal, (poolA, new JournalEntry[](0), new JournalEntry[](0))),
                NOT_MANAGER,
                H
            );
        }
        if (i == n++) {
            return _e(
                "Hub.notifyPool",
                address(hub),
                abi.encodeCall(hub.notifyPool, (poolA, CENTRIFUGE_ID, REFUND)),
                NOT_MANAGER,
                H
            );
        }
        if (i == n++) {
            return _e(
                "Hub.notifyShareClass",
                address(hub),
                abi.encodeCall(
                    hub.notifyShareClass,
                    (poolA, scA, CENTRIFUGE_ID, address(shareTokenRegistrar).toBytes32(), "", 0, REFUND)
                ),
                NOT_MANAGER,
                H
            );
        }
        if (i == n++) {
            return _e(
                "Hub.notifyShareMetadata",
                address(hub),
                abi.encodeCall(hub.notifyShareMetadata, (poolA, scA, CENTRIFUGE_ID, 0, REFUND)),
                NOT_MANAGER,
                H
            );
        }
        if (i == n++) {
            return _e(
                "Hub.notifySharePrice",
                address(hub),
                abi.encodeCall(hub.notifySharePrice, (poolA, scA, CENTRIFUGE_ID, REFUND)),
                NOT_MANAGER,
                H
            );
        }
        if (i == n++) {
            return _e(
                "Hub.notifyAssetPrice",
                address(hub),
                abi.encodeCall(hub.notifyAssetPrice, (poolA, scA, usdcId, REFUND)),
                NOT_MANAGER,
                H
            );
        }
        if (i == n++) {
            return _e(
                "Hub.managerCall",
                address(hub),
                abi.encodeCall(
                    hub.managerCall,
                    (poolA, CENTRIFUGE_ID, address(spokeOracle).toBytes32(), abi.encode(false), 0, 0, REFUND)
                ),
                NOT_MANAGER,
                H
            );
        }
        if (i == n++) {
            return _f(
                "Hub.requestCallback",
                address(hub),
                abi.encodeCall(hub.requestCallback, (poolA, scA, usdcId, "", 0, false, REFUND)),
                NOT_AUTHORIZED,
                F,
                address(orderBook)
            );
        }
        // Hub: ward-gated
        if (i == n++) {
            return _e(
                "Hub.updateAccountingAmount",
                address(hub),
                abi.encodeCall(hub.updateAccountingAmount, (poolA, scA, usdcId, true, 1)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "Hub.updateAccountingValue",
                address(hub),
                abi.encodeCall(hub.updateAccountingValue, (poolA, scA, usdcId, true, 1)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "Hub.file",
                address(hub),
                abi.encodeCall(hub.file, ("sender", address(messageDispatcher))),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "Hub.createPool",
                address(hub),
                abi.encodeCall(hub.createPool, (hubRegistry.poolId(CENTRIFUGE_ID, 9), c.caller, USD_ID)),
                NOT_AUTHORIZED,
                W
            );
        }
        return _none();
    }

    /// @dev HubHandler, HubRegistry, ShareClassManager, Holdings, Accounting (ward-gated)
    function _section1(uint256 i, Ctx memory c) internal view returns (Entry memory) {
        uint256 n;
        if (i == n++) {
            return _e(
                "HubHandler.file",
                address(hubHandler),
                abi.encodeCall(hubHandler.file, ("sender", address(messageDispatcher))),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "HubHandler.registerAsset",
                address(hubHandler),
                abi.encodeCall(hubHandler.registerAsset, (usdcId, 6)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "HubHandler.request",
                address(hubHandler),
                abi.encodeCall(hubHandler.request, (poolA, scA, usdcId, c.anyBytes)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "HubHandler.updateAssets",
                address(hubHandler),
                abi.encodeCall(hubHandler.updateAssets, (CENTRIFUGE_ID, poolA, scA, usdcId, 1, true, false, 0)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "HubHandler.updateShares",
                address(hubHandler),
                abi.encodeCall(hubHandler.updateShares, (CENTRIFUGE_ID, poolA, scA, 1, true, false, 0)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "HubHandler.initiateTransferShares",
                address(hubHandler),
                abi.encodeCall(
                    hubHandler.initiateTransferShares,
                    (CENTRIFUGE_ID, CENTRIFUGE_ID, poolA, scA, c.caller.toBytes32(), c.caller.toBytes32(), 1, 0, REFUND)
                ),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "HubRegistry.registerAsset",
                address(hubRegistry),
                abi.encodeCall(hubRegistry.registerAsset, (usdcId, 6)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "HubRegistry.registerPool",
                address(hubRegistry),
                abi.encodeCall(hubRegistry.registerPool, (hubRegistry.poolId(CENTRIFUGE_ID, 9), c.caller, USD_ID)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "HubRegistry.updateManager",
                address(hubRegistry),
                abi.encodeCall(hubRegistry.updateManager, (poolA, c.caller, true)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "HubRegistry.setMetadata",
                address(hubRegistry),
                abi.encodeCall(hubRegistry.setMetadata, (poolA, "x")),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "HubRegistry.updateCurrency",
                address(hubRegistry),
                abi.encodeCall(hubRegistry.updateCurrency, (poolA, USD_ID)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "HubRegistry.setPolicy",
                address(hubRegistry),
                abi.encodeCall(hubRegistry.setPolicy, (poolA, IHubPolicy(address(hubPolicy)))),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "HubRegistry.setHubRequestManager",
                address(hubRegistry),
                abi.encodeCall(hubRegistry.setHubRequestManager, (poolA, CENTRIFUGE_ID, IHubRequestManager(c.caller))),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "HubRegistry.setBridgingHook",
                address(hubRegistry),
                abi.encodeCall(hubRegistry.setBridgingHook, (poolA, IBridgingHook(c.caller))),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "HubRegistry.initiateAuthorization",
                address(hubRegistry),
                abi.encodeCall(hubRegistry.initiateAuthorization, (poolA, FM, c.anyBytes)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "HubRegistry.cancelAuthorization",
                address(hubRegistry),
                abi.encodeCall(hubRegistry.cancelAuthorization, (poolA, FM, c.anyBytes)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _f(
                "HubRegistry.consumeAuthorization",
                address(hubRegistry),
                abi.encodeCall(hubRegistry.consumeAuthorization, (poolA, FM, c.anyBytes, type(uint48).max)),
                CALLER_NOT_POLICY,
                F,
                address(hubRegistry.policy(poolA))
            );
        }
        if (i == n++) {
            return _e(
                "ShareClassManager.addShareClass",
                address(shareClassManager),
                abi.encodeCall(shareClassManager.addShareClass, (poolA, "Second", "SEC", bytes32(uint256(7)))),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "ShareClassManager.updateSharePrice",
                address(shareClassManager),
                abi.encodeCall(shareClassManager.updateSharePrice, (poolA, scA, d18(2, 1), uint64(block.timestamp))),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "ShareClassManager.updateMetadata",
                address(shareClassManager),
                abi.encodeCall(shareClassManager.updateMetadata, (poolA, scA, "Share", "SHR")),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "ShareClassManager.updateShares",
                address(shareClassManager),
                abi.encodeCall(shareClassManager.updateShares, (CENTRIFUGE_ID, poolA, scA, 1, true)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "ShareClassManager.transferShares",
                address(shareClassManager),
                abi.encodeCall(shareClassManager.transferShares, (poolA, scA, CENTRIFUGE_ID, CENTRIFUGE_ID + 1, 1)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "Holdings.initialize",
                address(holdings),
                abi.encodeCall(holdings.initialize, (poolA, scA, usdcId, identityValuation, _accounts())),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "Holdings.setAccountId",
                address(holdings),
                abi.encodeCall(holdings.setAccountId, (poolA, scA, usdcId, 0, ASSET_ACCOUNT)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "Holdings.updateValuation",
                address(holdings),
                abi.encodeCall(holdings.updateValuation, (poolA, scA, usdcId, identityValuation)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "Holdings.setSnapshotHook",
                address(holdings),
                abi.encodeCall(holdings.setSnapshotHook, (poolA, ISnapshotHook(address(0)))),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "Holdings.setSnapshot",
                address(holdings),
                abi.encodeCall(holdings.setSnapshot, (poolA, scA, CENTRIFUGE_ID, true, 1)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "Holdings.callOnSyncSnapshot",
                address(holdings),
                abi.encodeCall(holdings.callOnSyncSnapshot, (poolA, scA, CENTRIFUGE_ID)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "Holdings.callOnTransferSnapshot",
                address(holdings),
                abi.encodeCall(holdings.callOnTransferSnapshot, (poolA, scA, CENTRIFUGE_ID, CENTRIFUGE_ID + 1, 1)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "Holdings.increase",
                address(holdings),
                abi.encodeCall(holdings.increase, (poolA, scA, usdcId, CENTRIFUGE_ID, 1)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "Holdings.decrease",
                address(holdings),
                abi.encodeCall(holdings.decrease, (poolA, scA, usdcId, CENTRIFUGE_ID, 1)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "Holdings.update",
                address(holdings),
                abi.encodeCall(holdings.update, (poolA, scA, usdcId)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return
                _e(
                    "Accounting.unlock",
                    address(accounting),
                    abi.encodeCall(accounting.unlock, (poolA)),
                    NOT_AUTHORIZED,
                    W
                );
        }
        if (i == n++) {
            return _e("Accounting.lock", address(accounting), abi.encodeCall(accounting.lock, ()), NOT_AUTHORIZED, W);
        }
        if (i == n++) {
            return _e(
                "Accounting.createAccount",
                address(accounting),
                abi.encodeCall(accounting.createAccount, (poolA, AccountId.wrap(9), true)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "Accounting.setAccountMetadata",
                address(accounting),
                abi.encodeCall(accounting.setAccountMetadata, (poolA, ASSET_ACCOUNT, "x")),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "Accounting.addDebit",
                address(accounting),
                abi.encodeCall(accounting.addDebit, (ASSET_ACCOUNT, 1)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "Accounting.addCredit",
                address(accounting),
                abi.encodeCall(accounting.addCredit, (ASSET_ACCOUNT, 1)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "Accounting.addJournal",
                address(accounting),
                abi.encodeCall(accounting.addJournal, (new JournalEntry[](0), new JournalEntry[](0))),
                NOT_AUTHORIZED,
                W
            );
        }
        return _none();
    }

    /// @dev Spoke (balance sheet: NotManager), SpokeRegistry, SpokeHandler, Escrow, SnapshotQueue, Envoy
    function _section2(uint256 i, Ctx memory c) internal view returns (Entry memory) {
        uint256 n;
        if (i == n++) {
            return _e(
                "Spoke.deposit",
                address(spoke),
                abi.encodeCall(spoke.deposit, (poolA, scA, address(usdc), 0, 1)),
                NOT_MANAGER,
                S
            );
        }
        if (i == n++) {
            return _e(
                "Spoke.noteDeposit",
                address(spoke),
                abi.encodeCall(spoke.noteDeposit, (poolA, scA, address(usdc), 0, 1)),
                NOT_MANAGER,
                S
            );
        }
        if (i == n++) {
            return _e(
                "Spoke.withdraw",
                address(spoke),
                abi.encodeCall(spoke.withdraw, (poolA, scA, address(usdc), 0, c.caller, 1)),
                NOT_MANAGER,
                S
            );
        }
        if (i == n++) {
            return _e(
                "Spoke.withdrawReserved",
                address(spoke),
                abi.encodeCall(
                    spoke.withdrawReserved, (poolA, scA, address(usdc), 0, c.caller, 1, c.caller, REASON_STRANGER)
                ),
                NOT_MANAGER,
                S
            );
        }
        if (i == n++) {
            return _e(
                "Spoke.reserve",
                address(spoke),
                abi.encodeCall(spoke.reserve, (poolA, scA, address(usdc), 0, 1, c.caller, REASON_STRANGER)),
                NOT_MANAGER,
                S
            );
        }
        if (i == n++) {
            return _e(
                "Spoke.unreserve",
                address(spoke),
                abi.encodeCall(spoke.unreserve, (poolA, scA, address(usdc), 0, 1, c.caller, REASON_STRANGER)),
                NOT_MANAGER,
                S
            );
        }
        if (i == n++) {
            return _e(
                "Spoke.submitQueuedAssets",
                address(spoke),
                abi.encodeCall(spoke.submitQueuedAssets, (poolA, scA, usdcId, 0, REFUND)),
                NOT_MANAGER,
                S
            );
        }
        if (i == n++) {
            return
                _e(
                    "Spoke.issue",
                    address(spoke),
                    abi.encodeCall(spoke.issue, (poolA, scA, c.caller, 1)),
                    NOT_MANAGER,
                    S
                );
        }
        if (i == n++) {
            return _e("Spoke.revoke", address(spoke), abi.encodeCall(spoke.revoke, (poolA, scA, 1)), NOT_MANAGER, S);
        }
        if (i == n++) {
            return _e(
                "Spoke.withdrawShares",
                address(spoke),
                abi.encodeCall(spoke.withdrawShares, (poolA, scA, c.caller, 1)),
                NOT_MANAGER,
                S
            );
        }
        if (i == n++) {
            return _e(
                "Spoke.submitQueuedShares",
                address(spoke),
                abi.encodeCall(spoke.submitQueuedShares, (poolA, scA, 0, REFUND)),
                NOT_MANAGER,
                S
            );
        }
        if (i == n++) {
            return _e(
                "Spoke.transferSharesFrom",
                address(spoke),
                abi.encodeCall(spoke.transferSharesFrom, (poolA, scA, c.caller, actors[0], c.caller, 1)),
                NOT_MANAGER,
                S
            );
        }
        if (i == n++) {
            return _e(
                "Spoke.file",
                address(spoke),
                abi.encodeCall(spoke.file, ("sender", address(messageDispatcher))),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            // Moving another holder's shares across chains: the owner or a ward only
            return _f(
                "Spoke.crosschainTransferShares",
                address(spoke),
                abi.encodeWithSignature(
                    "crosschainTransferShares(uint16,uint64,bytes16,bytes32,address,address,uint128,uint128,uint128,address)",
                    CENTRIFUGE_ID + 1,
                    poolA,
                    scA,
                    c.caller.toBytes32(),
                    c.caller,
                    actors[0],
                    uint128(1),
                    uint128(0),
                    uint128(0),
                    REFUND
                ),
                NOT_AUTHORIZED,
                W | F,
                actors[0]
            );
        }
        if (i == n++) {
            return _f(
                "Spoke.request",
                address(spoke),
                abi.encodeCall(spoke.request, (poolA, scA, usdcId, c.anyBytes, 0, false, REFUND)),
                NOT_AUTHORIZED,
                F,
                c.requestManager
            );
        }
        if (i == n++) {
            return _e(
                "SpokeRegistry.addPool",
                address(spokeRegistry),
                abi.encodeCall(spokeRegistry.addPool, (hubRegistry.poolId(CENTRIFUGE_ID, 9))),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "SpokeRegistry.addShareClass",
                address(spokeRegistry),
                abi.encodeCall(
                    spokeRegistry.addShareClass, (poolA, scA, address(shareA), IRegistrar(address(shareTokenRegistrar)))
                ),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "SpokeRegistry.linkToken",
                address(spokeRegistry),
                abi.encodeCall(
                    spokeRegistry.linkToken, (poolA, scA, c.caller, IRegistrar(address(shareTokenRegistrar)))
                ),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "SpokeRegistry.setRequestManager",
                address(spokeRegistry),
                abi.encodeCall(spokeRegistry.setRequestManager, (poolA, ISpokeRequestManager(c.caller))),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "SpokeRegistry.updateManager",
                address(spokeRegistry),
                abi.encodeCall(spokeRegistry.updateManager, (poolA, c.caller, true)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "SpokeRegistry.updateBridger",
                address(spokeRegistry),
                abi.encodeCall(spokeRegistry.updateBridger, (poolA, c.caller, true)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "SpokeRegistry.setPolicy",
                address(spokeRegistry),
                abi.encodeCall(spokeRegistry.setPolicy, (poolA, IPolicy(c.caller))),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "SpokeRegistry.authorize",
                address(spokeRegistry),
                abi.encodeCall(spokeRegistry.authorize, (poolA, c.anyBytes)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "SpokeRegistry.unauthorize",
                address(spokeRegistry),
                abi.encodeCall(spokeRegistry.unauthorize, (poolA, c.anyBytes)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _f(
                "SpokeRegistry.consumeAuthorization",
                address(spokeRegistry),
                abi.encodeCall(spokeRegistry.consumeAuthorization, (poolA, FM, c.anyBytes)),
                CALLER_NOT_POLICY,
                F,
                address(spokeRegistry.policy(poolA))
            );
        }
        if (i == n++) {
            return _e(
                "SpokeRegistry.registerVault",
                address(spokeRegistry),
                abi.encodeCall(
                    spokeRegistry.registerVault,
                    (poolA, scA, usdcId, address(usdc), 0, IVaultFactory(address(vaultFactory)), c.vault, "")
                ),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "SpokeRegistry.linkVault",
                address(spokeRegistry),
                abi.encodeCall(spokeRegistry.linkVault, (poolA, scA, usdcId, c.vault)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "SpokeRegistry.unlinkVault",
                address(spokeRegistry),
                abi.encodeCall(spokeRegistry.unlinkVault, (poolA, scA, usdcId, c.vault)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "SpokeRegistry.createAssetId",
                address(spokeRegistry),
                abi.encodeCall(spokeRegistry.createAssetId, (CENTRIFUGE_ID, c.caller, 0)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "SpokeRegistry.updatePricePoolPerShare",
                address(spokeRegistry),
                abi.encodeCall(spokeRegistry.updatePricePoolPerShare, (poolA, scA, d18(2, 1), uint64(block.timestamp))),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "SpokeRegistry.updatePricePoolPerAsset",
                address(spokeRegistry),
                abi.encodeCall(
                    spokeRegistry.updatePricePoolPerAsset, (poolA, scA, usdcId, d18(2, 1), uint64(block.timestamp))
                ),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "SpokeHandler.file",
                address(spokeHandler),
                abi.encodeCall(spokeHandler.file, ("escrowFactory", address(escrowFactory))),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "SpokeHandler.addPool",
                address(spokeHandler),
                abi.encodeCall(spokeHandler.addPool, (hubRegistry.poolId(CENTRIFUGE_ID, 9))),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "SpokeHandler.addShareClass",
                address(spokeHandler),
                abi.encodeCall(
                    spokeHandler.addShareClass,
                    (poolA, scA, "Share", "SHR", 18, bytes32(0), IRegistrar(address(shareTokenRegistrar)), "")
                ),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "SpokeHandler.updateShareMetadata",
                address(spokeHandler),
                abi.encodeCall(spokeHandler.updateShareMetadata, (poolA, scA, "Share", "SHR")),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "SpokeHandler.updateRestriction",
                address(spokeHandler),
                abi.encodeCall(spokeHandler.updateRestriction, (poolA, scA, c.memberMsg)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "SpokeHandler.executeTransferShares",
                address(spokeHandler),
                abi.encodeCall(spokeHandler.executeTransferShares, (poolA, scA, c.caller.toBytes32(), 1)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "SpokeHandler.updateVault",
                address(spokeHandler),
                abi.encodeCall(spokeHandler.updateVault, (poolA, scA, usdcId, c.vault, VaultUpdateKind.Unlink, "")),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "SpokeHandler.updateManager",
                address(spokeHandler),
                abi.encodeCall(spokeHandler.updateManager, (poolA, c.caller, true)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "SpokeHandler.updateBridger",
                address(spokeHandler),
                abi.encodeCall(spokeHandler.updateBridger, (poolA, c.caller, true)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "SpokeHandler.setPolicy",
                address(spokeHandler),
                abi.encodeCall(spokeHandler.setPolicy, (poolA, IPolicy(c.caller))),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "SpokeHandler.authorize",
                address(spokeHandler),
                abi.encodeCall(spokeHandler.authorize, (poolA, c.anyBytes)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "SpokeHandler.unauthorize",
                address(spokeHandler),
                abi.encodeCall(spokeHandler.unauthorize, (poolA, c.anyBytes)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "SpokeHandler.updatePricePoolPerShare",
                address(spokeHandler),
                abi.encodeCall(spokeHandler.updatePricePoolPerShare, (poolA, scA, d18(2, 1), uint64(block.timestamp))),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "SpokeHandler.updatePricePoolPerAsset",
                address(spokeHandler),
                abi.encodeCall(
                    spokeHandler.updatePricePoolPerAsset, (poolA, scA, usdcId, d18(2, 1), uint64(block.timestamp))
                ),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "SpokeHandler.setRequestManager",
                address(spokeHandler),
                abi.encodeCall(spokeHandler.setRequestManager, (poolA, ISpokeRequestManager(c.caller))),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "SpokeHandler.requestCallback",
                address(spokeHandler),
                abi.encodeCall(spokeHandler.requestCallback, (poolA, scA, usdcId, c.anyBytes)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "Escrow.deposit",
                address(_escrow(poolA)),
                abi.encodeCall(_escrow(poolA).deposit, (scA, address(usdc), 0, 1)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "Escrow.withdraw",
                address(_escrow(poolA)),
                abi.encodeCall(_escrow(poolA).withdraw, (scA, address(usdc), 0, c.caller, 1)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "Escrow.reserve",
                address(_escrow(poolA)),
                abi.encodeCall(_escrow(poolA).reserve, (scA, address(usdc), 0, 1, c.caller, REASON_STRANGER)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "Escrow.unreserve",
                address(_escrow(poolA)),
                abi.encodeCall(_escrow(poolA).unreserve, (scA, address(usdc), 0, 1, c.caller, REASON_STRANGER)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "Escrow.authTransferTo",
                address(_escrow(poolA)),
                abi.encodeCall(_escrow(poolA).authTransferTo, (address(usdc), 0, c.caller, 1)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "SnapshotQueue.queueAssets",
                address(snapshotQueue),
                abi.encodeCall(snapshotQueue.queueAssets, (poolA, scA, usdcId, 1, true)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "SnapshotQueue.queueShares",
                address(snapshotQueue),
                abi.encodeCall(snapshotQueue.queueShares, (poolA, scA, 1, true)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "SnapshotQueue.flushAssets",
                address(snapshotQueue),
                abi.encodeCall(snapshotQueue.flushAssets, (poolA, scA, usdcId)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "SnapshotQueue.flushShares",
                address(snapshotQueue),
                abi.encodeCall(snapshotQueue.flushShares, (poolA, scA)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "EscrowFactory.newEscrow",
                address(escrowFactory),
                abi.encodeCall(escrowFactory.newEscrow, (hubRegistry.poolId(CENTRIFUGE_ID, 9))),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "EscrowFactory.file",
                address(escrowFactory),
                abi.encodeCall(escrowFactory.file, ("spoke", address(spoke))),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "Envoy.callFromHub",
                c.envoy,
                abi.encodeCall(envoy.callFromHub, (poolA, address(spokeOracle), abi.encode(false))),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "Envoy.callFromSpoke",
                c.envoy,
                abi.encodeCall(
                    envoy.callFromSpoke,
                    (
                        poolA,
                        address(oracleValuation),
                        abi.encode(uint16(0), FEEDER.toBytes32(), true),
                        CENTRIFUGE_ID,
                        bytes32(0)
                    )
                ),
                NOT_AUTHORIZED,
                W
            );
        }
        // The Envoy is every manager's anchor: nothing but the message processors may speak through it.
        // Root's `auth` surface
        if (i == n++) {
            return _e("Root.endorse", address(root), abi.encodeCall(root.endorse, (c.caller)), NOT_AUTHORIZED, W);
        }
        if (i == n++) {
            return _e("Root.veto", address(root), abi.encodeCall(root.veto, (address(spoke))), NOT_AUTHORIZED, W);
        }
        if (i == n++) {
            return _e("Root.pause", address(root), abi.encodeCall(root.pause, ()), NOT_AUTHORIZED, W);
        }
        if (i == n++) {
            return _e("Root.unpause", address(root), abi.encodeCall(root.unpause, ()), NOT_AUTHORIZED, W);
        }
        if (i == n++) {
            return
                _e("Root.scheduleRely", address(root), abi.encodeCall(root.scheduleRely, (c.caller)), NOT_AUTHORIZED, W);
        }
        if (i == n++) {
            return _e("Root.cancelRely", address(root), abi.encodeCall(root.cancelRely, (c.caller)), NOT_AUTHORIZED, W);
        }
        if (i == n++) {
            return _e(
                "Root.relyContract",
                address(root),
                abi.encodeCall(root.relyContract, (address(spoke), c.caller)),
                bytes4(0),
                W
            );
        }
        if (i == n++) {
            return _e(
                "Root.denyContract",
                address(root),
                abi.encodeCall(root.denyContract, (address(spoke), address(messageDispatcher))),
                bytes4(0),
                W
            );
        }
        if (i == n++) {
            return _e("Root.file", address(root), abi.encodeCall(root.file, ("delay", 0)), NOT_AUTHORIZED, W);
        }
        // `rely`/`deny` on whichever warded contract the c.salt picks
        if (i == n++) {
            address target = _warded(c.salt);
            return _e("rely", target, abi.encodeCall(root.rely, (c.caller)), NOT_AUTHORIZED, W);
        }
        if (i == n++) {
            address target = _warded(c.salt);
            return _e("deny", target, abi.encodeCall(root.deny, (address(this))), NOT_AUTHORIZED, W);
        }
        return _none();
    }

    /// @dev Share token, registrar and hook
    function _section3(uint256 i, Ctx memory c) internal view returns (Entry memory) {
        uint256 n;
        if (i == n++) {
            return _e(
                "ShareTokenRegistrar.file",
                address(shareTokenRegistrar),
                abi.encodeCall(shareTokenRegistrar.file, ("envoy", c.caller)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "ShareTokenRegistrar.newToken",
                address(shareTokenRegistrar),
                abi.encodeCall(shareTokenRegistrar.newToken, ("Share", "SHR", 18, bytes32(uint256(5)), "")),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "ShareTokenRegistrar.mint",
                address(shareTokenRegistrar),
                abi.encodeCall(shareTokenRegistrar.mint, (address(shareA), c.caller, 1)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "ShareTokenRegistrar.burn",
                address(shareTokenRegistrar),
                abi.encodeCall(shareTokenRegistrar.burn, (address(shareA), actors[0], 1)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "ShareTokenRegistrar.authTransferFrom",
                address(shareTokenRegistrar),
                abi.encodeCall(
                    shareTokenRegistrar.authTransferFrom, (address(shareA), c.caller, actors[0], c.caller, 1)
                ),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "ShareTokenRegistrar.updateMetadata",
                address(shareTokenRegistrar),
                abi.encodeCall(shareTokenRegistrar.updateMetadata, (address(shareA), "Share", "SHR")),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "ShareTokenRegistrar.updateRestriction",
                address(shareTokenRegistrar),
                abi.encodeCall(shareTokenRegistrar.updateRestriction, (address(shareA), c.memberMsg)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _f(
                "ShareTokenRegistrar.fromHub",
                address(shareTokenRegistrar),
                abi.encodeCall(shareTokenRegistrar.fromHub, (poolA, abi.encode(uint8(0), scA))),
                NOT_ENVOY,
                F,
                c.envoy
            );
        }
        if (i == n++) {
            return _e(
                "ShareToken.mint",
                address(shareA),
                abi.encodeWithSignature("mint(address,uint256)", c.caller, uint256(1)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "ShareToken.burn",
                address(shareA),
                abi.encodeWithSignature("burn(address,uint256)", actors[0], uint256(1)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "ShareToken.authTransferFrom",
                address(shareA),
                abi.encodeWithSignature(
                    "authTransferFrom(address,address,address,uint256)", c.caller, actors[0], c.caller, uint256(1)
                ),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "ShareToken.file(address)",
                address(shareA),
                abi.encodeWithSignature("file(bytes32,address)", bytes32("hook"), c.caller),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "ShareToken.file(string)",
                address(shareA),
                abi.encodeWithSignature("file(bytes32,string)", bytes32("name"), "Share"),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "ShareToken.updateVault",
                address(shareA),
                abi.encodeWithSignature("updateVault(address,address)", address(usdc), c.caller),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _f(
                "ShareToken.setHookData",
                address(shareA),
                abi.encodeWithSignature("setHookData(address,bytes16)", c.caller, bytes16(type(uint128).max)),
                NOT_AUTH_OR_HOOK,
                W | F,
                address(fullRestrictions)
            );
        }
        if (i == n++) {
            return _e(
                "ShareTokenHook.updateRestriction",
                address(fullRestrictions),
                abi.encodeCall(fullRestrictions.updateRestriction, (address(shareA), c.memberMsg)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _f(
                "ShareTokenHook.freeze",
                address(fullRestrictions),
                abi.encodeCall(fullRestrictions.freeze, (address(shareA), actors[0])),
                NOT_AUTHORIZED,
                W | K,
                address(shareA)
            );
        }
        if (i == n++) {
            return _f(
                "ShareTokenHook.unfreeze",
                address(fullRestrictions),
                abi.encodeCall(fullRestrictions.unfreeze, (address(shareA), actors[0])),
                NOT_AUTHORIZED,
                W | K,
                address(shareA)
            );
        }
        if (i == n++) {
            return _f(
                "ShareTokenHook.updateMember",
                address(fullRestrictions),
                abi.encodeCall(fullRestrictions.updateMember, (address(shareA), c.caller, type(uint64).max)),
                NOT_AUTHORIZED,
                W | K,
                address(shareA)
            );
        }
        if (i == n++) {
            return _f(
                "ShareTokenHook.fromHub",
                address(fullRestrictions),
                abi.encodeCall(
                    fullRestrictions.fromHub,
                    (poolA, abi.encode(bytes16(scA.raw()), uint8(0), c.caller.toBytes32(), true))
                ),
                NOT_ENVOY,
                F,
                c.envoy
            );
        }
        return _none();
    }

    /// @dev Vault Development Kit: vault callbacks, OrderBook, FeeRequestManager, routers, routes, policies
    function _section4(uint256 i, Ctx memory c) internal view returns (Entry memory) {
        uint256 n;
        if (i == n++) {
            return _f(
                "Vault.approveDeposits",
                c.vault,
                abi.encodeCall(vaults[0].approveDeposits, (1, 1)),
                NOT_AUTHORIZED,
                F,
                c.requestManager
            );
        }
        if (i == n++) {
            return _f(
                "Vault.issueShares",
                c.vault,
                abi.encodeCall(vaults[0].issueShares, (1, 1)),
                NOT_AUTHORIZED,
                F,
                c.requestManager
            );
        }
        if (i == n++) {
            return _f(
                "Vault.fulfillDepositRequest",
                c.vault,
                abi.encodeCall(vaults[0].fulfillDepositRequest, (1, 1, 1)),
                NOT_AUTHORIZED,
                F,
                c.requestManager
            );
        }
        if (i == n++) {
            return _f(
                "Vault.cancelDeposit",
                c.vault,
                abi.encodeCall(vaults[0].cancelDeposit, (1, 1, 1)),
                NOT_AUTHORIZED,
                F,
                c.requestManager
            );
        }
        if (i == n++) {
            return _f(
                "Vault.revokeShares",
                c.vault,
                abi.encodeCall(vaults[0].revokeShares, (1, 1, 1)),
                NOT_AUTHORIZED,
                F,
                c.requestManager
            );
        }
        if (i == n++) {
            return _f(
                "Vault.fulfillRedeemRequest",
                c.vault,
                abi.encodeCall(vaults[0].fulfillRedeemRequest, (1, 1, 1)),
                NOT_AUTHORIZED,
                F,
                c.requestManager
            );
        }
        if (i == n++) {
            return _f(
                "Vault.cancelRedeem",
                c.vault,
                abi.encodeCall(vaults[0].cancelRedeem, (1, 1, 1)),
                NOT_AUTHORIZED,
                F,
                c.requestManager
            );
        }
        if (i == n++) {
            return _e(
                "OrderBook.request",
                address(orderBook),
                abi.encodeCall(
                    orderBook.request, (poolA, scA, usdcId, abi.encodePacked(uint8(1), bytes32(0), uint128(1)))
                ),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _f(
                "OrderBook.fromHub",
                address(orderBook),
                abi.encodeCall(orderBook.fromHub, (poolA, abi.encode(uint8(2), address(0)))),
                NOT_ENVOY,
                F,
                c.envoy
            );
        }
        if (i == n++) {
            Fulfillment memory f;
            f.scId = scA;
            f.assetId = usdcId;
            f.fill = 1;
            f.refund = REFUND;
            return _e(
                "OrderBook.fulfillCallback",
                address(orderBook),
                abi.encodeCall(orderBook.fulfillCallback, (poolA, f)),
                CALLBACK_LOCKED,
                0
            );
        }
        if (i == n++) {
            return _e(
                "FeeRequestManager.fulfill",
                address(feeRequestManager),
                abi.encodeCall(feeRequestManager.fulfill, (poolA, scA, usdcId, RequestId.wrap(1), true, 1, 0, REFUND)),
                NOT_MANAGER,
                H
            );
        }
        if (i == n++) {
            return _e(
                "FeeRequestManager.cancel",
                address(feeRequestManager),
                abi.encodeCall(feeRequestManager.cancel, (poolA, scA, usdcId, RequestId.wrap(1), true, 1, 0, REFUND)),
                NOT_MANAGER,
                H
            );
        }
        if (i == n++) {
            return _f(
                "FeeRequestManager.fromHub",
                address(feeRequestManager),
                abi.encodeCall(feeRequestManager.fromHub, (poolA, abi.encode(uint8(0), usdcId, uint16(1)))),
                NOT_ENVOY,
                F,
                c.envoy
            );
        }
        if (i == n++) {
            return _e(
                "VaultRequestRouter.callback",
                address(vaultRouter),
                abi.encodeCall(vaultRouter.callback, (poolA, scA, usdcId, c.anyBytes)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _f(
                "VaultRequestRouter.fromHub",
                address(vaultRouter),
                abi.encodeCall(vaultRouter.fromHub, (poolA, abi.encode(uint128(0)))),
                NOT_ENVOY,
                F,
                c.envoy
            );
        }
        if (i == n++) {
            return _e(
                "VaultRequestRouter.sendDepositRequest",
                address(vaultRouter),
                abi.encodeCall(vaultRouter.sendDepositRequest, (1, 1)),
                NOT_LINKED,
                L
            );
        }
        if (i == n++) {
            return _e(
                "VaultRequestRouter.sendRedeemRequest",
                address(vaultRouter),
                abi.encodeCall(vaultRouter.sendRedeemRequest, (1, 1)),
                NOT_LINKED,
                L
            );
        }
        if (i == n++) {
            return _f(
                "VaultRouter.requestDeposit",
                address(investorRouter),
                abi.encodeCall(investorRouter.requestDeposit, (vaults[0], 1, c.caller, actors[0])),
                INVALID_OWNER,
                F,
                actors[0]
            );
        }
        if (i == n++) {
            return _f(
                "VaultRouter.requestDeposit for another controller",
                address(investorRouter),
                abi.encodeCall(investorRouter.requestDeposit, (vaults[0], 1, actors[0], c.caller)),
                INVALID_CONTROLLER,
                F,
                actors[0]
            );
        }
        if (i == n++) {
            return _f(
                "VaultRouter.requestRedeem",
                address(investorRouter),
                abi.encodeCall(investorRouter.requestRedeem, (vaults[0], 1, c.caller, actors[0])),
                INVALID_OWNER,
                F,
                actors[0]
            );
        }
        if (i == n++) {
            return _f(
                "VaultRouter.requestRedeem for another controller",
                address(investorRouter),
                abi.encodeCall(investorRouter.requestRedeem, (vaults[0], 1, actors[0], c.caller)),
                INVALID_CONTROLLER,
                F,
                actors[0]
            );
        }
        if (i == n++) {
            return _f(
                "VaultRouter.deposit",
                address(investorRouter),
                abi.encodeCall(investorRouter.deposit, (vaults[0], 1, actors[0], actors[0])),
                INVALID_OWNER,
                F,
                actors[0]
            );
        }
        if (i == n++) {
            return _f(
                "VaultLiquidityRoute.fromHub",
                address(vaultRoute),
                abi.encodeCall(
                    vaultRoute.fromHub,
                    (
                        poolA,
                        abi.encode(
                            IVaultLiquidityRoute.ConfigKind.Consent,
                            address(vaultC),
                            abi.encode(address(vaults[2]), true)
                        )
                    )
                ),
                NOT_ENVOY,
                F,
                c.envoy
            );
        }
        if (i == n++) {
            return _f(
                "VaultLiquidityRoute.provide",
                address(vaultRoute),
                abi.encodeCall(vaultRoute.provide, (address(vaults[2]), 1)),
                NOT_VAULT,
                F,
                address(vaults[2])
            );
        }
        if (i == n++) {
            return _f(
                "BasinLiquidityRoute.fromHub",
                address(basinRoute),
                abi.encodeCall(basinRoute.fromHub, (poolA, abi.encode(address(vaults[3]), uint128(1)))),
                NOT_ENVOY,
                F,
                c.envoy
            );
        }
        if (i == n++) {
            return _f(
                "BasinLiquidityRoute.setCredit",
                address(basinRoute),
                abi.encodeCall(basinRoute.setCredit, (address(vaults[3]), type(uint128).max)),
                NOT_LP,
                F,
                LP
            );
        }
        if (i == n++) {
            return _f(
                "BasinLiquidityRoute.provide",
                address(basinRoute),
                abi.encodeCall(basinRoute.provide, (address(vaults[3]), 1)),
                NOT_VAULT,
                F,
                address(vaults[3])
            );
        }
        if (i == n++) {
            return _e(
                "BasinLiquidityRoute.repay",
                address(basinRoute),
                abi.encodeCall(basinRoute.repay, (address(vaults[3]), 1)),
                NOT_MANAGER,
                S
            );
        }
        if (i == n++) {
            return _f(
                "ReserveInstantPolicy.fromHub",
                address(reserveInstantPolicy),
                abi.encodeCall(reserveInstantPolicy.fromHub, (poolA, abi.encode(uint8(0), c.vault, c.anyBytes))),
                NOT_ENVOY,
                F,
                c.envoy
            );
        }
        if (i == n++) {
            return _f(
                "SpokeOracle.fromHub",
                address(spokeOracle),
                abi.encodeCall(spokeOracle.fromHub, (poolA, abi.encode(false))),
                NOT_ENVOY,
                F,
                c.envoy
            );
        }
        if (i == n++) {
            return
                _e(
                    "SpokeOracle.pause",
                    address(spokeOracle),
                    abi.encodeCall(spokeOracle.pause, (poolA)),
                    NOT_MANAGER,
                    S
                );
        }
        if (i == n++) {
            return _f(
                "OracleValuation.fromHub",
                address(oracleValuation),
                abi.encodeCall(oracleValuation.fromHub, (poolA, abi.encode(uint16(0), c.caller.toBytes32(), true))),
                NOT_ENVOY,
                F,
                c.envoy
            );
        }
        if (i == n++) {
            return _f(
                "OracleValuation.fromSpoke",
                address(oracleValuation),
                abi.encodeCall(
                    oracleValuation.fromSpoke,
                    (poolA, abi.encode(scA, usdcId, d18(2, 1)), CENTRIFUGE_ID, c.caller.toBytes32())
                ),
                NOT_ENVOY,
                F,
                c.envoy
            );
        }
        if (i == n++) {
            return _e(
                "OracleValuation.setPrice",
                address(oracleValuation),
                abi.encodeCall(oracleValuation.setPrice, (poolA, scA, usdcId, d18(2, 1))),
                NOT_FEEDER,
                P
            );
        }
        if (i == n++) {
            return _f(
                "AccountingToken.fromHub",
                address(accountingToken),
                abi.encodeCall(accountingToken.fromHub, (poolA, abi.encode(c.caller.toBytes32(), true))),
                NOT_ENVOY,
                F,
                c.envoy
            );
        }
        if (i == n++) {
            return _e(
                "AccountingToken.mint",
                address(accountingToken),
                abi.encodeCall(accountingToken.mint, (c.caller, _basinLiabilityTokenId(), 1, scA)),
                NOT_MINTER,
                M
            );
        }
        if (i == n++) {
            return _e(
                "AccountingToken.burn",
                address(accountingToken),
                abi.encodeCall(accountingToken.burn, (address(_escrow(poolA)), _basinLiabilityTokenId(), 1, scA)),
                NOT_MINTER,
                M
            );
        }
        if (i == n++) {
            return _e(
                "SubsidyManager.withdraw",
                address(subsidyManager),
                abi.encodeCall(subsidyManager.withdraw, (poolA, c.caller, 1)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "SubsidyManager.withdrawAll",
                address(subsidyManager),
                abi.encodeCall(subsidyManager.withdrawAll, (poolA, c.caller)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _e(
                "SubsidyManager.file",
                address(subsidyManager),
                abi.encodeCall(subsidyManager.file, ("envoy", c.caller)),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _f(
                "SubsidyManager.fromHub",
                address(subsidyManager),
                abi.encodeCall(subsidyManager.fromHub, (poolA, abi.encode(c.caller.toBytes32(), uint256(1)))),
                NOT_ENVOY,
                F,
                c.envoy
            );
        }
        if (i == n++) {
            return _e(
                "RefundEscrowFactory.newEscrow",
                address(refundEscrowFactory),
                abi.encodeCall(refundEscrowFactory.newEscrow, (hubRegistry.poolId(CENTRIFUGE_ID, 9))),
                NOT_AUTHORIZED,
                W
            );
        }
        if (i == n++) {
            return _f(
                "StdHubPolicy.enforce",
                address(hubPolicy),
                abi.encodeCall(hubPolicy.enforce, (poolA, c.caller, abi.encodeCall(hub.setPoolMetadata, (poolA, "x")))),
                NOT_ENFORCER,
                F,
                address(hub)
            );
        }
        return _none();
    }

    /// @dev The warded contracts `rely`/`deny` are swept over.
    function _warded(uint256 salt) internal view returns (address) {
        address[24] memory w = [
            address(root),
            address(gateway),
            address(multiAdapter),
            address(envoy),
            address(messageProcessor),
            address(messageDispatcher),
            address(shareTokenRegistrar),
            address(escrowFactory),
            address(spokeRegistry),
            address(snapshotQueue),
            address(spoke),
            address(spokeHandler),
            address(hubRegistry),
            address(accounting),
            address(holdings),
            address(shareClassManager),
            address(hub),
            address(hubHandler),
            address(orderBook),
            address(vaultFactory),
            address(vaultRouter),
            address(_escrow(poolA)),
            address(shareA),
            address(subsidyManager)
        ];
        return w[salt % w.length];
    }

    bytes32 internal constant REASON_STRANGER = keccak256("stranger");
}
