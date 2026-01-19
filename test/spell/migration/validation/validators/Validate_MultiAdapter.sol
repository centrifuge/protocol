// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Spoke} from "../../../../../src/core/spoke/Spoke.sol";
import {PoolId} from "../../../../../src/core/types/PoolId.sol";
import {HubRegistry} from "../../../../../src/core/hub/HubRegistry.sol";
import {MultiAdapter} from "../../../../../src/core/messaging/MultiAdapter.sol";
import {IAdapter} from "../../../../../src/core/messaging/interfaces/IAdapter.sol";

import {BaseValidator} from "../BaseValidator.sol";

/// @title Validate_MultiAdapter
/// @notice Validates that adapter configurations for all pools match GLOBAL_POOL (pool 0)
/// @dev POST: Ensures all pools use the same adapter configuration as the global default
contract Validate_MultiAdapter is BaseValidator {
    PoolId public constant GLOBAL_POOL = PoolId.wrap(0);
    ValidationError[] errors;

    function supportedPhases() public pure override returns (Phase) {
        return Phase.POST;
    }

    function name() public pure override returns (string memory) {
        return "MultiAdapter";
    }

    function validate(ValidationContext memory ctx) public override returns (ValidationResult memory) {
        MultiAdapter multiAdapter = ctx.latest.core.multiAdapter;

        for (uint256 i; i < ctx.pools.length; i++) {
            PoolId poolId = ctx.pools[i];

            bool inHub = HubRegistry(ctx.old.inner.hubRegistry).exists(poolId);
            bool inSpoke = Spoke(ctx.old.inner.spoke).isPoolActive(poolId);

            if (inHub) {
                uint16[] memory centrifugeIds = ctx.queryService.chainsWherePoolIsNotified(poolId);
                for (uint256 j; j < centrifugeIds.length; j++) {
                    uint16 centrifugeId = centrifugeIds[j];

                    // The hub is connected to all spokes notified except the hub
                    if (poolId.centrifugeId() != centrifugeId) {
                        _checkPoolAdapters(multiAdapter, centrifugeId, poolId, true);
                    }
                }
            }

            if (inSpoke) {
                // The spoke always connected to its hub
                if (poolId.centrifugeId() != multiAdapter.localCentrifugeId()) {
                    _checkPoolAdapters(multiAdapter, poolId.centrifugeId(), poolId, false);
                }
            }
        }

        return ValidationResult({
            passed: errors.length == 0, validatorName: "MultiAdapter (POST)", errors: _trimErrors(errors, errors.length)
        });
    }

    function _checkPoolAdapters(MultiAdapter multiAdapter, uint16 centrifugeId, PoolId poolId, bool isHub) internal {
        uint8 globalQuorum = multiAdapter.quorum(centrifugeId, GLOBAL_POOL);
        uint8 poolQuorum = multiAdapter.quorum(centrifugeId, poolId);

        string memory poolIdStr = _toString(PoolId.unwrap(poolId));

        // Check quorum matches
        if (poolQuorum != globalQuorum) {
            errors.push(
                _buildError({
                    field: "quorum",
                    value: string.concat("Pool ", poolIdStr),
                    expected: _toString(globalQuorum),
                    actual: _toString(poolQuorum),
                    message: string.concat(
                        "Pool ",
                        isHub ? "(hub side) " : "(spoke side) ",
                        poolIdStr,
                        " quorum (",
                        _toString(poolQuorum),
                        ") does not match GLOBAL_POOL (",
                        _toString(globalQuorum),
                        ")"
                    )
                })
            );
        }

        // Check threshold matches
        {
            uint8 globalThreshold = multiAdapter.threshold(centrifugeId, GLOBAL_POOL);
            uint8 poolThreshold = multiAdapter.threshold(centrifugeId, poolId);
            if (poolThreshold != globalThreshold) {
                errors.push(
                    _buildError({
                        field: "threshold",
                        value: string.concat("Pool ", poolIdStr),
                        expected: _toString(globalThreshold),
                        actual: _toString(poolThreshold),
                        message: string.concat(
                            "Pool ",
                            isHub ? "(hub side) " : "(spoke side) ",
                            poolIdStr,
                            " threshold (",
                            _toString(poolThreshold),
                            ") does not match GLOBAL_POOL (",
                            _toString(globalThreshold),
                            ")"
                        )
                    })
                );
            }
        }

        // Check recoveryIndex matches
        {
            uint8 globalRecoveryIndex = multiAdapter.recoveryIndex(centrifugeId, GLOBAL_POOL);
            uint8 poolRecoveryIndex = multiAdapter.recoveryIndex(centrifugeId, poolId);
            if (poolRecoveryIndex != globalRecoveryIndex) {
                errors.push(
                    _buildError({
                        field: "recoveryIndex",
                        value: string.concat("Pool ", poolIdStr),
                        expected: _toString(globalRecoveryIndex),
                        actual: _toString(poolRecoveryIndex),
                        message: string.concat(
                            "Pool ",
                            isHub ? "(hub side) " : "(spoke side) ",
                            poolIdStr,
                            " recoveryIndex (",
                            _toString(poolRecoveryIndex),
                            ") does not match GLOBAL_POOL (",
                            _toString(globalRecoveryIndex),
                            ")"
                        )
                    })
                );
            }
        }

        // Check adapter addresses match (only if quorum matches)
        if (poolQuorum == globalQuorum) {
            IAdapter[] memory globalAdapters = new IAdapter[](globalQuorum);
            for (uint8 q = 0; q < globalQuorum; q++) {
                globalAdapters[q] = multiAdapter.adapters(centrifugeId, GLOBAL_POOL, q);
            }

            for (uint8 q = 0; q < poolQuorum; q++) {
                IAdapter poolAdapter = multiAdapter.adapters(centrifugeId, poolId, q);
                if (poolAdapter != globalAdapters[q]) {
                    errors.push(
                        _buildError({
                            field: string.concat("adapters[", _toString(q), "]"),
                            value: string.concat("Pool ", poolIdStr),
                            expected: vm.toString(address(globalAdapters[q])),
                            actual: vm.toString(address(poolAdapter)),
                            message: string.concat(
                                "Pool ",
                                isHub ? "(hub side) " : "(spoke side) ",
                                poolIdStr,
                                " adapter[",
                                _toString(q),
                                "] does not match GLOBAL_POOL"
                            )
                        })
                    );
                }
            }
        }
    }
}
