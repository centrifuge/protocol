// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {IEscrow} from "../../../src/core/spoke/interfaces/IEscrow.sol";
import {IEscrowProvider} from "../../../src/core/spoke/factories/interfaces/IEscrowFactory.sol";

contract MockEscrowProvider is IEscrowProvider {
    mapping(uint64 => address) internal _escrows;
    mapping(address => PoolId) internal _poolIds;

    function setEscrow(PoolId poolId_, address escrow_) external {
        _escrows[poolId_.raw()] = escrow_;
        _poolIds[escrow_] = poolId_;
    }

    function escrow(PoolId poolId_) external view returns (IEscrow) {
        return IEscrow(_escrows[poolId_.raw()]);
    }

    function poolId(address escrow_) external view returns (PoolId) {
        return _poolIds[escrow_];
    }
}
