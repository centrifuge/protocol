// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyProtection} from "../../../src/misc/ReentrancyProtection.sol";

import "forge-std/Test.sol";

interface IVictim {
    function exit() external;
}

/// @dev A venue reached through a route, whose callback hands control back to the attacker.
contract Venue {
    address public callback;

    function set(address c) external {
        callback = c;
    }

    function swap() external {
        (bool ok, bytes memory err) = callback.call(abi.encodeWithSignature("onSwap()"));
        // Bubble the original revert, so a guard's error reaches the test rather than a wrapper's
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(32, err), mload(err))
            }
        }
    }
}

contract ProtectedVictim is ReentrancyProtection {
    Venue public immutable venue;
    uint256 public exits;

    constructor(Venue venue_) {
        venue = venue_;
    }

    function exit() external protected {
        exits++;
        venue.swap();
    }
}

contract GuardedVictim is ReentrancyProtection {
    Venue public immutable venue;
    uint256 public exits;

    constructor(Venue venue_) {
        venue = venue_;
    }

    function exit() external nonReentrant {
        exits++;
        venue.swap();
    }
}

/// @dev Both the outer caller and the account the venue's callback returns control to.
contract Attacker {
    IVictim internal victim;
    bool internal reentered;

    function go(IVictim victim_) external {
        victim = victim_;
        victim_.exit();
    }

    function onSwap() external {
        if (reentered) return;
        reentered = true;
        victim.exit();
    }
}

/// @dev Why `nonReentrant` exists beside `protected`, which cannot replace it.
contract ReentrancyProtectionTest is Test {
    Venue venue = new Venue();
    Attacker attacker = new Attacker();

    function setUp() public {
        venue.set(address(attacker));
    }

    /// @dev `protected` sets `_initiator` on the outer call, so a re-entrant call finds it non-zero
    ///      and takes the multicall branch. That branch only requires the same `msg.sender`, which an
    ///      attacker who is both the caller and the venue satisfies. No multicall is involved.
    function testProtectedAdmitsAReentrantCallFromTheSameSender() public {
        ProtectedVictim victim = new ProtectedVictim(venue);

        attacker.go(IVictim(address(victim)));

        assertEq(victim.exits(), 2, "protected admitted the second entry");
    }

    function testTheStrictGuardRefusesIt() public {
        GuardedVictim victim = new GuardedVictim(venue);

        vm.expectRevert(ReentrancyProtection.Reentrancy.selector);
        attacker.go(IVictim(address(victim)));
    }
}
