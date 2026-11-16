// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @dev A pool's vault the liquidity route is told to draw on, answering every call as its mode says: nothing, a
///      revert, a 300 kB payload, or the largest number. The route trusts nothing it reads from it, and this is the
///      test that it does not.
contract HostileUnderlying {
    uint8 public mode;
    uint64 public immutable poolId;
    bytes16 public immutable scId;

    /// @dev The position it is registered under, which the registry reads from a vault before it records it. The
    ///      rest of what it says is hostile.
    constructor(uint64 poolId_, bytes16 scId_) {
        poolId = poolId_;
        scId = scId_;
    }

    function setMode(uint8 mode_) external {
        mode = mode_;
    }

    fallback() external {
        uint8 m = mode;
        if (m == 1) revert("hostile");
        if (m == 2) {
            assembly {
                return(0, 300000)
            }
        }
        if (m == 3) {
            assembly {
                mstore(0, not(0))
                return(0, 32)
            }
        }
        assembly {
            mstore(0, 0)
            return(0, 32)
        }
    }
}
