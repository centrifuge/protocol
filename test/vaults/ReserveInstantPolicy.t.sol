// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IsContract} from "./Vault.t.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {newAssetId} from "../../src/core/types/AssetId.sol";
import {ISpoke} from "../../src/core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {VaultDetails, ISpokeRegistry} from "../../src/core/spoke/interfaces/ISpokeRegistry.sol";

import {IVault} from "../../src/vaults/interfaces/IVault.sol";
import {ReserveInstantPolicy} from "../../src/vaults/policies/ReserveInstantPolicy.sol";
import {IReserveInstantPolicy} from "../../src/vaults/policies/interfaces/IVaultPlugins.sol";

import "forge-std/Test.sol";

/// @dev The default instant policy: it decides how much may be deposited or redeemed instantly and
///      what it costs, for every vault that runs an instant lane.
contract ReserveInstantPolicyTest is Test {
    PoolId constant POOL = PoolId.wrap(1);
    PoolId constant OTHER_POOL = PoolId.wrap(2);
    ShareClassId constant SC = ShareClassId.wrap(bytes16("sc1"));

    address spoke = address(new IsContract());
    address spokeRegistry = address(new IsContract());
    address vault = address(new IsContract());
    address asset = address(new IsContract());
    address envoy = makeAddr("envoy");
    address feeRecipient = makeAddr("feeRecipient");
    address investor = makeAddr("investor");
    address gate = makeAddr("gate");

    ReserveInstantPolicy policy;

    function setUp() public {
        // The policy asks the registry which pool a vault belongs to, never the vault itself, and
        // pins the registry at construction.
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.spokeRegistry.selector), abi.encode(spokeRegistry));
        policy = new ReserveInstantPolicy(ISpoke(spoke), envoy);

        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.vaultDetails.selector, vault),
            abi.encode(VaultDetails(POOL, SC, newAssetId(0, 1), asset, uint256(0), true))
        );
        vm.mockCall(vault, abi.encodeWithSelector(IVault.poolId.selector), abi.encode(POOL));
        vm.mockCall(vault, abi.encodeWithSelector(IVault.scId.selector), abi.encode(SC));
        _setAvailable(0);
    }

    function _setAvailable(uint128 available) internal {
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.availableBalanceOf.selector), abi.encode(available));
    }

    function _quoteDeposit(uint128 assets) internal view returns (int128 fee) {
        (fee,) = policy.quoteInstantDeposit(vault, investor, investor, assets, false);
    }

    function _quoteRedeem(uint128 assets) internal view returns (int128 fee) {
        (fee,) = policy.quoteInstantRedeem(vault, investor, investor, assets, false);
    }

    function _config(uint128 maxReserve, bool redeemEnabled, uint16 depositFeeBps, uint16 redeemFeeBps)
        internal
        view
        returns (IReserveInstantPolicy.Config memory)
    {
        return IReserveInstantPolicy.Config({
            feeRecipient: feeRecipient,
            depositFeeBps: depositFeeBps,
            redeemFeeBps: redeemFeeBps,
            redeemEnabled: redeemEnabled,
            gatedDeposit: false,
            gatedRedeem: false,
            maxReserve: maxReserve
        });
    }

    function _payload(IReserveInstantPolicy.Config memory config_) internal view returns (bytes memory) {
        return abi.encode(IReserveInstantPolicy.ConfigKind.Terms, vault, abi.encode(config_));
    }

    function _terms(uint128 maxReserve, bool redeemEnabled, uint16 depositFeeBps, uint16 redeemFeeBps)
        internal
        view
        returns (bytes memory)
    {
        return _payload(_config(maxReserve, redeemEnabled, depositFeeBps, redeemFeeBps));
    }

    function _configure(uint128 maxReserve, bool redeemEnabled, uint16 depositFeeBps, uint16 redeemFeeBps) internal {
        vm.prank(envoy);
        policy.fromHub(POOL, _terms(maxReserve, redeemEnabled, depositFeeBps, redeemFeeBps));
    }

    function _gate(bool gatedDeposit, bool gatedRedeem) internal {
        IReserveInstantPolicy.Config memory config_ = _config(1_000e6, true, 0, 0);
        config_.gatedDeposit = gatedDeposit;
        config_.gatedRedeem = gatedRedeem;

        vm.prank(envoy);
        policy.fromHub(POOL, _payload(config_));
    }

    function _allowDepositor(address who, bool allowed) internal {
        vm.prank(envoy);
        policy.fromHub(POOL, abi.encode(IReserveInstantPolicy.ConfigKind.Depositor, vault, abi.encode(who, allowed)));
    }

    function _allowRedeemer(address who, bool allowed) internal {
        vm.prank(envoy);
        policy.fromHub(POOL, abi.encode(IReserveInstantPolicy.ConfigKind.Redeemer, vault, abi.encode(who, allowed)));
    }

    function _allowSponsor(address who, bool allowed) internal {
        vm.prank(envoy);
        policy.fromHub(POOL, abi.encode(IReserveInstantPolicy.ConfigKind.Sponsor, vault, abi.encode(who, allowed)));
    }

    //----------------------------------------------------------------------------------------------
    // Configuration
    //----------------------------------------------------------------------------------------------

    function testConfigure() public {
        vm.expectEmit(true, true, false, true);
        emit IReserveInstantPolicy.SetConfig(POOL, vault, _config(1_000e6, true, 10, 25));
        _configure(1_000e6, true, 10, 25);

        (address recipient, uint16 depositFeeBps, uint16 redeemFeeBps, bool redeemEnabled,,, uint128 maxReserve) =
            policy.config(vault);
        assertEq(maxReserve, 1_000e6);
        assertTrue(redeemEnabled);
        assertEq(depositFeeBps, 10);
        assertEq(redeemFeeBps, 25);
        assertEq(recipient, feeRecipient);
    }

    function testOnlyEnvoyConfigures() public {
        vm.expectRevert(IReserveInstantPolicy.NotEnvoy.selector);
        policy.fromHub(POOL, _terms(1, true, 0, 0));
    }

    function testConfigureRejectsValue() public {
        vm.deal(envoy, 1 ether);
        vm.prank(envoy);
        vm.expectRevert(IReserveInstantPolicy.UnexpectedValue.selector);
        policy.fromHub{value: 1}(POOL, _terms(1, true, 0, 0));
    }

    /// @dev The Envoy is reachable by any pool's managers, so without the pool binding one pool could
    ///      set another pool's vault's instant caps and fees.
    function testConfigureBindsToThePoolOwningTheVault() public {
        vm.prank(envoy);
        vm.expectRevert(IReserveInstantPolicy.WrongPool.selector);
        policy.fromHub(OTHER_POOL, _terms(1, true, 0, 0));
    }

    /// @dev A vault another pool built, registered under this pool through a factory of its own
    function testConfigureRejectsAVaultBuiltForAnotherPool() public {
        vm.mockCall(vault, abi.encodeWithSelector(IVault.poolId.selector), abi.encode(OTHER_POOL));

        vm.prank(envoy);
        vm.expectRevert(IReserveInstantPolicy.WrongPool.selector);
        policy.fromHub(POOL, _terms(1, true, 0, 0));
    }

    function testConfigureRejectsFullFee() public {
        vm.prank(envoy);
        vm.expectRevert(IReserveInstantPolicy.InvalidFees.selector);
        policy.fromHub(POOL, _terms(1, true, 10_000, 0));

        vm.prank(envoy);
        vm.expectRevert(IReserveInstantPolicy.InvalidFees.selector);
        policy.fromHub(POOL, _terms(1, true, 0, 10_000));
    }

    /// @dev No recipient is how the vault is told to retain the fee in the escrow.
    function testFeesWithoutRecipientAreRetained() public {
        IReserveInstantPolicy.Config memory config_ = _config(1_000e6, true, 100, 100);
        config_.feeRecipient = address(0);
        vm.prank(envoy);
        policy.fromHub(POOL, _payload(config_));

        (int128 depositFee, address depositRecipient) =
            policy.quoteInstantDeposit(vault, investor, investor, 1_000e6, false);
        (int128 redeemFee, address redeemRecipient) =
            policy.quoteInstantRedeem(vault, investor, investor, 1_000e6, false);
        assertEq(depositFee, int128(10e6));
        assertEq(redeemFee, int128(10e6));
        assertEq(depositRecipient, address(0));
        assertEq(redeemRecipient, address(0));
    }

    function testUnknownConfigKindIsRefused() public {
        vm.prank(envoy);
        vm.expectRevert();
        policy.fromHub(POOL, abi.encode(uint8(4), vault, abi.encode(investor, true)));
    }

    function testUnconfiguredVaultHasNoInstantLane() public view {
        assertEq(policy.maxInstantDeposit(vault, investor), 0, "no deposit capacity");
        assertEq(policy.maxInstantRedeem(vault, investor), 0, "no redeem capacity");
    }

    //----------------------------------------------------------------------------------------------
    // Capacity
    //----------------------------------------------------------------------------------------------

    function testDepositCapacityIsTheReserveShortfall(uint128 maxReserve, uint128 available) public {
        maxReserve = uint128(bound(maxReserve, 1, type(uint128).max));
        _configure(maxReserve, false, 0, 0);
        _setAvailable(available);

        uint128 capacity = policy.maxInstantDeposit(vault, investor);
        if (available >= maxReserve) {
            assertEq(capacity, 0, "a full reserve takes no more");
        } else {
            assertEq(capacity, maxReserve - available, "capacity tops the escrow up to the target reserve");
        }
        // Never more than the target: depositing the capacity can only reach the reserve, not pass it.
        assertLe(uint256(capacity) + available, uint256(maxReserve) + available);
    }

    function testZeroReserveDisablesInstantDeposits() public {
        _configure(0, true, 0, 0);
        assertEq(policy.maxInstantDeposit(vault, investor), 0);
        assertEq(policy.maxInstantRedeem(vault, investor), type(uint128).max, "the redeem lane is independent");
    }

    function testRedeemCapacityIsUnboundedWhenEnabled() public {
        _configure(1, true, 0, 0);
        assertEq(policy.maxInstantRedeem(vault, investor), type(uint128).max, "escrow liquidity is the only bound");
        _configure(1, false, 0, 0);
        assertEq(policy.maxInstantRedeem(vault, investor), 0, "disabled closes the lane");
    }

    //----------------------------------------------------------------------------------------------
    // Fees
    //----------------------------------------------------------------------------------------------

    function testFeesQuoteAndCharge() public {
        _configure(1_000e6, true, 10, 25); // 0.1% in, 0.25% out

        assertEq(_quoteDeposit(1_000e6), int128(1e6), "0.1% of 1000");
        assertEq(_quoteRedeem(1_000e6), int128(2.5e6), "0.25% of 1000");

        (int128 depositFee, address depositRecipient) =
            policy.quoteInstantDeposit(vault, investor, investor, 1_000e6, false);
        (int128 redeemFee, address redeemRecipient) =
            policy.quoteInstantRedeem(vault, investor, investor, 1_000e6, false);

        assertEq(depositFee, int128(1e6), "the trade's quote names the fee");
        assertEq(redeemFee, int128(2.5e6), "the trade's quote names the fee");
        assertEq(depositRecipient, feeRecipient);
        assertEq(redeemRecipient, feeRecipient);
    }

    function testNoFeeConfiguredIsFree() public {
        _configure(1_000e6, true, 0, 0);

        assertEq(_quoteDeposit(1_000e6), int128(0));
        assertEq(_quoteRedeem(1_000e6), int128(0));
    }

    /// @dev The fee rounds up, so it cannot be rounded away by splitting one deposit into many small
    ///      ones — a floored fee would be zero for every amount below `10_000 / bps`.
    function testFeeIsNeverRoundedAway(uint128 assets, uint16 bps) public {
        bps = uint16(bound(bps, 1, 9_999));
        assets = uint128(bound(assets, 1, 1e30));
        _configure(1, true, bps, bps);

        int128 fee = _quoteDeposit(assets);
        assertGt(fee, 0, "a non-zero fee on a non-zero amount is never zero");
        assertLe(uint128(fee), assets, "and never exceeds the amount it is charged on");
        assertEq(fee, _quoteRedeem(assets), "both sides round the same way");
    }

    function testSplittingNeverPaysLessFee(uint128 assets, uint16 bps) public {
        bps = uint16(bound(bps, 1, 9_999));
        assets = uint128(bound(assets, 2, 1e30));
        _configure(1, true, bps, bps);

        uint128 half = assets / 2;
        int128 whole = _quoteDeposit(assets);
        int128 split = _quoteDeposit(half) + _quoteDeposit(assets - half);

        assertGe(split, whole, "splitting a deposit never reduces the fee paid");
    }

    /// @dev These are pure quotes: the policy is caller-agnostic, so the same amount costs the same
    ///      whoever asks. A per-identity policy would be a different implementation.
    function testQuotesAreCallerAgnostic(address a, address b, uint128 assets) public {
        assets = uint128(bound(assets, 1, 1e30));
        _configure(1_000e6, true, 42, 42);

        (int128 feeA,) = policy.quoteInstantDeposit(vault, a, a, assets, false);
        (int128 feeB,) = policy.quoteInstantDeposit(vault, b, b, assets, false);
        assertEq(feeA, feeB);
    }

    //----------------------------------------------------------------------------------------------
    // Gating
    //----------------------------------------------------------------------------------------------

    /// @dev The allowlists are inert until the manager gates the lane, so the default policy stays
    ///      open to anyone and gating is something a pool states rather than something it inherits.
    function testLanesAreUngatedByDefault() public {
        _configure(1_000e6, true, 0, 0);

        assertEq(policy.maxInstantDeposit(vault, investor), 1_000e6);
        assertEq(policy.maxInstantRedeem(vault, investor), type(uint128).max);
        policy.onInstantDeposit(vault, investor, investor, 1, false);
        policy.onInstantRedeem(vault, investor, investor, 1, false);
    }

    function testGatedDepositLaneIsClosedWhileTheAllowlistIsEmpty() public {
        _gate(true, false);

        vm.expectRevert(IReserveInstantPolicy.NotDepositor.selector);
        policy.onInstantDeposit(vault, investor, investor, 1, false);

        assertEq(policy.maxInstantRedeem(vault, investor), type(uint128).max, "the redeem lane is independent");
    }

    /// @dev The gate is the caller, never the receiver. The vault hands the capacity view the
    ///      receiver, so gating that view would close the lane on the investor the gate deposits for:
    ///      it quotes the lane, and the allowlist is enforced where the caller is visible.
    function testGatedDepositLaneNamesTheCallerNotTheReceiver() public {
        _gate(true, false);
        _allowDepositor(gate, true);

        assertEq(policy.maxInstantDeposit(vault, investor), 1_000e6, "the lane's capacity, not a permission");

        vm.expectEmit(true, true, true, true);
        emit IReserveInstantPolicy.SetAllowed(POOL, vault, gate, IReserveInstantPolicy.ConfigKind.Depositor, true);
        _allowDepositor(gate, true);

        policy.onInstantDeposit(vault, gate, investor, 600e6, false);

        vm.expectRevert(IReserveInstantPolicy.NotDepositor.selector);
        policy.onInstantDeposit(vault, investor, investor, 1, false);
    }

    function testRevokingADepositorClosesItsLane() public {
        _gate(true, false);
        _allowDepositor(gate, true);
        policy.onInstantDeposit(vault, gate, investor, 1, false);

        _allowRedeemer(gate, true);
        _allowDepositor(gate, false);

        vm.expectRevert(IReserveInstantPolicy.NotDepositor.selector);
        policy.onInstantDeposit(vault, gate, investor, 1, false);
    }

    function testGatedRedeemLaneNamesTheCaller() public {
        _gate(false, true);
        vm.expectEmit(address(policy));
        emit IReserveInstantPolicy.SetAllowed(POOL, vault, investor, IReserveInstantPolicy.ConfigKind.Redeemer, true);
        _allowRedeemer(investor, true);

        policy.onInstantRedeem(vault, investor, investor, 1, false);

        vm.expectRevert(IReserveInstantPolicy.NotRedeemer.selector);
        policy.onInstantRedeem(vault, gate, gate, 1, false);
    }

    /// @dev The redeem view names the owner, who is also the caller of an instant redeem, so it reports none
    ///      where the gate would refuse that owner.
    function testGatedRedeemViewReportsNothingOffTheAllowlist() public {
        _gate(false, true);
        assertEq(policy.maxInstantRedeem(vault, investor), 0, "the owner is not on the list");

        _allowRedeemer(investor, true);
        assertEq(policy.maxInstantRedeem(vault, investor), type(uint128).max);
        assertEq(policy.maxInstantRedeem(vault, gate), 0, "the allowlist names one owner");
    }

    /// @dev A closed switch and an empty allowlist are different statements, and either one closes.
    function testDisabledRedeemLaneIgnoresTheAllowlist() public {
        _configure(1_000e6, false, 0, 0);
        _allowRedeemer(investor, true);

        assertEq(policy.maxInstantRedeem(vault, investor), 0, "the switch is what the view reports");
    }

    /// @dev The lanes are independent: an entry gate is not an exit gate.
    function testTheLanesDoNotShareTheirAllowlist() public {
        _gate(true, true);
        _allowDepositor(gate, true);

        policy.onInstantDeposit(vault, gate, investor, 1, false);
        vm.expectRevert(IReserveInstantPolicy.NotRedeemer.selector);
        policy.onInstantRedeem(vault, gate, investor, 1, false);
    }

    function testGatingIsPerVault() public {
        address other = address(new IsContract());
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.vaultDetails.selector, other),
            abi.encode(VaultDetails(POOL, SC, newAssetId(0, 1), asset, uint256(0), true))
        );
        vm.mockCall(other, abi.encodeWithSelector(IVault.poolId.selector), abi.encode(POOL));
        vm.mockCall(other, abi.encodeWithSelector(IVault.scId.selector), abi.encode(SC));
        _gate(true, false);
        _allowDepositor(gate, true);

        assertTrue(policy.isAllowed(vault, IReserveInstantPolicy.ConfigKind.Depositor, gate));
        assertFalse(
            policy.isAllowed(other, IReserveInstantPolicy.ConfigKind.Depositor, gate),
            "an allowlist entry names one vault"
        );
        assertFalse(policy.isAllowed(vault, IReserveInstantPolicy.ConfigKind.Redeemer, gate), "and one list");
    }

    /// @dev There is no switch to open crediting: the vault asks only on a vault with both lanes, and there only a
    ///      sponsor the pool allowed for that vault may fund a position for someone else.
    function testOnlyAllowedSponsorsCredit() public {
        _configure(1_000e6, true, 0, 0);
        assertFalse(policy.canCredit(vault, investor, gate), "nobody by default");

        vm.expectEmit();
        emit IReserveInstantPolicy.SetAllowed(POOL, vault, investor, IReserveInstantPolicy.ConfigKind.Sponsor, true);
        _allowSponsor(investor, true);
        assertTrue(policy.canCredit(vault, investor, gate));
        assertTrue(policy.isAllowed(vault, IReserveInstantPolicy.ConfigKind.Sponsor, investor));
        assertFalse(policy.canCredit(makeAddr("otherVault"), investor, gate), "a sponsor of one vault only");

        _allowSponsor(investor, false);
        assertFalse(policy.canCredit(vault, investor, gate), "removing a sponsor closes it again");
    }

    function testOnlyTheEnvoySetsSponsors() public {
        vm.expectRevert(IReserveInstantPolicy.NotEnvoy.selector);
        policy.fromHub(POOL, abi.encode(IReserveInstantPolicy.ConfigKind.Sponsor, vault, abi.encode(investor, true)));
    }

    /// @dev Exact-out grosses the net up, so the fee is never below the configured rate of the gross it is
    ///      charged on, and never above an exact-in call on that gross.
    function testExactOutChargesTheRateOfItsGross(uint16 feeBps, uint128 net) public {
        feeBps = uint16(bound(feeBps, 0, 9_999));
        net = uint128(bound(net, 1, type(uint64).max));
        _configure(1_000e6, true, feeBps, feeBps);

        (int128 fee,) = policy.quoteInstantDeposit(vault, investor, investor, net, true);
        uint256 gross = uint256(net) + uint128(fee);
        assertGe(uint128(fee) * 10_000, gross * feeBps, "at least the configured rate");

        (int128 feeIn,) = policy.quoteInstantDeposit(vault, investor, investor, uint128(gross), false);
        assertLe(uint128(fee), uint128(feeIn), "and no more than the exact-in fee on the gross");
    }
}
