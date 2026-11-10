// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {VaultActionLib, VaultActionKind, VaultAction} from "../../../src/vaults/libraries/VaultActionLib.sol";

import {MaxPositionHook} from "../mocks/MaxPositionHook.sol";

import "forge-std/Test.sol";

import {RoleCheck} from "../../../src/token/interfaces/IRoleHook.sol";

contract CapToken {
    mapping(address => uint256) public balanceOf;

    function set(address who, uint256 amount) external {
        balanceOf[who] = amount;
    }
}

/// @dev A vault's views at a share price of 1e12 shares per asset unit.
contract CapVault {
    mapping(address => uint256) public pendingDepositRequest_;
    mapping(address => uint256) public claimableMint;
    mapping(address => uint256) public pendingRedeemRequest_;

    function pendingRedeemRequest(uint256, address who) external view returns (uint256) {
        return pendingRedeemRequest_[who];
    }

    function setRedeem(address who, uint256 pending) external {
        pendingRedeemRequest_[who] = pending;
    }

    function pendingDepositRequest(uint256, address who) external view returns (uint256) {
        return pendingDepositRequest_[who];
    }

    function convertToShares(uint256 assets) external pure returns (uint256) {
        return assets * 1e12;
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares / 1e12;
    }

    function set(address who, uint256 pending, uint256 claimable) external {
        pendingDepositRequest_[who] = pending;
        claimableMint[who] = claimable;
    }
}

/// @dev A limit on a position needs no vault action kinds: each check says how much is new to the account, and the
///      hook adds that to what it reads.
contract MaxPositionHookTest is Test {
    uint256 constant CAP = 1_000e18;

    CapToken token = new CapToken();
    CapVault vault = new CapVault();
    MaxPositionHook hook;

    address controller = makeAddr("controller");
    address owner = makeAddr("owner");
    address receiver = makeAddr("receiver");

    function setUp() public {
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        hook = new MaxPositionHook(CAP, vaults);
    }

    /// @dev Asks as the vault does, the shares given and the assets they are worth at the mock's price.
    function _act(VaultActionKind kind, address c, address o, address r, uint128 shares) internal returns (bool) {
        vm.prank(address(vault));
        return
            hook.checkRoles(
                address(token), VaultActionLib.roleChecks(VaultAction(kind, c, o, r, shares / 1e12, shares))
            );
    }

    function _maxShares(VaultActionKind kind, address c, address o, address r) internal returns (uint256 maxShares) {
        vm.prank(address(vault));
        (, maxShares) = hook.maxAllowed(
            address(token), VaultActionLib.roleChecks(VaultAction(kind, c, o, r, type(uint128).max, type(uint128).max))
        );
    }

    function testADepositRequestWithinTheLimitPasses() public {
        assertTrue(_act(VaultActionKind.DepositRequest, controller, owner, controller, 1_000e18));
    }

    function testADepositRequestOverTheLimitIsRefused() public {
        assertFalse(_act(VaultActionKind.DepositRequest, controller, owner, controller, 1_000e18 + 1));
    }

    function testAPendingRequestCountsTowardsTheLimit() public {
        vault.set(controller, 600e6, 0);
        assertTrue(_act(VaultActionKind.DepositRequest, controller, owner, controller, 400e18));
        assertFalse(_act(VaultActionKind.DepositRequest, controller, owner, controller, 400e18 + 1));
    }

    function testHeldSharesAndClaimableSharesCountTowardsTheLimit() public {
        token.set(controller, 300e18);
        vault.set(controller, 0, 200e18);
        assertTrue(_act(VaultActionKind.DepositRequest, controller, owner, controller, 500e18));
        assertFalse(_act(VaultActionKind.DepositRequest, controller, owner, controller, 500e18 + 1));
    }

    /// @dev A pending redemption is still in the position, so a holder at the cap cannot request its way to room and
    ///      then have the redemption cancelled back into claimable shares.
    function testAPendingRedemptionCountsTowardsTheLimit() public {
        vault.setRedeem(controller, 1_000e18);
        assertFalse(_act(VaultActionKind.DepositRequest, controller, owner, controller, 1));
        // and the redeem request that put it there grows nothing
        token.set(owner, 1_000e18);
        assertTrue(_act(VaultActionKind.RedeemRequest, owner, owner, address(0), 1_000e18));
    }

    function testAHolderOverTheLimitCanStillClaimItsOwnPosition() public {
        // The position is over the limit, say a price move: its claim only moves what the position already counts
        token.set(controller, 900e18);
        vault.set(controller, 0, 400e18);
        assertTrue(_act(VaultActionKind.DepositClaim, controller, address(0), controller, 400e18));
    }

    function testAClaimDeliveredToAnotherReceiverCountsForTheReceiver() public {
        assertTrue(_act(VaultActionKind.DepositClaim, controller, address(0), receiver, 1_000e18));
        assertFalse(_act(VaultActionKind.DepositClaim, controller, address(0), receiver, 1_000e18 + 1));
        token.set(receiver, 1);
        assertFalse(_act(VaultActionKind.DepositClaim, controller, address(0), receiver, 1_000e18));
    }

    function testAnInstantDepositIsLimitedOnTheReceiverNotTheOwnerPassingItOn() public {
        // The owner is over the limit and only passes the value on
        token.set(owner, 5_000e18);
        assertTrue(_act(VaultActionKind.InstantDeposit, owner, owner, receiver, 1_000e18));
        assertFalse(_act(VaultActionKind.InstantDeposit, owner, owner, receiver, 1_000e18 + 1));
        // Its own position is limited when it is the receiver
        assertFalse(_act(VaultActionKind.InstantDeposit, owner, owner, owner, 1));
    }

    function testARequestTransferIsLimitedOnTheReceiver() public {
        vault.set(receiver, 0, 800e18);
        assertTrue(_act(VaultActionKind.DepositRequestTransfer, owner, owner, receiver, 200e18));
        assertFalse(_act(VaultActionKind.DepositRequestTransfer, owner, owner, receiver, 200e18 + 1));
        // A pending redemption moved to the receiver is an exit, which a cap never refuses
        assertTrue(_act(VaultActionKind.RedeemRequestTransfer, owner, owner, receiver, 200e18 + 1));
    }

    /// @dev An omnibus controller at the cap still takes the redemptions of its owners, so they can leave.
    function testARedeemRequestToAControllerAtTheCapIsNotRefused() public {
        token.set(controller, CAP);
        assertTrue(_act(VaultActionKind.RedeemRequest, controller, owner, address(0), 100e18));
        assertEq(_maxShares(VaultActionKind.RedeemRequest, owner, owner, controller), type(uint256).max);
    }

    function testExitsPayoutsAndRefundsAreNeverLimited() public {
        token.set(controller, 5_000e18);
        assertTrue(_act(VaultActionKind.RedeemRequest, controller, controller, address(0), 5_000e18));
        assertTrue(_act(VaultActionKind.RedeemClaim, controller, address(0), controller, 5_000e18));
        assertTrue(_act(VaultActionKind.InstantRedeem, controller, controller, controller, 5_000e18));
        assertTrue(_act(VaultActionKind.DepositRefundClaim, controller, address(0), controller, 5_000e18));
        assertTrue(_act(VaultActionKind.RedeemRefundClaim, controller, address(0), controller, 5_000e18));
    }

    function testOnRolesRevertsWhatCheckRolesRefuses() public {
        RoleCheck[] memory checks = VaultActionLib.roleChecks(
            VaultAction(VaultActionKind.DepositRequest, controller, owner, controller, 1_000e6, 1_000e18 + 1)
        );
        vm.prank(address(vault));
        vm.expectRevert(MaxPositionHook.MaxPositionExceeded.selector);
        hook.onRoles(address(token), checks);
    }

    function testMaxAllowedIsTheRoomUnderTheCap() public {
        token.set(controller, 300e18);
        vault.set(controller, 200e6, 100e18);
        // 1_000 - 300 - 200 - 100 shares of room
        assertEq(_maxShares(VaultActionKind.DepositRequest, controller, owner, controller), 400e18);
        assertEq(_maxShares(VaultActionKind.DepositClaim, owner, address(0), controller), 400e18);
        // What it allows passes, one more does not
        assertTrue(_act(VaultActionKind.DepositRequest, controller, owner, controller, 400e18));
        assertFalse(_act(VaultActionKind.DepositRequest, controller, owner, controller, 400e18 + 1));
    }

    function testMaxAllowedSetsNoLimitOnWhatDoesNotGrowAPosition() public {
        token.set(controller, 5_000e18);
        assertEq(_maxShares(VaultActionKind.InstantRedeem, controller, controller, controller), type(uint256).max);
        assertEq(_maxShares(VaultActionKind.DepositClaim, controller, address(0), controller), type(uint256).max);
    }

    function testMaxAllowedOfAHolderOverTheCapIsZero() public {
        token.set(receiver, 2_000e18);
        assertEq(_maxShares(VaultActionKind.InstantDeposit, owner, owner, receiver), 0);
    }
}
