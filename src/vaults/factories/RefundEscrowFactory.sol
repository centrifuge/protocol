// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "../../misc/Auth.sol";

import {PoolId} from "../../common/types/PoolId.sol";
import {IAsyncRequestManager} from "../interfaces/IVaultManagers.sol";

interface IRefundEscrow {
    function requestFunds() external;
}

contract RefundEscrow is Auth, IRefundEscrow {
    event ReceiveNativeTokens(address who, uint256 amount);

    constructor(address owner) Auth(owner) {}

    receive() external payable {}

    function requestFunds() external auth {
        msg.sender.call{value: address(this).balance}("");
    }
}

interface IRefundEscrowFactory {
    function file(bytes32 what, address data) external;
    function getOrCreate(PoolId poolId) external returns (IRefundEscrow);
    function get(PoolId poolId) external view returns (IRefundEscrow);
}

contract RefundEscrowFactory is Auth {
    event File(bytes32 what, address data);
    event DeployRefundEscrow(PoolId indexed poolId, address indexed escrow);

    error FileUnrecognizedParam();

    IAsyncRequestManager public asyncRequestManager;

    constructor(IAsyncRequestManager asyncRequestManager_, address deployer) Auth(deployer) {
        asyncRequestManager = asyncRequestManager_;
    }

    function file(bytes32 what, address data) external auth {
        if (what == "asyncRequestManager") asyncRequestManager = IAsyncRequestManager(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    function getOrCreate(PoolId poolId) external auth returns (IRefundEscrow) {
        IRefundEscrow escrow = get(poolId);
        if (address(escrow).code.length > 0) return escrow;

        RefundEscrow escrow_ = new RefundEscrow{salt: bytes32(uint256(poolId.raw()))}(address(asyncRequestManager));
        emit DeployRefundEscrow(poolId, address(escrow_));
        return IRefundEscrow(escrow_);
    }

    function get(PoolId poolId) public view returns (IRefundEscrow) {
        bytes32 salt = bytes32(uint256(poolId.raw()));
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(abi.encodePacked(type(RefundEscrow).creationCode, abi.encode(poolId, address(this))))
            )
        );

        return IRefundEscrow(address(uint160(uint256(hash))));
    }
}
