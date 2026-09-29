// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IEscrowProvider, IEscrowFactory} from "./interfaces/IEscrowFactory.sol";

import {Auth} from "../../../misc/Auth.sol";

import {Escrow} from "../Escrow.sol";
import {PoolId} from "../../types/PoolId.sol";
import {IEscrow} from "../interfaces/IEscrow.sol";

contract EscrowFactory is Auth, IEscrowFactory {
    address public immutable root;

    address public spoke;

    mapping(address escrow => PoolId) public poolId;

    constructor(address root_, address deployer) Auth(deployer) {
        root = root_;
    }

    /// @inheritdoc IEscrowFactory
    function file(bytes32 what, address data) external auth {
        if (what == "spoke") spoke = data;
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    /// @inheritdoc IEscrowFactory
    function newEscrow(PoolId poolId_) public auth returns (IEscrow) {
        Escrow escrow_ = new Escrow{salt: bytes32(uint256(poolId_.raw()))}(poolId_, address(this));

        poolId[address(escrow_)] = poolId_;

        escrow_.rely(root);
        escrow_.rely(spoke);

        escrow_.deny(address(this));

        emit DeployEscrow(poolId_, address(escrow_));
        return IEscrow(escrow_);
    }

    /// @inheritdoc IEscrowProvider
    function escrow(PoolId poolId_) external view returns (IEscrow) {
        bytes32 salt = bytes32(uint256(poolId_.raw()));
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(abi.encodePacked(type(Escrow).creationCode, abi.encode(poolId_, address(this))))
            )
        );

        return IEscrow(address(uint160(uint256(hash))));
    }
}
