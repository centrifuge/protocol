// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {Escrow} from "src/vaults/Escrow.sol";

contract EscrowWrapper is Escrow {
    constructor(address deployer) Escrow(deployer) {}
    
    // function getReservedAmount(uint64 poolId, bytes16 scId, address token, uint256 tokenId) public view returns (uint256) {
    //     return reservedAmount[poolId][scId][token][tokenId];
    // }

    // function getHolding(uint64 poolId, bytes16 scId, address token, uint256 tokenId) public view returns (uint256) {
    //     return holding[poolId][scId][token][tokenId];
    // }
}
