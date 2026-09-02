// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IBridgeCircuitBreaker} from "./interfaces/IBridgeCircuitBreaker.sol";

import {Auth} from "../../misc/Auth.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {IManagerCallFromHub} from "../../core/utils/interfaces/IManagerCall.sol";
import {IBridgingHook, BridgeSharesParams, BridgeSharesResult} from "../../core/hub/interfaces/IBridgingHook.sol";

import {ICircuitBreakerGuard} from "../../managers/spoke/guards/interfaces/ICircuitBreakerGuard.sol";

/// @title  BridgeCircuitBreaker
/// @notice Combines pausing and a fixed-window rate limit into one hook. Both checks run on every transfer.
///         Transfers whose single amount exceeds rateMax can never pass the rate limit organically; a hub
///         manager must explicitly authorize them via AuthorizeTransfer before retrying.
contract BridgeCircuitBreaker is Auth, IManagerCallFromHub, IBridgeCircuitBreaker {
    address public immutable envoy;
    ICircuitBreakerGuard public immutable circuitBreakerGuard;

    mapping(bytes32 => uint256) public authorizations;
    mapping(PoolId => mapping(ShareClassId => bool)) public paused;
    mapping(PoolId => mapping(ShareClassId => mapping(uint16 => Limits))) public limits;

    constructor(address envoy_, address circuitBreakerGuard_, address deployer) Auth(deployer) {
        envoy = envoy_;
        circuitBreakerGuard = ICircuitBreakerGuard(circuitBreakerGuard_);
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IManagerCallFromHub
    function fromHub(PoolId poolId, bytes calldata payload) external payable {
        require(msg.sender == envoy, NotEnvoy());
        require(msg.value == 0, UnexpectedValue());

        uint8 kindValue = abi.decode(payload, (uint8));
        if (kindValue == uint8(ConfigKind.SetPaused)) {
            (, bytes16 scId_, bool isPaused) = abi.decode(payload, (uint8, bytes16, bool));
            ShareClassId scId = ShareClassId.wrap(scId_);
            paused[poolId][scId] = isPaused;
            emit SetPaused(poolId, scId, isPaused);
        } else if (kindValue == uint8(ConfigKind.SetRateLimit)) {
            (, bytes16 scId_, uint16 centrifugeId, uint128 max, uint32 windowSeconds) =
                abi.decode(payload, (uint8, bytes16, uint16, uint128, uint32));
            ShareClassId scId = ShareClassId.wrap(scId_);
            limits[poolId][scId][centrifugeId].rateMax = max;
            limits[poolId][scId][centrifugeId].rateWindow = windowSeconds;
            emit SetRateLimit(poolId, scId, centrifugeId, max, windowSeconds);
        } else if (kindValue == uint8(ConfigKind.AuthorizeTransfer)) {
            (
                ,
                bytes16 scId_,
                uint16 originCentrifugeId,
                uint16 targetCentrifugeId,
                bytes32 sender,
                bytes32 receiver,
                uint128 amount
            ) = abi.decode(payload, (uint8, bytes16, uint16, uint16, bytes32, bytes32, uint128));
            ShareClassId scId = ShareClassId.wrap(scId_);
            bytes32 key = _authKey(poolId, scId, originCentrifugeId, targetCentrifugeId, sender, receiver, amount);
            authorizations[key]++;
            emit AuthorizeTransfer(poolId, scId, originCentrifugeId, targetCentrifugeId, sender, receiver, amount);
        } else if (kindValue == uint8(ConfigKind.CancelTransferAuthorizations)) {
            (
                ,
                bytes16 scId_,
                uint16 originCentrifugeId,
                uint16 targetCentrifugeId,
                bytes32 sender,
                bytes32 receiver,
                uint128 amount
            ) = abi.decode(payload, (uint8, bytes16, uint16, uint16, bytes32, bytes32, uint128));
            ShareClassId scId = ShareClassId.wrap(scId_);
            bytes32 key = _authKey(poolId, scId, originCentrifugeId, targetCentrifugeId, sender, receiver, amount);
            delete authorizations[key];
            emit CancelTransferAuthorizations(
                poolId, scId, originCentrifugeId, targetCentrifugeId, sender, receiver, amount
            );
        } else {
            revert UnknownConfigKind();
        }
    }

    //----------------------------------------------------------------------------------------------
    // Hook call
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IBridgingHook
    function onBridgeShares(BridgeSharesParams calldata p) external auth returns (BridgeSharesResult memory) {
        require(!paused[p.poolId][p.scId], Paused());

        _consumeRateLimit(p);

        return
            BridgeSharesResult({
                receiver: p.receiver, amount: p.amount, extraGasLimit: p.extraGasLimit, refund: p.refund
            });
    }

    /// @dev Authorized transfers bypass all rate limiting. Unauthorized transfers are tallied
    ///      against the fixed window; the guard reverts if the cumulative total is exceeded.
    function _consumeRateLimit(BridgeSharesParams calldata p) private {
        bytes32 key =
            _authKey(p.poolId, p.scId, p.originCentrifugeId, p.targetCentrifugeId, p.sender, p.receiver, p.amount);
        if (authorizations[key] > 0) {
            authorizations[key]--;
            return;
        }

        Limits memory l = limits[p.poolId][p.scId][p.originCentrifugeId];
        require(p.amount <= l.rateMax, TransferNotAuthorized());
        circuitBreakerGuard.tally(
            keccak256(abi.encode(p.poolId, p.scId, p.originCentrifugeId)), p.amount, l.rateMax, l.rateWindow
        );
    }

    function _authKey(
        PoolId poolId,
        ShareClassId scId,
        uint16 originCentrifugeId,
        uint16 targetCentrifugeId,
        bytes32 sender,
        bytes32 receiver,
        uint128 amount
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(poolId, scId, originCentrifugeId, targetCentrifugeId, sender, receiver, amount));
    }
}
