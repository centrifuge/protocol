// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IPoolEscrowProvider, IPoolEscrowFactory} from "./interfaces/IPoolEscrowFactory.sol";

import {Auth} from "../../misc/Auth.sol";

import {PoolId} from "../types/PoolId.sol";
import {PoolEscrow} from "../PoolEscrow.sol";
import {IPoolEscrow} from "../interfaces/IPoolEscrow.sol";

contract PoolEscrowFactory is Auth, IPoolEscrowFactory {
    address public immutable root;

    address public gateway;
    address public balanceSheet;

    constructor(address root_, address deployer) Auth(deployer) {
        root = root_;
    }

    /// @inheritdoc IPoolEscrowFactory
    function file(bytes32 what, address data) external auth {
        if (what == "gateway") gateway = data;
        else if (what == "balanceSheet") balanceSheet = data;
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    /// @inheritdoc IPoolEscrowFactory
    function newEscrow(PoolId poolId) public auth returns (IPoolEscrow) {
        PoolEscrow escrow_ = new PoolEscrow{salt: bytes32(uint256(poolId.raw()))}(poolId, address(this));

        escrow_.rely(root);
        escrow_.rely(gateway);
        escrow_.rely(balanceSheet);

        escrow_.deny(address(this));

        emit DeployPoolEscrow(poolId, address(escrow_));
        return IPoolEscrow(escrow_);
    }

    /// @inheritdoc IPoolEscrowProvider
    function escrow(PoolId poolId) external view returns (IPoolEscrow) {
        bytes32 salt = bytes32(uint256(poolId.raw()));
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(abi.encodePacked(type(PoolEscrow).creationCode, abi.encode(poolId, address(this))))
            )
        );

        return IPoolEscrow(address(uint160(uint256(hash))));
    }
}
