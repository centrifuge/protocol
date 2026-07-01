// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../../core/types/PoolId.sol";
import {ShareClassId} from "../../../core/types/ShareClassId.sol";
import {IBridgingHook} from "../../../core/hub/interfaces/IBridgingHook.sol";

import {ICircuitBreakerGuard} from "../../../managers/spoke/guards/interfaces/ICircuitBreakerGuard.sol";

interface IBridgeCircuitBreaker is IBridgingHook {
    enum ConfigKind {
        SetPaused,
        SetRateLimit,
        AuthorizeTransfer,
        CancelTransferAuthorizations
    }

    struct Limits {
        /// @dev Max transfer amount per window per origin chain. 0 = no transfers (all require explicit authorization).
        uint128 rateMax;
        /// @dev Time window for rate limit in seconds
        uint32 rateWindow;
    }

    event SetPaused(PoolId indexed poolId, ShareClassId indexed scId, bool isPaused);
    event SetRateLimit(
        PoolId indexed poolId, ShareClassId indexed scId, uint16 indexed centrifugeId, uint128 max, uint32 windowSeconds
    );
    event AuthorizeTransfer(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        uint16 indexed centrifugeId,
        bytes32 sender,
        bytes32 receiver,
        uint128 amount
    );
    event CancelTransferAuthorizations(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        uint16 indexed centrifugeId,
        bytes32 sender,
        bytes32 receiver,
        uint128 amount
    );

    error NotAuthorized();
    error NotEnvoy();
    error UnexpectedValue();
    error Paused();
    error UnknownConfigKind();
    error TransferNotAuthorized();

    function hubHandler() external view returns (address);
    function circuitBreakerGuard() external view returns (ICircuitBreakerGuard);

    /// @notice Whether transfers for a given (pool, share class) are currently paused.
    function paused(PoolId poolId, ShareClassId scId) external view returns (bool);

    /// @notice Per-chain rate limit for a given (pool, share class, centrifugeId).
    function limits(PoolId poolId, ShareClassId scId, uint16 centrifugeId)
        external
        view
        returns (uint128 rateMax, uint32 rateWindow);

    /// @notice Number of times a specific large transfer has been authorized to bypass the rate limit.
    ///         Keyed by keccak256(abi.encode(poolId, scId, centrifugeId, sender, receiver, amount)).
    ///         Each authorization allows one transfer; the count is decremented on use.
    function authorizations(bytes32 key) external view returns (uint256);
}
