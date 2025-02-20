// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IPrecompile {
    function execute(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) external;
}
