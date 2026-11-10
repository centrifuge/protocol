// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AmpleEscrow, IsContract, MockERC20, MockShareToken} from "./Vault.t.sol";

import {D18} from "../../src/misc/types/D18.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {ISpoke} from "../../src/core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../src/core/types/AssetId.sol";
import {ISpokeRegistry, VaultDetails} from "../../src/core/spoke/interfaces/ISpokeRegistry.sol";

import {
    IVaultRequestManager,
    IVaultDepositCallbacks,
    IVaultRedeemCallbacks
} from "../../src/vaults/messaging/interfaces/IVaultRequestManager.sol";

import {Vault} from "../../src/vaults/Vault.sol";
import {PerRequestPolicy} from "../../src/vaults/policies/RequestPolicies.sol";
import {IVaultOracle} from "../../src/vaults/oracles/interfaces/IVaultOracle.sol";
import {IAsyncVault, IVaultErrors, VaultConfig, VaultPlugins} from "../../src/vaults/interfaces/IAsyncVault.sol";
import {
    IInstantPolicy,
    IRequestPolicy,
    ILiquidityRoute,
    ISettlementObserver,
    Settlement
} from "../../src/vaults/policies/interfaces/IVaultPlugins.sol";

import "forge-std/Test.sol";

import {IShareToken} from "../../src/token/interfaces/IShareToken.sol";
import {IRoleHook, Role, RoleCheck, Effect} from "../../src/token/interfaces/IRoleHook.sol";

/// @dev Records what the vault tells it, so a test can inspect the amount a restriction is vetted on
///      rather than only whether the call was made.
contract RecordingHook is IRoleHook {
    uint256 public lastAmount;
    uint256 public lastAssets;
    Role public lastRole;
    uint256 public calls;

    function onRoles(address, RoleCheck[] calldata checks) external returns (bytes4) {
        lastAmount = checks[checks.length - 1].shares;
        lastAssets = checks[checks.length - 1].assets;
        lastRole = checks[checks.length - 1].role;
        calls++;
        return IRoleHook.onRoles.selector;
    }

    function checkRoles(address, RoleCheck[] calldata) external pure returns (bool) {
        return true;
    }

    function maxAllowed(address, RoleCheck[] calldata) external pure returns (uint256, uint256) {
        return (type(uint256).max, type(uint256).max);
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}

/// @dev The promises this stack deliberately does not make. Each test here pins an `n` row of
///      SPECIFICATION.md: the row says the property does not hold, and the test says what happens
///      instead, so a change in the behaviour shows up as a failure rather than as a silently
///      outdated document.
contract VaultNonGuaranteesTest is Test {
    PoolId constant POOL = PoolId.wrap(1);
    ShareClassId constant SC = ShareClassId.wrap(bytes16("sc1"));
    AssetId immutable ASSET_ID = newAssetId(0, 1);

    D18 constant ONE = D18.wrap(1e18);

    address spoke = address(new IsContract());
    address spokeRegistry = address(new IsContract());
    address router = address(new IsContract());
    address oracle = address(new IsContract());
    address escrow = address(new AmpleEscrow());

    MockERC20 asset = new MockERC20(6);
    MockShareToken share = new MockShareToken(18);
    PerRequestPolicy requestPolicy = new PerRequestPolicy(true);
    RecordingHook hook = new RecordingHook();

    Vault vault;
    IAsyncVault v;

    address controller = makeAddr("controller");
    address receiver = makeAddr("receiver");

    function setUp() public {
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.escrow.selector), abi.encode(escrow));

        vault = _deployVault();
        v = IAsyncVault(address(vault));

        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.vaultDetails.selector),
            abi.encode(VaultDetails(POOL, SC, ASSET_ID, address(asset), uint256(0), true))
        );
        vm.mockCall(spokeRegistry, abi.encodeWithSelector(ISpokeRegistry.requestManager.selector), abi.encode(router));
        vm.mockCall(oracle, abi.encodeWithSelector(IVaultOracle.prices.selector), abi.encode(ONE, ONE, true));
        vm.mockCall(router, abi.encodeWithSelector(IVaultRequestManager.sendDepositRequest.selector), "");
        vm.mockCall(router, abi.encodeWithSelector(IVaultRequestManager.sendRedeemRequest.selector), "");

        bytes4[9] memory voids = [
            ISpoke.noteDeposit.selector,
            ISpoke.reserve.selector,
            ISpoke.unreserve.selector,
            ISpoke.issue.selector,
            ISpoke.revoke.selector,
            ISpoke.withdraw.selector,
            ISpoke.withdrawReserved.selector,
            ISpoke.withdrawShares.selector,
            ISpoke.transferSharesFrom.selector
        ];
        for (uint256 i; i < voids.length; i++) {
            vm.mockCall(spoke, abi.encodeWithSelector(voids[i]), "");
        }
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.availableBalanceOf.selector), abi.encode(uint128(1_000_000e6)));
        share.setHook(address(hook));
    }

    function _deployVault() internal returns (Vault) {
        return new Vault(
            POOL,
            SC,
            address(asset),
            ASSET_ID,
            IShareToken(address(share)),
            VaultConfig({
                foldHorizon: 0,
                spoke: ISpoke(spoke),
                spokeRegistry: ISpokeRegistry(spokeRegistry),
                plugins: VaultPlugins({
                    oracle: IVaultOracle(oracle),
                    instantPolicy: IInstantPolicy(address(0)),
                    requestPolicy: IRequestPolicy(address(requestPolicy)),
                    liquidityRoute: ILiquidityRoute(address(0)),
                    settlementObserver: ISettlementObserver(address(0))
                })
            })
        );
    }

    /// @dev Formerly an `n` row, now held: a cancelled deposit is refunded in assets with no shares
    ///      behind them, kept apart from the redeem fills, so it cannot bend the share figure a
    ///      restriction is vetted on. `withdraw` takes the refund first and vets only the filled part.
    function testRedeemRestrictionIsVettedOnTheFilledShares() public {
        vm.prank(controller);
        v.requestRedeem(1_000e18, controller, controller);
        vm.startPrank(router);
        IVaultRedeemCallbacks(address(vault)).revokeShares(1, 1_000e6, 1_000e18);
        IVaultRedeemCallbacks(address(vault)).fulfillRedeemRequest(1, 1_000e6, 1_000e18);
        vm.stopPrank();

        vm.prank(controller);
        v.requestDeposit(1_000e6, controller, controller);
        vm.prank(router);
        IVaultDepositCallbacks(address(vault)).cancelDeposit(2, 1_000e6, 1_000e6);

        vm.prank(controller);
        v.withdraw(1_500e6, receiver, controller);
        assertEq(hook.lastAmount(), 500e18, "the refund carries no shares; the fill part is vetted exactly");
        assertEq(hook.lastAssets(), 1_500e6, "the payout is all the receiver gets, the refund included");
    }

    /// @dev A refund paid to another receiver is a payout of the whole refund, though no shares stand behind it, so a
    ///      hook that limits payouts sees what leaves.
    function testARefundToAnotherReceiverIsVettedOnTheAssetsPaid() public {
        vm.prank(controller);
        v.requestDeposit(1_000e6, controller, controller);
        vm.prank(router);
        IVaultDepositCallbacks(address(vault)).cancelDeposit(1, 1_000e6, 1_000e6);

        vm.prank(controller);
        v.withdraw(1_000e6, receiver, controller);
        assertEq(uint8(hook.lastRole()), uint8(Role.Payout), "a payout");
        assertEq(hook.lastAssets(), 1_000e6, "of the whole refund");
        assertEq(hook.lastAmount(), 0, "with no shares behind it");
    }

    function readMaxMint(address vault_) external view returns (uint256) {
        return IAsyncVault(vault_).maxMint(controller);
    }

    /// @dev `n`: "A faulty settlement observer cannot block a settlement". `_observe` calls the
    ///      observer with no gas cap and no try/catch, so a revert there fails the whole hub callback
    ///      — deliberately, because blocking is the capability an observer that is the product (a
    ///      compliance register) exists to have. The cost is that it runs on the inbound path, after
    ///      the sibling balance-sheet callbacks have already landed, and a deterministic revert never
    ///      clears: the shares stay issued and the pending stays retired with nothing claimable
    ///      against them. A best-effort observer therefore has to guard its own downstream calls,
    ///      which is the contract neither shipped observer states.
    function testARevertingObserverFailsTheWholeSettlement() public {
        Vault blocked = _deployVaultWithObserver(address(new RevertingObserver()));
        IAsyncVault b = IAsyncVault(address(blocked));

        vm.prank(controller);
        uint96 localId = uint96(b.requestDeposit(1_000e6, controller, controller));

        // The balance-sheet legs land on their own.
        vm.startPrank(router);
        IVaultDepositCallbacks(address(blocked)).approveDeposits(localId, 1_000e6);
        IVaultDepositCallbacks(address(blocked)).issueShares(localId, 1_000e18);

        // The one that credits the claim does not, and no retry of it ever will.
        vm.expectRevert(RevertingObserver.ObserverFailed.selector);
        IVaultDepositCallbacks(address(blocked)).fulfillDepositRequest(localId, 1_000e6, 1_000e18);
        vm.stopPrank();

        assertEq(b.maxMint(controller), 0, "nothing is claimable against the issued shares");
    }

    /// @dev An observer is told once per settlement, not once per step the vault applies it in: a settled deposit is
    ///      one call with the fill, and a cancellation one with its gross and net.
    function testAnObserverSeesEachSettlementOnce() public {
        RecordingObserver observer = new RecordingObserver();
        Vault observed = _deployVaultWithObserver(address(observer));
        IAsyncVault o = IAsyncVault(address(observed));

        vm.startPrank(controller);
        uint96 settled = uint96(o.requestDeposit(1_000e6, controller, controller));
        uint96 cancelled = uint96(o.requestDeposit(500e6, controller, controller));
        vm.stopPrank();

        vm.startPrank(router);
        IVaultDepositCallbacks(address(observed)).approveDeposits(settled, 1_000e6);
        IVaultDepositCallbacks(address(observed)).issueShares(settled, 1_000e18);
        IVaultDepositCallbacks(address(observed)).fulfillDepositRequest(settled, 1_000e6, 1_000e18);
        IVaultDepositCallbacks(address(observed)).cancelDeposit(cancelled, 500e6, 500e6);
        vm.stopPrank();

        assertEq(observer.count(), 2, "one call for the fill, one for the cancellation");
        (uint128 assets, uint128 shares, uint128 gross, uint128 net) = observer.settlements(0);
        assertEq(assets, 1_000e6, "the fill's assets");
        assertEq(shares, 1_000e18, "and shares, once");
        assertEq(gross + net, 0, "no cancellation");
        assertTrue(observer.isDepositOf(0));
        (assets, shares, gross, net) = observer.settlements(1);
        assertEq(assets + shares, 0, "a cancellation fills nothing");
        assertEq(gross, 500e6);
        assertEq(net, 500e6);
    }

    /// @dev The observer is passed the cancellation's gross and net, so a fee the pool kept on it is visible.
    function testAnObserverSeesARetainedCancellationFee() public {
        RecordingObserver observer = new RecordingObserver();
        Vault observed = _deployVaultWithObserver(address(observer));
        IAsyncVault o = IAsyncVault(address(observed));

        vm.prank(controller);
        uint96 withFee = uint96(o.requestDeposit(500e6, controller, controller));

        vm.prank(router);
        IVaultDepositCallbacks(address(observed)).cancelDeposit(withFee, 500e6, 450e6);

        (,, uint128 gross, uint128 net) = observer.settlements(0);
        assertEq(gross - net, 50e6, "the retained fee");
    }

    function _deployVaultWithObserver(address observer) internal returns (Vault) {
        return new Vault(
            POOL,
            SC,
            address(asset),
            ASSET_ID,
            IShareToken(address(share)),
            VaultConfig({
                foldHorizon: 0,
                spoke: ISpoke(spoke),
                spokeRegistry: ISpokeRegistry(spokeRegistry),
                plugins: VaultPlugins({
                    oracle: IVaultOracle(oracle),
                    instantPolicy: IInstantPolicy(address(0)),
                    requestPolicy: IRequestPolicy(address(requestPolicy)),
                    liquidityRoute: ILiquidityRoute(address(0)),
                    settlementObserver: ISettlementObserver(observer)
                })
            })
        );
    }

    /// @dev `n`: the action hook is called by the vault, not by a trusted router, and the shipped
    ///      hooks accept any caller. That is safe only because they are pure checks; the interface
    ///      permits a stateful hook, and this is the call any such hook has to defend against.
    function testAnyoneCanInvokeTheActionHookDirectly() public {
        uint256 before = hook.calls();

        vm.prank(makeAddr("anyone"));
        RoleCheck[] memory checks = new RoleCheck[](1);
        checks[0] = RoleCheck(Role.Entry, address(0), controller, 0, 0, Effect.Neutral);
        hook.onRoles(address(share), checks);

        assertEq(hook.calls(), before + 1, "a forged role check reaches the hook unchallenged");
    }

    //----------------------------------------------------------------------------------------------
    // Who may write a controller's state
    //----------------------------------------------------------------------------------------------

    /// @dev `n`: "`requestRedeem` requires the caller to be the owner or their operator". ERC-7540
    ///      mandates supporting a redeem request where the shares are taken from a `msg.sender`
    ///      holding an ERC-20 approval over the owner's shares, which is why this side differs from
    ///      the deposit side: the share leg goes out through the token's own allowance check rather
    ///      than through an operator approval the vault knows about.
    function testAnyoneWithAShareAllowanceCanRequestARedeemOfTheOwnersShares() public {
        address spender = makeAddr("spender");

        vm.prank(spender);
        v.requestRedeem(1_000e18, spender, controller);

        assertEq(v.pendingRedeemRequest(0, spender), 1_000e18, "requested against the owner's shares");
    }

    //----------------------------------------------------------------------------------------------
    // Rounding
    //----------------------------------------------------------------------------------------------

    /// @dev Formerly an `n` row, now held: the ledger deducts exactly what it pays. A redeem whose
    ///      pro-rata payout floors to nothing reverts rather than consuming the claim.
    function testRedeemDeductsExactlyWhatItPaysOut() public {
        vm.prank(controller);
        uint96 localId = uint96(v.requestRedeem(3e18, controller, controller));

        vm.startPrank(router);
        IVaultRedeemCallbacks(address(vault)).revokeShares(localId, 1, 3e18);
        IVaultRedeemCallbacks(address(vault)).fulfillRedeemRequest(localId, 1, 3e18);
        vm.stopPrank();

        vm.prank(controller);
        vm.expectRevert(IVaultErrors.ZeroAmount.selector);
        v.redeem(1e18, receiver, controller);

        vm.prank(controller);
        assertEq(v.redeem(3e18, receiver, controller), 1, "the whole balance pays the whole unit");
        assertEq(v.maxWithdraw(controller), 0);
    }
}

/// @dev Records every settlement it is told about.
contract RecordingObserver {
    Settlement[] public settlements;
    bool[] public isDepositOf;

    function onSettle(address, uint256, bool isDeposit, Settlement calldata settlement) external {
        settlements.push(settlement);
        isDepositOf.push(isDeposit);
    }

    function count() external view returns (uint256) {
        return settlements.length;
    }
}

/// @dev Reverts on every settlement, standing in for an observer that has become unable to complete its work: a
///      claw-back whose shares have moved, a register that rejects the party.
contract RevertingObserver {
    error ObserverFailed();

    function onSettle(address, uint256, bool, Settlement calldata) external pure {
        revert ObserverFailed();
    }
}
