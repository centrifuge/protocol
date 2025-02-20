// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

function previewAddress(address deployer, bytes32 salt, bytes memory bytecode) pure returns (address instance) {
    instance = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(bytecode))))));
}
