// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IGasService {
    event File(bytes32 indexed what, uint64 value);

    error FileUnrecognizedParam();

    /// @notice Using file patter to update state variables;
    /// @dev    Used to update the messageGasLimit and proofGasLimit;
    ///         It is used in occasions where update is done rarely.
    function file(bytes32 what, uint64 value) external;

    /// @notice The cost of 'message' execution on the recipient chain.
    /// @dev    This is a getter method
    /// @return Amount in gas
    function messageGasLimit() external returns (uint64);

    /// @notice The cost of 'proof' execution on the recipient chain.
    /// @dev    This is a getter method
    /// @return Amount in gas
    function proofGasLimit() external returns (uint64);

    /// @notice Estimate the total execution cost on the recipient chain in ETH.
    /// @dev    Currently payload is disregarded and not included in the calculation.
    /// @param  payload Estimates the execution cost based on the payload
    /// @return Estimated cost in WEI units
    function estimate(uint32 chainId, bytes calldata payload) external view returns (uint256);

    /// @notice Used to verify if given user for a given message can take advantage of
    ///         transaction cost prepayment.
    /// @dev    This is used in the Gateway to check if the source of the transaction
    ///         is eligible for tx cost payment from Gateway's balance.
    /// @param  source Source that triggered the transaction
    /// @param  payload The message that is going to be send
    function shouldRefuel(address source, bytes calldata payload) external returns (bool);
}
