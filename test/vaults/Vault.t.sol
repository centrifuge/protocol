// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "../../src/misc/types/D18.sol";
import {IAuth} from "../../src/misc/interfaces/IAuth.sol";
import {IERC7575} from "../../src/misc/interfaces/IERC7575.sol";
import {IERC7540Deposit, IERC7540Redeem, IERC7540Operator} from "../../src/misc/interfaces/IERC7540.sol";
import {IERC8161DepositTransferable, IERC8161RedeemTransferable} from "../../src/misc/interfaces/IERC8161.sol";

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
import {VaultRequestIdLib} from "../../src/vaults/libraries/VaultRequestIdLib.sol";
import {
    IInstantPolicy,
    IRequestPolicy,
    ILiquidityRoute,
    ISettlementObserver
} from "../../src/vaults/policies/interfaces/IVaultPlugins.sol";
import {
    IAsyncVault,
    IVaultErrors,
    IVaultEvents,
    VaultConfig,
    VaultPlugins,
    REASON_REDEEM
} from "../../src/vaults/interfaces/IAsyncVault.sol";

import "forge-std/Test.sol";

import {IShareToken} from "../../src/token/interfaces/IShareToken.sol";
import {ITransferHook} from "../../src/token/interfaces/ITransferHook.sol";
import {IRoleHook, Role, RoleCheck, Effect} from "../../src/token/interfaces/IRoleHook.sol";

// Empty contract so vm.mockCall targets have code (foundry-rs/foundry#10703).
contract IsContract {}

/// @dev The escrow as the mocked-spoke suites need it. Every reservation reads as ample, so a
///      clamped release frees what it is asked, except the vault's own redeem payouts, which read as
///      none owed against an unbounded holding, so a payout reservation is never refused.
contract AmpleEscrow {
    function holding(ShareClassId, address, uint256) external pure returns (uint128, uint128) {
        return (type(uint128).max, 0);
    }

    function reservedBy(ShareClassId, address, bytes32 reason, address, uint256) external pure returns (uint128) {
        return reason == REASON_REDEEM ? 0 : type(uint128).max;
    }
}

contract MockERC20 {
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    /// @dev Transfers are no-ops; only what a route delivers is counted, so the vault can measure it.
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }
}

contract MockShareToken {
    uint8 public decimals;
    uint256 public totalSupply;
    bool public allowed = true;
    address public hook;
    mapping(address => bool) public blocked;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function setHook(address h) external {
        hook = h;
    }

    function setAllowed(bool a) external {
        allowed = a;
    }

    function setTotalSupply(uint256 s) external {
        totalSupply = s;
    }

    function setBlocked(address who, bool b) external {
        blocked[who] = b;
    }

    /// @dev Holders are unbounded unless a test sets a balance, so instant views size by capacity alone.
    mapping(address => uint256) internal _balances;
    mapping(address => bool) internal _balanceSet;

    function setBalance(address who, uint256 amount) external {
        _balances[who] = amount;
        _balanceSet[who] = true;
    }

    function balanceOf(address who) external view returns (uint256) {
        return _balanceSet[who] ? _balances[who] : type(uint128).max;
    }

    function checkTransferRestriction(address, address to, uint256) external view returns (bool) {
        return allowed && !blocked[to];
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }
}

contract VaultTest is Test {
    using VaultRequestIdLib for address;

    PoolId constant POOL = PoolId.wrap(1);
    ShareClassId constant SC = ShareClassId.wrap(bytes16("sc1"));
    AssetId immutable ASSET_ID = newAssetId(0, 1);

    D18 constant ONE = D18.wrap(1e18);
    D18 constant ZERO_PRICE = D18.wrap(0);

    address spoke = address(new IsContract());
    address spokeRegistry = address(new IsContract());
    address actionHook = address(new IsContract());
    address router = address(new IsContract());
    address oracle = address(new IsContract());
    address instantPolicy = address(new IsContract());
    address escrow = address(new AmpleEscrow());

    MockERC20 asset = new MockERC20(6);
    MockShareToken share = new MockShareToken(18);
    PerRequestPolicy requestPolicy = new PerRequestPolicy(true);

    Vault vault;

    address controller = makeAddr("controller");
    address receiver = makeAddr("receiver");
    address operator = makeAddr("operator");

    function setUp() public {
        // The vault derives its escrow from spoke.escrow(poolId) at construction.
        _mock(spoke, abi.encodeWithSelector(ISpoke.escrow.selector), abi.encode(escrow));

        VaultConfig memory config = VaultConfig({
            foldHorizon: 0,
            spoke: ISpoke(spoke),
            spokeRegistry: ISpokeRegistry(spokeRegistry),
            plugins: VaultPlugins({
                oracle: IVaultOracle(oracle),
                instantPolicy: IInstantPolicy(instantPolicy),
                requestPolicy: IRequestPolicy(address(requestPolicy)),
                liquidityRoute: ILiquidityRoute(address(0)),
                settlementObserver: ISettlementObserver(address(0))
            })
        });

        vault = new Vault(POOL, SC, address(asset), ASSET_ID, IShareToken(address(share)), config);

        // Linked, prices 1:1, requests routed through the registered VaultRequestRouter singleton.
        _mock(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.vaultDetails.selector),
            abi.encode(VaultDetails(POOL, SC, ASSET_ID, address(asset), uint256(0), true))
        );
        _mock(spokeRegistry, abi.encodeWithSelector(ISpokeRegistry.requestManager.selector), abi.encode(router));

        // The vault asks its share token's hook the role checks of its actions; by default it allows every check,
        // and the instant policy lets anyone credit a position to another controller.
        share.setHook(actionHook);
        _mock(actionHook, abi.encodeWithSelector(IRoleHook.onRoles.selector), abi.encode(IRoleHook.onRoles.selector));
        _mock(actionHook, abi.encodeWithSelector(IRoleHook.checkRoles.selector), abi.encode(true));
        _mock(
            actionHook,
            abi.encodeWithSelector(IRoleHook.maxAllowed.selector),
            abi.encode(type(uint256).max, type(uint256).max)
        );
        _mock(instantPolicy, abi.encodeWithSelector(IInstantPolicy.canCredit.selector), abi.encode(true));
        _mock(router, abi.encodeWithSelector(IVaultRequestManager.sendDepositRequest.selector), "");
        _mock(router, abi.encodeWithSelector(IVaultRequestManager.sendRedeemRequest.selector), "");
        _mock(oracle, abi.encodeWithSelector(IVaultOracle.prices.selector), abi.encode(ONE, ONE, true));

        // All spoke mutating calls used by the flows return nothing / a balance.
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
            _mock(spoke, abi.encodeWithSelector(voids[i]), "");
        }
        _mock(spoke, abi.encodeWithSelector(ISpoke.availableBalanceOf.selector), abi.encode(uint128(1_000_000e6)));
    }

    // --- helpers ---

    function _mock(address target, bytes memory data, bytes memory ret) internal {
        vm.mockCall(target, data, ret);
    }

    function _requestId(uint96 localId) internal view returns (uint256) {
        return uint256(VaultRequestIdLib.from(address(vault), localId).raw());
    }

    function _fulfillDeposit(uint96 localId, uint128 assets, uint128 shares_) internal {
        // Canonical deposit fulfillment: approve (release) -> issue -> fulfil.
        vm.startPrank(router);
        IVaultDepositCallbacks(address(vault)).approveDeposits(localId, assets);
        IVaultDepositCallbacks(address(vault)).issueShares(localId, shares_);
        IVaultDepositCallbacks(address(vault)).fulfillDepositRequest(localId, assets, shares_);
        vm.stopPrank();
    }

    function _fulfillRedeem(uint96 localId, uint128 assets, uint128 shares_) internal {
        // Canonical redeem fulfillment: revoke (burn + reserve payout) -> fulfil.
        vm.startPrank(router);
        IVaultRedeemCallbacks(address(vault)).revokeShares(localId, assets, shares_);
        IVaultRedeemCallbacks(address(vault)).fulfillRedeemRequest(localId, assets, shares_);
        vm.stopPrank();
    }

    // --- tests ---

    /// @dev A request transfer moves economic exposure, so the hook must see it: the new holder answers to `Entry`
    ///      for the position it takes, from the old holder, so a restriction hook can vet both parties.
    function testRequestTransferIsGatedByTheActionHook() public {
        vm.prank(controller);
        IAsyncVault(address(vault)).requestDeposit(1_000e6, controller, controller);

        address newController = makeAddr("newController");
        // The whole pending request moves from the sender's position to the receiver's, in assets and at the price
        uint128 shares_ = uint128(IAsyncVault(address(vault)).convertToShares(1_000e6));
        RoleCheck[] memory checks = new RoleCheck[](1);
        checks[0] = RoleCheck(Role.Entry, controller, newController, 1_000e6, shares_, Effect.Moves);
        vm.expectCall(actionHook, abi.encodeCall(IRoleHook.onRoles, (address(share), checks)));

        vm.prank(controller);
        IAsyncVault(address(vault)).transferDepositRequest(_requestId(1), controller, newController);
    }

    /// @dev And a hook that refuses blocks the transfer outright.
    function testRequestTransferBlockedByTheActionHook() public {
        vm.prank(controller);
        IAsyncVault(address(vault)).requestDeposit(1_000e6, controller, controller);

        vm.mockCallRevert(actionHook, abi.encodeWithSelector(IRoleHook.onRoles.selector), "blocked");

        vm.prank(controller);
        vm.expectRevert();
        IAsyncVault(address(vault)).transferDepositRequest(_requestId(1), controller, makeAddr("newController"));
    }

    /// @dev ERC-8161: a pending request is now transferable at the contribution level (per-request
    ///      policy). The whole unsettled contribution, and its share of the aggregate pending,
    ///      moves to the new controller.
    function testTransferDepositRequestMovesContribution() public {
        vm.prank(controller);
        IAsyncVault(address(vault)).requestDeposit(1_000e6, controller, controller);
        assertEq(IAsyncVault(address(vault)).pendingDepositRequest(0, controller), 1_000e6);

        address newController = makeAddr("newController");
        // The standard ERC-8161 event carries the sender, not an amount, so the amounts have an event of their own.
        vm.expectEmit(true, true, true, true, address(vault));
        emit IVaultEvents.RequestTransferred(_requestId(1), controller, newController, true, 1_000e6, 1_000e6);
        vm.expectEmit(true, true, true, true, address(vault));
        emit IERC8161DepositTransferable.TransferDepositRequest(_requestId(1), controller, newController, controller);
        vm.prank(controller);
        IAsyncVault(address(vault)).transferDepositRequest(_requestId(1), controller, newController);

        assertEq(IAsyncVault(address(vault)).pendingDepositRequest(0, controller), 0, "sender emptied");
        assertEq(IAsyncVault(address(vault)).pendingDepositRequest(0, newController), 1_000e6, "receiver holds it");
        assertEq(IAsyncVault(address(vault)).contribution(1, controller).amount, 0, "sender contribution moved");
        assertEq(IAsyncVault(address(vault)).contribution(1, newController).amount, 1_000e6, "receiver contribution");

        // The transferee claims the fulfilled request.
        _fulfillDeposit(1, 1_000e6, 1_000e18);
        uint256 maxMint = IAsyncVault(address(vault)).claimableMint(newController);
        assertEq(maxMint, 1_000e18, "transferee eager-folded at fulfillment");
    }

    /// @dev The redeem-side mirror. Only the rejection paths were covered, so a transfer that actually
    ///      moved a redeem request had never run: the shares stay in the escrow and it is the claim on
    ///      them that moves.
    function testTransferRedeemRequestMovesContribution() public {
        vm.prank(controller);
        IAsyncVault(address(vault)).requestRedeem(1_000e18, controller, controller);
        assertEq(IAsyncVault(address(vault)).pendingRedeemRequest(0, controller), 1_000e18);

        address newController = makeAddr("newRedeemController");
        vm.prank(controller);
        IAsyncVault(address(vault)).transferRedeemRequest(_requestId(1), controller, newController);

        assertEq(IAsyncVault(address(vault)).pendingRedeemRequest(0, controller), 0, "sender emptied");
        assertEq(IAsyncVault(address(vault)).pendingRedeemRequest(0, newController), 1_000e18, "receiver holds it");
        assertEq(IAsyncVault(address(vault)).contribution(1, controller).amount, 0, "sender contribution moved");
        assertEq(IAsyncVault(address(vault)).contribution(1, newController).amount, 1_000e18, "receiver contribution");

        _fulfillRedeem(1, 1_000e6, 1_000e18);

        // The original controller falls through to the instant lane once their ledger is empty, so the
        // policy has to answer for them.
        _noInstantLane();

        assertEq(IAsyncVault(address(vault)).maxWithdraw(newController), 1_000e6, "the payout follows the transfer");
        assertEq(IAsyncVault(address(vault)).maxWithdraw(controller), 0, "and not the original controller");
    }

    /// @dev The async-mode predicate walks the controller's whole horizon and has to ignore the other
    ///      side's buckets, or an open redeem request would send a 2-arg `deposit` down the claim path
    ///      with nothing to claim.
    function testAnOpenRequestOnOneSideDoesNotCloseTheOther() public {
        vm.prank(controller);
        IAsyncVault(address(vault)).requestRedeem(1_000e18, controller, controller);

        assertEq(IAsyncVault(address(vault)).pendingRedeemRequest(0, controller), 1_000e18);
        assertEq(IAsyncVault(address(vault)).pendingDepositRequest(0, controller), 0, "nothing pending on deposit");

        _instantLane(5_000e6);

        // With only a redeem in flight, the 2-arg deposit still takes the instant path.
        vm.prank(controller);
        uint256 shares = IAsyncVault(address(vault)).deposit(1_000e6, receiver);
        assertEq(shares, 1_000e18, "the deposit side is still open for business");
    }

    function _noInstantLane() internal {
        _mock(instantPolicy, abi.encodeWithSelector(IInstantPolicy.maxInstantDeposit.selector), abi.encode(uint128(0)));
        _mock(instantPolicy, abi.encodeWithSelector(IInstantPolicy.maxInstantRedeem.selector), abi.encode(uint128(0)));
    }

    function _instantLane(uint128 cap) internal {
        _mock(instantPolicy, abi.encodeWithSelector(IInstantPolicy.maxInstantDeposit.selector), abi.encode(cap));
        _mock(instantPolicy, abi.encodeWithSelector(IInstantPolicy.maxInstantRedeem.selector), abi.encode(cap));
        _mock(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantDeposit.selector),
            abi.encode(int128(0), address(0))
        );
        _mock(instantPolicy, abi.encodeWithSelector(IInstantPolicy.onInstantDeposit.selector), "");
        _mock(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantRedeem.selector),
            abi.encode(int128(0), address(0))
        );
        _mock(instantPolicy, abi.encodeWithSelector(IInstantPolicy.onInstantRedeem.selector), "");
    }

    function testAsyncDepositRequestAndClaim() public {
        vm.prank(controller);
        uint256 requestId = IAsyncVault(address(vault)).requestDeposit(1_000e6, controller, controller);
        assertEq(requestId, _requestId(1));
        assertEq(IAsyncVault(address(vault)).pendingDepositRequest(0, controller), 1_000e6);

        // Hub fulfills: 1000 assets -> 1000e18 shares at 1:1 (6 -> 18 decimals).
        _fulfillDeposit(1, 1_000e6, 1_000e18);

        uint256 maxMint = IAsyncVault(address(vault)).claimableMint(controller);
        assertEq(maxMint, 1_000e18);
        assertEq(IAsyncVault(address(vault)).pendingDepositRequest(0, controller), 0);

        // Claim: consumes maxMint and transfers shares out of escrow.
        vm.expectCall(
            spoke, abi.encodeWithSelector(ISpoke.withdrawShares.selector, POOL, SC, receiver, uint128(1_000e18))
        );
        vm.expectEmit(true, true, false, true, address(vault));
        emit IVaultEvents.Claimed(controller, receiver, controller, true, 1_000e6, 1_000e18, 0);
        vm.prank(controller);
        uint256 shares_ = IAsyncVault(address(vault)).deposit(1_000e6, receiver, controller);
        assertEq(shares_, 1_000e18);
        maxMint = IAsyncVault(address(vault)).claimableMint(controller);
        assertEq(maxMint, 0);
    }

    //----------------------------------------------------------------------------------------------
    // Auto-fold horizon
    //----------------------------------------------------------------------------------------------

    function _openPositions(address who, uint256 n) internal {
        for (uint256 i; i < n; i++) {
            vm.prank(who);
            IAsyncVault(address(vault)).requestDeposit(1e6, who, who);
        }
    }

    function _maxMint(address who) internal view returns (uint256) {
        return IAsyncVault(address(vault)).maxMint(who);
    }

    /// @dev No count of open positions blocks a request, and settled ones, each folded as it settled, are all
    ///      claimable in one call.
    function testOpenPositionsAreUnbounded() public {
        _openPositions(controller, 200);
        for (uint96 id = 1; id <= 200; id++) {
            _fulfillDeposit(id, 1e6, 1e18);
        }
        vm.prank(controller);
        assertEq(IAsyncVault(address(vault)).deposit(200e6, receiver, controller), 200e18);
    }

    /// @dev An unbatched position folds as it settles, so one the horizon no longer tracks is claimable without a
    ///      `foldRequest` and no longer pending.
    function testASettledPositionOutsideTheHorizonIsClaimable() public {
        _openPositions(controller, 2);
        _fulfillDeposit(1, 1e6, 1e18);
        _fulfillDeposit(2, 1e6, 1e18);

        assertEq(_maxMint(controller), 2e18, "the evicted position too");
        assertEq(IAsyncVault(address(vault)).pendingDepositRequest(0, controller), 0);
        assertEq(IAsyncVault(address(vault)).pendingDepositRequest(_requestId(1), controller), 0);
    }

    /// @dev A horizon narrower than the unsettled positions evicts one from the claim's fold, not from the pending
    ///      total the routing reads: once the tracked one is claimed, the instant lane stays closed while the evicted
    ///      one is pending.
    function testAnEvictedUnsettledPositionStillClosesTheInstantLane() public {
        _instantLane(5_000e6);
        _openPositions(controller, 2);
        _fulfillDeposit(2, 1e6, 1e18);

        vm.prank(controller);
        IAsyncVault(address(vault)).deposit(1e6, receiver);
        assertEq(IAsyncVault(address(vault)).pendingDepositRequest(0, controller), 1e6, "position 1 is pending");

        vm.prank(controller);
        vm.expectRevert(IVaultErrors.ExceedsDepositLimits.selector);
        IAsyncVault(address(vault)).deposit(1e6, receiver);
    }

    /// @dev An unconfigured horizon is one slot per open bucket, and a configured one applies as is: the pool sizes it.
    function testTheHorizonIsTheConfiguredOneOrTheDefault() public {
        assertEq(IAsyncVault(address(_vaultWithHorizon(0))).foldHorizon(), 1, "the default");
        assertEq(IAsyncVault(address(_vaultWithHorizon(20))).foldHorizon(), 20, "configured above it");
        assertEq(IAsyncVault(address(_vaultWithHorizon(100))).foldHorizon(), 100, "no cap");
    }

    /// @dev The vault reads the policy once, when deployed, so a policy that cannot answer cannot be deployed with.
    function testAPolicyThatCannotCountItsOpenBucketsCannotBeDeployedWith() public {
        vm.mockCallRevert(
            address(requestPolicy), abi.encodeWithSelector(IRequestPolicy.maxOpenBuckets.selector), "broken"
        );
        vm.expectRevert("broken");
        _vaultWithHorizon(1);
    }

    /// @dev A position a sponsor opens for the controller is the controller's: it folds as it settles, with no
    ///      `foldRequest`.
    function testASponsoredPositionIsTrackedLikeAnOwnOne() public {
        address sponsor = makeAddr("sponsor");
        asset.mint(sponsor, 1e6);
        vm.prank(sponsor);
        asset.approve(address(vault), type(uint256).max);

        vm.prank(sponsor);
        IAsyncVault(address(vault)).requestDeposit(1e6, controller, sponsor);
        _fulfillDeposit(1, 1e6, 1e18);

        assertEq(_maxMint(controller), 1e18, "claimable without a fold");
        assertEq(IAsyncVault(address(vault)).pendingDepositRequest(0, controller), 0);
    }

    /// @dev On a vault with both lanes, crediting a controller the caller does not act for asks the instant policy
    ///      whether the payer is a sponsor. The controller's operator asks nothing more.
    function testCreditingAnotherControllerAsksTheInstantPolicyForASponsor() public {
        address sponsor = makeAddr("sponsor");
        asset.mint(sponsor, 3e6);
        asset.mint(operator, 1e6);
        vm.prank(sponsor);
        asset.approve(address(vault), type(uint256).max);
        vm.prank(operator);
        asset.approve(address(vault), type(uint256).max);
        vm.prank(controller);
        IAsyncVault(address(vault)).setOperator(operator, true);

        bytes memory asked = abi.encodeCall(IInstantPolicy.canCredit, (address(vault), sponsor, controller));
        vm.expectCall(instantPolicy, asked);
        vm.prank(sponsor);
        IAsyncVault(address(vault)).requestDeposit(1e6, controller, sponsor);

        vm.expectCall(
            instantPolicy, abi.encodeCall(IInstantPolicy.canCredit, (address(vault), operator, controller)), 0
        );
        vm.prank(operator);
        IAsyncVault(address(vault)).requestDeposit(1e6, controller, operator);

        _mock(instantPolicy, asked, abi.encode(false));
        vm.prank(sponsor);
        vm.expectRevert(IVaultErrors.NotSponsor.selector);
        IAsyncVault(address(vault)).requestDeposit(1e6, controller, sponsor);
    }

    /// @dev A transfer moves the remainder between pending totals and the position out of the sender's
    ///      horizon; the recipient folds it unless the caller acts for them.
    function testTransferMovesThePendingTotal() public {
        address newController = makeAddr("newController");
        _openPositions(controller, 1);

        vm.prank(controller);
        IAsyncVault(address(vault)).transferDepositRequest(_requestId(1), controller, newController);

        assertEq(IAsyncVault(address(vault)).pendingDepositRequest(0, controller), 0);
        assertEq(IAsyncVault(address(vault)).pendingDepositRequest(0, newController), 1e6);
    }

    /// @dev A transferred unbatched position folds, as it settles, to whoever holds it then.
    function testASettlementFoldsATransferredPositionToItsHolder() public {
        address newController = makeAddr("newController");
        _openPositions(controller, 1);
        vm.prank(controller);
        IAsyncVault(address(vault)).transferDepositRequest(_requestId(1), controller, newController);

        _fulfillDeposit(1, 1e6, 1e18);

        assertEq(IAsyncVault(address(vault)).claimableMint(newController), 1e18);
        assertEq(IAsyncVault(address(vault)).claimableMint(controller), 0);
        assertEq(IAsyncVault(address(vault)).bucket(1).owner, address(0), "retired once folded whole");
    }

    function testAsyncRedeemRequestAndClaim() public {
        vm.prank(controller);
        IAsyncVault(address(vault)).requestRedeem(1_000e18, controller, controller);
        assertEq(IAsyncVault(address(vault)).pendingRedeemRequest(0, controller), 1_000e18);

        _fulfillRedeem(1, 1_000e6, 1_000e18);

        uint256 maxWithdraw = IAsyncVault(address(vault)).claimableWithdraw(controller);
        assertEq(maxWithdraw, 1_000e6);

        vm.expectCall(
            spoke,
            abi.encodeWithSelector(
                ISpoke.withdrawReserved.selector, POOL, SC, address(asset), uint256(0), receiver, uint128(1_000e6)
            )
        );
        vm.prank(controller);
        uint256 assets_ = IAsyncVault(address(vault)).redeem(1_000e18, receiver, controller);
        assertEq(assets_, 1_000e6);
    }

    function testInstantDepositWithFee() public {
        // Instant policy: 5000 asset capacity, 1% entry fee to feeRecipient.
        address feeRecipient = makeAddr("feeRecipient");
        _mock(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.maxInstantDeposit.selector),
            abi.encode(uint128(5_000e6))
        );
        _mock(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantDeposit.selector),
            abi.encode(uint128(10e6), feeRecipient)
        ); // 1% of 1000e6
        _mock(instantPolicy, abi.encodeWithSelector(IInstantPolicy.onInstantDeposit.selector), "");

        // Fee goes to the recipient; net 990e6 to escrow; shares minted for the net.
        vm.expectCall(
            spoke,
            abi.encodeWithSelector(ISpoke.noteDeposit.selector, POOL, SC, address(asset), uint256(0), uint128(990e6))
        );
        vm.expectCall(spoke, abi.encodeWithSelector(ISpoke.issue.selector, POOL, SC, receiver, uint128(990e18)));

        vm.expectEmit(address(vault));
        emit IVaultEvents.InstantFees(controller, receiver, true, 990e18, int128(10e6), feeRecipient, 0, 0, ONE, ONE);
        vm.prank(controller);
        uint256 shares_ = IAsyncVault(address(vault)).deposit(1_000e6, receiver);
        assertEq(shares_, 990e18);
    }

    /// @dev `maxMint` must be mintable: the entry fee is paid on top of the shares' asset value, so it
    ///      has to come out of the policy's spend capacity before converting to shares. Regression test
    ///      for a version where `maxMint` converted the gross capacity and `mint(maxMint())` reverted.
    function testInstantMintAtMaxMintSucceedsWithFee() public {
        address feeRecipient = makeAddr("feeRecipient");
        _mock(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.maxInstantDeposit.selector),
            abi.encode(uint128(5_000e6))
        );
        // The view asks for the controller about the 5000e6 capacity (1%), the trade for its receiver about the 4950e6
        // net (1%): two quotes, since the amount asked about differs
        _mock(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantDeposit.selector, address(vault), controller, controller),
            abi.encode(int128(50e6), feeRecipient)
        );
        _mock(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantDeposit.selector, address(vault), controller, receiver),
            abi.encode(int128(49.5e6), feeRecipient)
        );
        _mock(instantPolicy, abi.encodeWithSelector(IInstantPolicy.onInstantDeposit.selector), "");

        uint256 maxShares = IAsyncVault(address(vault)).maxMint(controller);
        assertEq(maxShares, 4_950e18, "capacity net of the entry fee, converted at 1:1");

        vm.prank(controller);
        uint256 assets_ = IAsyncVault(address(vault)).mint(maxShares, receiver);
        assertEq(assets_, 4_999.5e6, "total spend stays inside the 5000e6 capacity");
    }

    /// @dev The 3-argument ERC-7540 entrypoints claim only. Without this an operator calling them for a
    ///      controller with nothing in flight would perform an instant deposit out of its own balance,
    ///      since the instant path pulls from `msg.sender`.
    function testThreeArgDepositDoesNotFallBackToInstant() public {
        _mock(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.maxInstantDeposit.selector),
            abi.encode(uint128(5_000e6))
        );

        vm.prank(controller);
        IAsyncVault(address(vault)).setOperator(operator, true);

        // Nothing pending or claimable: the claim must revert rather than silently deposit.
        vm.prank(operator);
        vm.expectRevert(IVaultErrors.ExceedsDepositLimits.selector);
        IAsyncVault(address(vault)).deposit(1_000e6, receiver, controller);

        vm.prank(operator);
        vm.expectRevert(IVaultErrors.ExceedsDepositLimits.selector);
        IAsyncVault(address(vault)).mint(1_000e18, receiver, controller);
    }

    /// @dev A share price of zero passes the registry's validity check, which only asserts a price was
    ///      notified at least once. Before the guard, `mint` converted any share amount to zero assets,
    ///      cleared the capacity check (the capacity also clamps to zero at a zero price) and issued the
    ///      shares for free — outright dilution of every holder.
    function testInstantMintRejectsAZeroSharePrice() public {
        _mock(oracle, abi.encodeWithSelector(IVaultOracle.prices.selector), abi.encode(d18(1e18), d18(0), true));
        _mock(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.maxInstantDeposit.selector),
            abi.encode(uint128(5_000e6))
        );
        _mock(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantDeposit.selector),
            abi.encode(int128(0), address(0))
        );
        _mock(instantPolicy, abi.encodeWithSelector(IInstantPolicy.onInstantDeposit.selector), "");

        vm.prank(controller);
        vm.expectRevert(IVaultErrors.InvalidPrice.selector);
        IAsyncVault(address(vault)).mint(1_000e18, receiver);
    }

    /// @dev The shares of an instant deposit are issued on top of the supply, which holds at most a `uint128`, so
    ///      `maxDeposit` and `maxMint` keep to the room it has left. They used to clamp to what fits a `uint128` on
    ///      its own, and a deposit at the reported maximum then overflowed the share queue. Found by the Recon
    ///      campaign at a share price a billionth of par.
    function testInstantCapacityLeavesRoomForTheSharesAlreadyIssued() public {
        uint256 room = 1_000e18;
        share.setTotalSupply(type(uint128).max - room);
        _mock(oracle, abi.encodeWithSelector(IVaultOracle.prices.selector), abi.encode(d18(1e18), d18(1e18), true));
        _instantLane(type(uint128).max);
        _mock(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantDeposit.selector),
            abi.encode(int128(0), address(0))
        );
        _mock(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantDeposit.selector),
            abi.encode(int128(0), address(0))
        );
        _mock(instantPolicy, abi.encodeWithSelector(IInstantPolicy.onInstantDeposit.selector), "");

        uint256 maxAssets = IAsyncVault(address(vault)).maxDeposit(controller);
        assertGt(maxAssets, 0, "there is room for something");
        assertLe(IAsyncVault(address(vault)).convertToShares(maxAssets), room, "maxDeposit fits the room");
        assertLe(IAsyncVault(address(vault)).maxMint(controller), room, "maxMint fits the room");

        // And the deposit at the maximum is not refused for the capacity
        vm.prank(controller);
        IAsyncVault(address(vault)).deposit(maxAssets, receiver);
    }

    /// @dev A request transfer must name a bucket that exists. The redeem-side predicate was
    ///      `!isDeposit`, which an all-zero (unused) bucket satisfies, so anyone could transfer a
    ///      non-existent request to any address — appending to that address's horizon, which
    ///      every claim and every capacity view walks in full. Unbounded growth freezes the position.
    function testRequestTransferRejectsANonExistentBucket() public {
        address victim = makeAddr("victim");
        uint256 fabricated = _requestId(12345);

        vm.prank(controller);
        vm.expectRevert(IVaultErrors.InvalidRequestId.selector);
        IAsyncVault(address(vault)).transferRedeemRequest(fabricated, controller, victim);

        vm.prank(controller);
        vm.expectRevert(IVaultErrors.InvalidRequestId.selector);
        IAsyncVault(address(vault)).transferDepositRequest(fabricated, controller, victim);
    }

    function testInstantMintNoFee() public {
        _mock(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.maxInstantDeposit.selector),
            abi.encode(uint128(5_000e6))
        );
        _mock(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantDeposit.selector),
            abi.encode(uint128(0), address(0))
        );
        _mock(instantPolicy, abi.encodeWithSelector(IInstantPolicy.onInstantDeposit.selector), "");

        // mint 1000e18 shares -> 1000e6 net assets to escrow at 1:1.
        vm.expectCall(spoke, abi.encodeWithSelector(ISpoke.issue.selector, POOL, SC, receiver, uint128(1_000e18)));
        vm.prank(controller);
        uint256 assets_ = IAsyncVault(address(vault)).mint(1_000e18, receiver);
        assertEq(assets_, 1_000e6);
    }

    function testInstantRedeemNetOfFee() public {
        address feeRecipient = makeAddr("feeRecipient");
        _mock(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.maxInstantRedeem.selector),
            abi.encode(uint128(5_000e6))
        );
        _mock(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantRedeem.selector),
            abi.encode(uint128(10e6), feeRecipient)
        ); // 1% of gross 1000e6
        _mock(instantPolicy, abi.encodeWithSelector(IInstantPolicy.onInstantRedeem.selector), "");

        // redeem 1000e18 shares: receiver gets 990e6 (gross 1000e6 - fee 10e6), fee to recipient.
        vm.expectCall(
            spoke,
            abi.encodeWithSelector(
                ISpoke.withdraw.selector, POOL, SC, address(asset), uint256(0), receiver, uint128(990e6)
            )
        );
        vm.expectCall(
            spoke,
            abi.encodeWithSelector(
                ISpoke.withdraw.selector, POOL, SC, address(asset), uint256(0), feeRecipient, uint128(10e6)
            )
        );
        vm.expectEmit(address(vault));
        emit IVaultEvents.InstantFees(controller, receiver, false, 1_000e18, int128(10e6), feeRecipient, 0, 0, ONE, ONE);
        vm.prank(controller);
        uint256 assets_ = IAsyncVault(address(vault)).redeem(1_000e18, receiver);
        assertEq(assets_, 990e6);
    }

    /// @dev Settling a bucket is visible on the vault, not only once someone folds it.
    function testSettlingABucketEmitsItsTotals() public {
        vm.prank(controller);
        IAsyncVault(address(vault)).requestDeposit(1_000e6, controller, controller);

        vm.startPrank(router);
        IVaultDepositCallbacks(address(vault)).approveDeposits(1, 1_000e6);
        IVaultDepositCallbacks(address(vault)).issueShares(1, 1_000e18);
        vm.expectEmit(address(vault));
        emit IVaultEvents.BucketSettled(_requestId(1), true, 1_000e6, 1_000e18, 0, 0);
        IVaultDepositCallbacks(address(vault)).fulfillDepositRequest(1, 1_000e6, 1_000e18);
        vm.stopPrank();
    }

    /// @dev The retained fee stays in the escrow: shares burn at full value but only the payout
    ///      leaves, so the difference accrues to the holders who did not exit.
    function testInstantRedeemRetainedStaysInEscrow() public {
        _mock(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.maxInstantRedeem.selector),
            abi.encode(uint128(5_000e6))
        );
        // A 1% fee with no recipient is retained by the pool.
        _mock(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantRedeem.selector),
            abi.encode(int128(10e6), address(0))
        );
        _mock(instantPolicy, abi.encodeWithSelector(IInstantPolicy.onInstantRedeem.selector), "");

        // Shares worth 1000e6 burn, but only 990e6 leaves the escrow. Nothing is paid to a recipient.
        vm.expectCall(
            spoke,
            abi.encodeWithSelector(
                ISpoke.withdraw.selector, POOL, SC, address(asset), uint256(0), receiver, uint128(990e6)
            )
        );
        vm.expectCall(spoke, abi.encodeWithSelector(ISpoke.revoke.selector, POOL, SC, uint128(1_000e18)));

        vm.prank(controller);
        uint256 assets_ = IAsyncVault(address(vault)).redeem(1_000e18, receiver);
        assertEq(assets_, 990e6, "payout is net of the retained fee");
    }

    /// @dev On the deposit side the retained fee reaches the escrow but backs no shares.
    function testInstantDepositRetainedBacksNoShares() public {
        _mock(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.maxInstantDeposit.selector),
            abi.encode(uint128(5_000e6))
        );
        _mock(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantDeposit.selector),
            abi.encode(int128(10e6), address(0))
        );
        _mock(instantPolicy, abi.encodeWithSelector(IInstantPolicy.onInstantDeposit.selector), "");

        // The full 1000e6 is escrowed, but only 990e6 of it backs newly issued shares.
        vm.expectCall(
            spoke,
            abi.encodeWithSelector(ISpoke.noteDeposit.selector, POOL, SC, address(asset), uint256(0), uint128(1_000e6))
        );
        vm.expectCall(spoke, abi.encodeWithSelector(ISpoke.issue.selector, POOL, SC, receiver, uint128(990e18)));

        vm.prank(controller);
        uint256 shares_ = IAsyncVault(address(vault)).deposit(1_000e6, receiver);
        assertEq(shares_, 990e18, "shares priced on the net of the retained fee");
    }

    /// @dev A price the executes would reject must read as no instant capacity, not as capacity
    ///      that reverts on use. Otherwise routers sizing off `max*` hit an unpriceable revert.
    function testStalePriceReadsAsNoInstantCapacity() public {
        _mock(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.maxInstantDeposit.selector),
            abi.encode(uint128(5_000e6))
        );
        _mock(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.maxInstantRedeem.selector),
            abi.encode(uint128(5_000e6))
        );
        // The oracle returns the prices but refuses to vouch for them; the capacity views must read
        // that as no capacity rather than as capacity that reverts on use.
        _mock(oracle, abi.encodeWithSelector(IVaultOracle.prices.selector), abi.encode(ONE, ONE, false));

        assertEq(IAsyncVault(address(vault)).maxDeposit(controller), 0, "no instant deposit capacity");
        assertEq(IAsyncVault(address(vault)).maxMint(controller), 0, "no instant mint capacity");
        assertEq(IAsyncVault(address(vault)).maxWithdraw(controller), 0, "no instant withdraw capacity");
        assertEq(IAsyncVault(address(vault)).maxRedeem(controller), 0, "no instant redeem capacity");
    }

    function testInstantWithdrawDeliversExactAssets() public {
        // Exit fee 1%; withdraw(1000) must send the receiver exactly 1000, burning shares for 1010.
        address feeRecipient = makeAddr("feeRecipient");
        _mock(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.maxInstantRedeem.selector),
            abi.encode(uint128(5_000e6))
        );
        _mock(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantRedeem.selector),
            abi.encode(uint128(10e6), feeRecipient)
        ); // 1% of 1000e6
        _mock(instantPolicy, abi.encodeWithSelector(IInstantPolicy.onInstantRedeem.selector), "");

        vm.expectCall(
            spoke,
            abi.encodeWithSelector(
                ISpoke.withdraw.selector, POOL, SC, address(asset), uint256(0), receiver, uint128(1_000e6)
            )
        );
        vm.expectCall(
            spoke,
            abi.encodeWithSelector(
                ISpoke.withdraw.selector, POOL, SC, address(asset), uint256(0), feeRecipient, uint128(10e6)
            )
        );

        vm.prank(controller);
        uint256 shares_ = IAsyncVault(address(vault)).withdraw(1_000e6, receiver);
        assertEq(shares_, 1_010e18); // burned shares cover payout + fee
    }

    function testInstantDepositRebate() public {
        // Negative fee: the fee source tops the escrowed amount up by 10e6, so the shares are
        // priced on 1010e6 and stay fully asset-backed.
        address feeSource = makeAddr("feeSource");
        _mock(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.maxInstantDeposit.selector),
            abi.encode(uint128(5_000e6))
        );
        _mock(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantDeposit.selector),
            abi.encode(int128(-10e6), feeSource)
        );
        _mock(instantPolicy, abi.encodeWithSelector(IInstantPolicy.onInstantDeposit.selector), "");

        vm.expectCall(
            spoke,
            abi.encodeWithSelector(ISpoke.noteDeposit.selector, POOL, SC, address(asset), uint256(0), uint128(1_010e6))
        );
        vm.expectCall(spoke, abi.encodeWithSelector(ISpoke.issue.selector, POOL, SC, receiver, uint128(1_010e18)));
        vm.expectCall(
            address(asset), abi.encodeWithSelector(MockERC20.transferFrom.selector, feeSource, escrow, uint256(10e6))
        );
        vm.expectCall(
            address(asset),
            abi.encodeWithSelector(MockERC20.transferFrom.selector, controller, escrow, uint256(1_000e6))
        );

        vm.prank(controller);
        uint256 shares_ = IAsyncVault(address(vault)).deposit(1_000e6, receiver);
        assertEq(shares_, 1_010e18);
    }

    function testInstantRedeemRebate() public {
        // Negative fee: the escrow pays the gross share value; the fee source pays the receiver
        // 10e6 on top, outside pool accounting.
        address feeSource = makeAddr("feeSource");
        _mock(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.maxInstantRedeem.selector),
            abi.encode(uint128(5_000e6))
        );
        _mock(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantRedeem.selector),
            abi.encode(int128(-10e6), feeSource)
        );
        _mock(instantPolicy, abi.encodeWithSelector(IInstantPolicy.onInstantRedeem.selector), "");

        vm.expectCall(
            spoke,
            abi.encodeWithSelector(
                ISpoke.withdraw.selector, POOL, SC, address(asset), uint256(0), receiver, uint128(1_000e6)
            )
        );
        vm.expectCall(
            address(asset), abi.encodeWithSelector(MockERC20.transferFrom.selector, feeSource, receiver, uint256(10e6))
        );

        vm.prank(controller);
        uint256 assets_ = IAsyncVault(address(vault)).redeem(1_000e18, receiver);
        assertEq(assets_, 1_010e6);
    }

    function testInstantWithdrawRebateBurnsFewerShares() public {
        // withdraw(1000) with a 10e6 rebate: the escrow covers only 990e6, so shares for 990e6
        // are burned; the fee source pays the remaining 10e6 straight to the receiver.
        address feeSource = makeAddr("feeSource");
        _mock(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.maxInstantRedeem.selector),
            abi.encode(uint128(5_000e6))
        );
        _mock(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantRedeem.selector),
            abi.encode(int128(-10e6), feeSource)
        );
        _mock(instantPolicy, abi.encodeWithSelector(IInstantPolicy.onInstantRedeem.selector), "");

        vm.expectCall(
            spoke,
            abi.encodeWithSelector(
                ISpoke.withdraw.selector, POOL, SC, address(asset), uint256(0), receiver, uint128(990e6)
            )
        );
        vm.expectCall(
            address(asset), abi.encodeWithSelector(MockERC20.transferFrom.selector, feeSource, receiver, uint256(10e6))
        );

        vm.prank(controller);
        uint256 shares_ = IAsyncVault(address(vault)).withdraw(1_000e6, receiver);
        assertEq(shares_, 990e18);
    }

    function testPendingRequestForeignVaultIdReturnsZero() public {
        vm.prank(controller);
        IAsyncVault(address(vault)).requestDeposit(1_000e6, controller, controller);

        // A request id namespaced to a different vault must resolve to 0, not this vault's bucket.
        uint256 foreignId = uint256(VaultRequestIdLib.from(makeAddr("otherVault"), 1).raw());
        assertEq(IAsyncVault(address(vault)).pendingDepositRequest(foreignId, controller), 0);
        // The correctly-namespaced per-request id resolves.
        assertEq(IAsyncVault(address(vault)).pendingDepositRequest(_requestId(1), controller), 1_000e6);
    }

    function testRedeemClaimEnforcesPayoutRestriction() public {
        vm.prank(controller);
        IAsyncVault(address(vault)).requestRedeem(1_000e18, controller, controller);
        _fulfillRedeem(1, 1_000e6, 1_000e18);

        // The claim enforces the redemption payout as a `Payout` role check; a hook that blocks it reverts the claim.
        vm.mockCallRevert(
            actionHook,
            abi.encodeWithSelector(IRoleHook.onRoles.selector),
            abi.encodeWithSelector(ITransferHook.TransferBlocked.selector)
        );
        vm.prank(controller);
        vm.expectRevert(ITransferHook.TransferBlocked.selector);
        IAsyncVault(address(vault)).redeem(1_000e18, receiver, controller);
    }

    function testCallbackUnauthorizedReverts() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        IVaultDepositCallbacks(address(vault)).fulfillDepositRequest(1, 1e6, 1e18);
    }

    /// @dev The ERC-165 ids the specs hardcode; a drifting local interface must fail loudly.
    function testErc165InterfaceIdsMatchSpecs() public view {
        assertEq(type(IERC7540Operator).interfaceId, bytes4(0xe3bc4e65), "ERC-7540 operator id");
        assertEq(type(IERC7540Deposit).interfaceId, bytes4(0xce3bbe50), "ERC-7540 async deposit id");
        assertEq(type(IERC7540Redeem).interfaceId, bytes4(0x620ee8e4), "ERC-7540 async redeem id");
        assertEq(type(IERC7575).interfaceId, bytes4(0x2f0a18c5), "ERC-7575 vault id");
        assertTrue(vault.supportsInterface(0xe3bc4e65));
        assertTrue(vault.supportsInterface(0xce3bbe50));
        assertTrue(vault.supportsInterface(0x620ee8e4));
        assertTrue(vault.supportsInterface(0x2f0a18c5));
        assertEq(type(IERC8161DepositTransferable).interfaceId, bytes4(0x53b3bb0a), "ERC-8161 deposit id");
        assertEq(type(IERC8161RedeemTransferable).interfaceId, bytes4(0x7846f5bd), "ERC-8161 redeem id");
        assertTrue(vault.supportsInterface(0x53b3bb0a));
        assertTrue(vault.supportsInterface(0x7846f5bd));
        assertFalse(vault.supportsInterface(0xffffffff), "ERC-165 invalid id");
        assertFalse(vault.supportsInterface(0x8bf840e3), "ERC-7887 is not implemented");
        assertFalse(vault.supportsInterface(0xe76cffc7), "ERC-7887 is not implemented");
    }

    /// @dev ERC-8161 is advertised only where the request policy lets a transfer through.
    function testTransfersAreRefusedAndUnadvertisedWhereThePolicyDisallowsThem() public {
        vm.mockCall(
            address(requestPolicy), abi.encodeWithSelector(IRequestPolicy.supportsTransfers.selector), abi.encode(false)
        );
        // Read once, when the vault is deployed
        Vault closed = _vaultWithHorizon(0);
        assertFalse(closed.supportsInterface(0x53b3bb0a), "deposit transfers");
        assertFalse(closed.supportsInterface(0x7846f5bd), "redeem transfers");
        assertTrue(closed.supportsInterface(0xce3bbe50), "async deposit stays");
        assertTrue(closed.supportsInterface(0x620ee8e4), "async redeem stays");

        vm.prank(controller);
        vm.expectRevert(IVaultErrors.TransfersUnsupported.selector);
        closed.transferDepositRequest(
            VaultRequestIdLib.from(address(closed), 1).raw(), controller, makeAddr("recipient")
        );
    }

    /// @dev ERC-7540: `setOperator` logs `OperatorSet` and returns true.
    function testSetOperatorEmitsAndReturnsTrue() public {
        address newOperator = makeAddr("newOperator");
        vm.expectEmit(true, true, false, true, address(vault));
        emit IERC7540Operator.OperatorSet(controller, newOperator, true);
        vm.prank(controller);
        assertTrue(IERC7540Operator(address(vault)).setOperator(newOperator, true));
        assertTrue(IERC7540Operator(address(vault)).isOperator(controller, newOperator));
    }

    /// @dev Previews quote the instant path, fee-inclusive (ERC-4626), at oracle prices.
    function testPreviewsQuoteInstantPathWithFees() public {
        _mock(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantDeposit.selector),
            abi.encode(int128(10e6), address(0))
        ); // 1% of 1000e6
        _mock(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantRedeem.selector),
            abi.encode(int128(10e6), address(0))
        );

        assertEq(vault.previewDeposit(1_000e6), 990e18, "deposit: shares on net of entry fee");
        assertEq(vault.previewMint(1_000e18), 1_010e6, "mint: assets grossed up by entry fee");
        assertEq(vault.previewWithdraw(1_000e6), 1_010e18, "withdraw: shares cover payout + exit fee");
        assertEq(vault.previewRedeem(1_000e18), 990e6, "redeem: payout net of exit fee");
    }

    /// @dev A rebate (negative fee quote) is clamped: previews only ever under-promise.
    function testPreviewClampsRebates() public {
        _mock(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantDeposit.selector),
            abi.encode(int128(-10e6), address(0))
        );
        assertEq(vault.previewDeposit(1_000e6), 1_000e18, "rebate ignored in preview");
    }

    function _vaultWithHorizon(uint256 horizon) internal returns (Vault) {
        VaultConfig memory config = VaultConfig({
            spoke: ISpoke(spoke),
            spokeRegistry: ISpokeRegistry(spokeRegistry),
            plugins: VaultPlugins({
                oracle: IVaultOracle(oracle),
                instantPolicy: IInstantPolicy(instantPolicy),
                requestPolicy: IRequestPolicy(address(requestPolicy)),
                liquidityRoute: ILiquidityRoute(address(0)),
                settlementObserver: ISettlementObserver(address(0))
            }),
            foldHorizon: horizon
        });
        return new Vault(POOL, SC, address(asset), ASSET_ID, IShareToken(address(share)), config);
    }

    /// @dev With no instant policy the vault is fully async and previews revert, per ERC-7540.
    function testPreviewsRevertWhenFullyAsync() public {
        VaultConfig memory config = VaultConfig({
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
        });
        Vault asyncOnly = new Vault(POOL, SC, address(asset), ASSET_ID, IShareToken(address(share)), config);

        vm.expectRevert();
        asyncOnly.previewDeposit(1_000e6);
        vm.expectRevert();
        asyncOnly.previewMint(1_000e18);
        vm.expectRevert();
        asyncOnly.previewWithdraw(1_000e6);
        vm.expectRevert();
        asyncOnly.previewRedeem(1_000e18);
    }

    /// @dev An instant-only vault (no request policy) is ERC-7575/ERC-4626 and must not advertise the
    ///      async ERC-7540 deposit/redeem interfaces its `request*` methods would reject.
    function testSupportsInterfaceInstantOnlyOmitsAsync() public {
        VaultConfig memory config = VaultConfig({
            foldHorizon: 0,
            spoke: ISpoke(spoke),
            spokeRegistry: ISpokeRegistry(spokeRegistry),
            plugins: VaultPlugins({
                oracle: IVaultOracle(oracle),
                instantPolicy: IInstantPolicy(instantPolicy),
                requestPolicy: IRequestPolicy(address(0)),
                liquidityRoute: ILiquidityRoute(address(0)),
                settlementObserver: ISettlementObserver(address(0))
            })
        });
        Vault instantOnly = new Vault(POOL, SC, address(asset), ASSET_ID, IShareToken(address(share)), config);

        // ERC-7575, ERC-165, and the operator interface stay supported.
        assertTrue(instantOnly.supportsInterface(0x2f0a18c5), "ERC-7575");
        assertTrue(instantOnly.supportsInterface(0x01ffc9a7), "ERC-165");
        assertTrue(instantOnly.supportsInterface(0xe3bc4e65), "ERC-7540 operator");
        // The async deposit/redeem interfaces are not advertised.
        assertFalse(instantOnly.supportsInterface(0xce3bbe50), "no async deposit");
        assertFalse(instantOnly.supportsInterface(0x620ee8e4), "no async redeem");
    }

    /// @dev Hub-initiated cancellations emit the ERC-7887 claimable event (same signature as the
    ///      v3 vaults) so cancellation-aware indexers can distinguish them from fulfillments. The
    ///      vault fires it in the settlement transaction, folding the unbatched bucket.
    function testCancellationEmitsErc7887ClaimableEvent() public {
        vm.prank(controller);
        IAsyncVault(address(vault)).requestDeposit(1_000e6, controller, controller);

        vm.expectEmit();
        emit IVaultEvents.CancelDepositClaimable(_requestId(1), controller, 1_000e6);
        vm.prank(router);
        IVaultDepositCallbacks(address(vault)).cancelDeposit(1, 1_000e6, 1_000e6);

        // The cancelled assets are claimable through the redeem side.
        uint256 maxWithdraw = IAsyncVault(address(vault)).claimableWithdraw(controller);
        assertEq(maxWithdraw, 1_000e6, "cancelled deposit claimable via withdraw");
    }

    /// @dev A cancellation with a retained fee: `BucketSettled` carries the gross and net, and the fold the
    ///      controller's share of each, so the fee is `gross - net` everywhere it is read.
    function testADepositCancellationWithARetainedFeeIsLoggedWhole() public {
        vm.prank(controller);
        IAsyncVault(address(vault)).requestDeposit(1_000e6, controller, controller);

        vm.expectEmit(true, false, false, true, address(vault));
        emit IVaultEvents.BucketSettled(_requestId(1), true, 0, 0, 1_000e6, 990e6);
        vm.expectEmit(true, true, false, true, address(vault));
        emit IVaultEvents.CancelDepositClaimable(_requestId(1), controller, 990e6);
        vm.expectEmit(true, true, false, true, address(vault));
        emit IVaultEvents.RequestFolded(_requestId(1), controller, true, 0, 0, 1_000e6, 990e6, 0, true, true);
        vm.prank(router);
        IVaultDepositCallbacks(address(vault)).cancelDeposit(1, 1_000e6, 990e6);
    }

    function testARedeemCancellationWithARetainedFeeIsLoggedWhole() public {
        vm.prank(controller);
        IAsyncVault(address(vault)).requestRedeem(1_000e18, controller, controller);

        vm.expectEmit(true, false, false, true, address(vault));
        emit IVaultEvents.BucketSettled(_requestId(1), false, 0, 0, 1_000e18, 990e18);
        vm.expectEmit(true, true, false, true, address(vault));
        emit IVaultEvents.CancelRedeemClaimable(_requestId(1), controller, 990e18);
        vm.expectEmit(true, true, false, true, address(vault));
        emit IVaultEvents.RequestFolded(_requestId(1), controller, false, 0, 0, 1_000e18, 990e18, 0, true, true);
        vm.prank(router);
        IVaultRedeemCallbacks(address(vault)).cancelRedeem(1, 1_000e18, 990e18);
    }

    /// @dev A fold that completes a fill reports what it credited beside the claimable event.
    function testAFillFoldEmitsRequestFoldedBesideTheClaimableEvent() public {
        vm.prank(controller);
        IAsyncVault(address(vault)).requestDeposit(1_000e6, controller, controller);

        vm.startPrank(router);
        IVaultDepositCallbacks(address(vault)).approveDeposits(1, 1_000e6);
        IVaultDepositCallbacks(address(vault)).issueShares(1, 1_000e18);

        vm.expectEmit(true, false, false, true, address(vault));
        emit IVaultEvents.BucketSettled(_requestId(1), true, 1_000e6, 1_000e18, 0, 0);
        vm.expectEmit(true, true, false, true, address(vault));
        emit IVaultEvents.DepositClaimable(_requestId(1), controller, 1_000e6, 1_000e18);
        vm.expectEmit(true, true, false, true, address(vault));
        emit IVaultEvents.RequestFolded(_requestId(1), controller, true, 1_000e6, 1_000e18, 0, 0, 0, true, true);
        IVaultDepositCallbacks(address(vault)).fulfillDepositRequest(1, 1_000e6, 1_000e18);
        vm.stopPrank();
    }

    /// @dev The first contribution to a bucket opens it, and a request on a fresh id is a fresh bucket.
    function testARequestOpensItsBucket() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit IVaultEvents.BucketOpened(_requestId(1), true, 0);
        vm.prank(controller);
        IAsyncVault(address(vault)).requestDeposit(1_000e6, controller, controller);

        vm.expectEmit(true, false, false, true, address(vault));
        emit IVaultEvents.BucketOpened(_requestId(2), false, 0);
        vm.prank(controller);
        IAsyncVault(address(vault)).requestRedeem(1_000e18, controller, controller);
    }

    /// @dev What the transfer moves besides the pending: the receiver takes over the snapshots of what the sender
    ///      had already folded, a fill and a cancellation with its fee.
    function testATransferLogsTheFoldedSnapshotsItMoves() public {
        vm.prank(controller);
        IAsyncVault(address(vault)).requestDeposit(1_000e6, controller, controller);
        _fulfillDeposit(1, 400e6, 400e18);
        vm.prank(router);
        IVaultDepositCallbacks(address(vault)).cancelDeposit(1, 100e6, 90e6);

        address newController = makeAddr("newController");
        vm.expectEmit(true, true, true, true, address(vault));
        emit IVaultEvents.RequestTransferred(_requestId(1), controller, newController, true, 1_000e6, 500e6);
        vm.prank(controller);
        IAsyncVault(address(vault)).transferDepositRequest(_requestId(1), controller, newController);
    }

    //----------------------------------------------------------------------------------------------
    // Identity and valuation views
    //----------------------------------------------------------------------------------------------

    /// @dev The whole configuration surface, in one place. It is what an integrator or an indexer
    ///      reads to find its way around a vault, and the router is the only contract that serves it,
    ///      so a getter wired to the wrong variable would show up nowhere else.
    function testTheRouterReportsItsOwnConfiguration() public view {
        IAsyncVault v_ = IAsyncVault(address(vault));

        assertEq(v_.asset(), address(asset));
        assertEq(v_.share(), address(share));
        assertEq(v_.poolId().raw(), POOL.raw());
        assertEq(v_.scId().raw(), SC.raw());
        assertEq(v_.assetId().raw(), ASSET_ID.raw());
        assertEq(address(v_.spoke()), spoke);
        assertEq(v_.escrow(), escrow);
        assertEq(address(v_.spokeRegistry()), spokeRegistry);
        assertEq(address(v_.oracle()), oracle);
        assertEq(address(v_.instantPolicy()), instantPolicy);
        assertEq(address(v_.requestPolicy()), address(requestPolicy));
        assertEq(address(v_.liquidityRoute()), address(0));
        assertEq(address(v_.settlementObserver()), address(0));
    }

    function testOperatorApprovalIsReadableBothWays() public {
        IAsyncVault v_ = IAsyncVault(address(vault));
        assertFalse(v_.isOperator(controller, operator));

        vm.prank(controller);
        v_.setOperator(operator, true);
        assertTrue(v_.isOperator(controller, operator));
        assertFalse(v_.isOperator(operator, controller), "approval is directional");

        vm.prank(controller);
        v_.setOperator(operator, false);
        assertFalse(v_.isOperator(controller, operator));
    }

    /// @dev The conversions price at the last hub prices and must answer whatever the oracle thinks of
    ///      them, since they are what values a position rather than what trades one.
    function testConversionsUseTheLastHubPrices() public {
        IAsyncVault v_ = IAsyncVault(address(vault));

        // 1 share is worth 2 assets: ppa 1, pps 2, across an 18/6 decimal gap.
        _mock(oracle, abi.encodeWithSelector(IVaultOracle.prices.selector), abi.encode(ONE, D18.wrap(2e18), true));

        assertEq(v_.convertToShares(200e6), 100e18, "assets to shares");
        assertEq(v_.convertToAssets(100e18), 200e6, "and back");
        assertEq(v_.pricePerShare(), 2e6, "one share in asset decimals");

        share.setTotalSupply(1_000e18);
        assertEq(v_.totalAssets(), 2_000e6, "the share supply at the last prices");
    }

    /// @dev A stale or refused price still converts: an ERC-7575 valuation that reverted would take
    ///      every integrator's position display down with it.
    function testConversionsAnswerEvenWhenTheOracleRefusesThePrice() public {
        IAsyncVault v_ = IAsyncVault(address(vault));
        _mock(oracle, abi.encodeWithSelector(IVaultOracle.prices.selector), abi.encode(ONE, ONE, false));

        assertEq(v_.convertToShares(1_000e6), 1_000e18);
        assertEq(v_.convertToAssets(1_000e18), 1_000e6);
    }

    /// @dev An unset price is zero, which would convert to zero rather than reverting, so both
    ///      directions guard it explicitly.
    function testConversionsAreZeroAtAnUnsetPrice() public {
        IAsyncVault v_ = IAsyncVault(address(vault));

        _mock(oracle, abi.encodeWithSelector(IVaultOracle.prices.selector), abi.encode(ONE, ZERO_PRICE, true));
        assertEq(v_.convertToShares(1_000e6), 0, "no share price");

        _mock(oracle, abi.encodeWithSelector(IVaultOracle.prices.selector), abi.encode(ZERO_PRICE, ONE, true));
        assertEq(v_.convertToAssets(1_000e18), 0, "no asset price");
    }

    function testAnUnbatchedRequestIsSentAtOnceAndOwned() public {
        IAsyncVault v_ = IAsyncVault(address(vault));
        assertEq(v_.bucket(1).queued, 0, "no bucket");

        vm.prank(controller);
        uint256 requestId = v_.requestDeposit(1_000e6, controller, controller);
        uint96 localId = uint96(requestId);

        // The default policy does not batch, so the request is flushed in the same call.
        assertEq(v_.bucket(localId).queued, 0, "flushed on the way out");
        assertEq(v_.bucket(localId).total, 1_000e6, "but it is in the bucket");
        assertEq(v_.bucket(localId).owner, controller, "owned by its controller");
    }
}
