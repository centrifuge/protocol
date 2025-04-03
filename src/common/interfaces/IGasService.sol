// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IGasService {
    event File(bytes32 indexed what, uint64 value);

    error FileUnrecognizedParam();

    /// @notice Gas limit for the execution cost of an individual message in a remote chain.
    /// @param chainId Where to the cost is defined
    /// @param message Individual message
    /// @return Estimated cost in WEI units
    function gasLimit(uint16 chainId, bytes calldata message) external view returns (uint64);
}
