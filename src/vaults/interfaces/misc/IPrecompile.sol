// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

interface IPrecompile {
    function execute(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) external;
}
