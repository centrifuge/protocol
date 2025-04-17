// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IPoolEscrow} from "src/vaults/interfaces/IEscrow.sol";

interface IPoolEscrowProvider {
    /// @notice Returns the deterministic address of an escrow contract based on a given pool id wrapped into the
    /// corresponding interface.
    ///
    /// @dev Does not check, whether the escrow was already deployed.
    function escrow(uint64 poolId) external view returns (IPoolEscrow);

    /// @notice Returns the address of the corresponding deployed escrow contract if it exists
    function deployedEscrow(uint64 poolId) external view returns (address);
}

interface IPoolEscrowFactory is IPoolEscrowProvider {
    event DeployPoolEscrow(uint64 indexed poolId, address indexed escrow);
    event File(bytes32 what, address data);

    error FileUnrecognizedParam();
    error EscrowAlreadyDeployed();

    /// @notice Deploys new escrow and returns it.
    /// @dev All share classes of a pool are represented by the same escrow contract.
    ///
    /// @param poolId Id of the pool this escrow is deployed for
    /// @return IPoolEscrow The the newly deployed escrow contract
    function newEscrow(uint64 poolId) external returns (IPoolEscrow);

    /// @notice Updates contract parameters of type address.
    function file(bytes32 what, address data) external;
}
