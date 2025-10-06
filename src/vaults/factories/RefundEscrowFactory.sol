// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IRefundEscrowFactory} from "./interfaces/IRefundEscrowFactory.sol";

import {Auth} from "../../misc/Auth.sol";
import {IAuth} from "../../misc/interfaces/IAuth.sol";

import {PoolId} from "../../core/types/PoolId.sol";

import {RefundEscrow, IRefundEscrow} from "../RefundEscrow.sol";

contract RefundEscrowFactory is Auth, IRefundEscrowFactory {
    address public controller;

    constructor(address deployer) Auth(deployer) {}

    /// @inheritdoc IRefundEscrowFactory
    function file(bytes32 what, address data) external auth {
        if (what == "controller") controller = data;
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    /// @inheritdoc IRefundEscrowFactory
    function newEscrow(PoolId poolId) external auth returns (IRefundEscrow escrow) {
        escrow = new RefundEscrow{salt: bytes32(uint256(poolId.raw()))}();
        IAuth(address(escrow)).rely(controller);
        IAuth(address(escrow)).deny(address(this));
        emit DeployRefundEscrow(poolId, address(escrow));
    }

    /// @inheritdoc IRefundEscrowFactory
    function get(PoolId poolId) public view returns (IRefundEscrow) {
        bytes32 salt = bytes32(uint256(poolId.raw()));
        bytes32 hash =
            keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(type(RefundEscrow).creationCode)));

        return IRefundEscrow(address(uint160(uint256(hash))));
    }
}
