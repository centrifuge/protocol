// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface ICreateXLike {
    /// @notice Deploys `initCode` through CREATE3, at an address derived from the caller and `salt` only
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address target);
}
