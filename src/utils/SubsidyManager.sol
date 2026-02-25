// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISubsidyManager} from "./interfaces/ISubsidyManager.sol";
import {IRefundEscrowFactory, IRefundEscrow} from "./RefundEscrowFactory.sol";

import {Auth} from "../misc/Auth.sol";
import {CastLib} from "../misc/libraries/CastLib.sol";

import {PoolId} from "../core/types/PoolId.sol";
import {ShareClassId} from "../core/types/ShareClassId.sol";
import {ITrustedContractUpdate} from "../core/utils/interfaces/IContractUpdate.sol";

contract SubsidyManager is Auth, ISubsidyManager {
    using CastLib for *;

    IRefundEscrowFactory public refundEscrowFactory;

    constructor(IRefundEscrowFactory refundEscrowFactory_, address deployer) Auth(deployer) {
        refundEscrowFactory = refundEscrowFactory_;
    }

    /// @inheritdoc ISubsidyManager
    function file(bytes32 what, address data) external auth {
        if (what == "refundEscrowFactory") refundEscrowFactory = IRefundEscrowFactory(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    /// @inheritdoc ISubsidyManager
    function deposit(PoolId poolId) external payable {
        IRefundEscrow refund = refundEscrowFactory.get(poolId);
        if (address(refund).code.length == 0) {
            refund = refundEscrowFactory.newEscrow(poolId);
        }

        refund.depositFunds{value: msg.value}();
        emit DepositSubsidy(poolId, msg.sender, msg.value);
    }

    /// @inheritdoc ISubsidyManager
    function withdraw(PoolId poolId, address to, uint256 value) public auth {
        IRefundEscrow refund = refundEscrowFactory.get(poolId);
        require(address(refund).code.length > 0, RefundEscrowNotDeployed());
        require(address(refund).balance >= value, NotEnoughToWithdraw());

        refund.withdrawFunds(to, value);

        emit WithdrawSubsidy(poolId, to, value);
    }

    /// @inheritdoc ISubsidyManager
    function withdrawAll(PoolId poolId, address to) external auth returns (address, uint256) {
        IRefundEscrow refund = refundEscrowFactory.get(poolId);
        uint256 amount = address(refund).balance;

        require(address(refund).code.length > 0, RefundEscrowNotDeployed());

        refund.withdrawFunds(to, amount);

        return (address(refund), amount);
    }

    /// @inheritdoc ITrustedContractUpdate
    function trustedCall(PoolId poolId, ShareClassId, bytes memory payload) external auth {
        (bytes32 who, uint256 value) = abi.decode(payload, (bytes32, uint256));
        withdraw(poolId, who.toAddress(), value);
    }
}
