// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "../../misc/Auth.sol";

import {PoolId} from "../../common/types/PoolId.sol";
import {IAsyncRequestManager} from "../interfaces/IVaultManagers.sol";

import {RefundEscrow, IRefundEscrow} from "../RefundEscrow.sol";
import {IRefundEscrowFactory} from "./interfaces/IRefundEscrowFactory.sol";

contract RefundEscrowFactory is Auth, IRefundEscrowFactory {
    address public controller;

    constructor(address deployer) Auth(deployer) {}

    function file(bytes32 what, address data) external auth {
        if (what == "controller") controller = data;
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    function newEscrow(PoolId poolId) external auth returns (IRefundEscrow escrow) {
        escrow = new RefundEscrow{salt: bytes32(uint256(poolId.raw()))}(address(controller));
        emit DeployRefundEscrow(poolId, address(escrow));
    }

    function get(PoolId poolId) public view returns (IRefundEscrow) {
        bytes32 salt = bytes32(uint256(poolId.raw()));
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(abi.encodePacked(type(RefundEscrow).creationCode, abi.encode(address(controller))))
            )
        );

        return IRefundEscrow(address(uint160(uint256(hash))));
    }
}
