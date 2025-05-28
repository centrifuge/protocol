// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";

enum UpdateContractType {
    /// @dev Placeholder for null update restriction type
    Invalid,
    Valuation,
    SyncDepositMaxReserve,
    LoanMaxBorrowAmount,
    LoanRate
}

library UpdateContractMessageLib {
    using UpdateContractMessageLib for bytes;
    using BytesLib for bytes;
    using CastLib for *;

    error UnknownMessageType();

    function updateContractType(bytes memory message) internal pure returns (UpdateContractType) {
        return UpdateContractType(message.toUint8(0));
    }

    //---------------------------------------
    //   UpdateContract.Valuation (submsg)
    //---------------------------------------

    struct UpdateContractValuation {
        bytes32 valuation;
    }

    function deserializeUpdateContractValuation(bytes memory data)
        internal
        pure
        returns (UpdateContractValuation memory)
    {
        require(updateContractType(data) == UpdateContractType.Valuation, UnknownMessageType());
        return UpdateContractValuation({valuation: data.toBytes32(1)});
    }

    function serialize(UpdateContractValuation memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(UpdateContractType.Valuation, t.valuation);
    }

    //---------------------------------------
    //   UpdateContract.SyncDepositMaxReserve (submsg)
    //---------------------------------------

    struct UpdateContractSyncDepositMaxReserve {
        uint128 assetId;
        uint128 maxReserve;
    }

    function deserializeUpdateContractSyncDepositMaxReserve(bytes memory data)
        internal
        pure
        returns (UpdateContractSyncDepositMaxReserve memory)
    {
        require(updateContractType(data) == UpdateContractType.SyncDepositMaxReserve, UnknownMessageType());
        return UpdateContractSyncDepositMaxReserve({assetId: data.toUint128(1), maxReserve: data.toUint128(17)});
    }

    function serialize(UpdateContractSyncDepositMaxReserve memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(UpdateContractType.SyncDepositMaxReserve, t.assetId, t.maxReserve);
    }

    //---------------------------------------
    //   UpdateContract.LoanMaxBorrowAmount (submsg)
    //---------------------------------------

    struct UpdateContractLoanMaxBorrowAmount {
        uint128 assetId;
        uint128 maxBorrowAmount;
    }

    function deserializeUpdateContractLoanMaxBorrowAmount(bytes memory data)
        internal
        pure
        returns (UpdateContractLoanMaxBorrowAmount memory)
    {
        require(updateContractType(data) == UpdateContractType.LoanMaxBorrowAmount, UnknownMessageType());

        return UpdateContractLoanMaxBorrowAmount({assetId: data.toUint128(1), maxBorrowAmount: data.toUint128(17)});
    }

    function serialize(UpdateContractLoanMaxBorrowAmount memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(UpdateContractType.LoanMaxBorrowAmount, t.assetId, t.maxBorrowAmount);
    }

    //---------------------------------------
    //   UpdateContract.LoanRate (submsg)
    //---------------------------------------

    struct UpdateContractLoanRate {
        uint128 assetId;
        bytes32 rateId;
    }

    function deserializeUpdateContractLoanRate(bytes memory data)
        internal
        pure
        returns (UpdateContractLoanRate memory)
    {
        require(updateContractType(data) == UpdateContractType.LoanRate, UnknownMessageType());

        return UpdateContractLoanRate({assetId: data.toUint128(1), rateId: data.toBytes32(17)});
    }

    function serialize(UpdateContractLoanRate memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(UpdateContractType.LoanRate, t.assetId, t.rateId);
    }
}
