// SPDX-License-Identifier: GPL-2.0
pragma solidity 0.8.28;

contract MockGasService {
    //<>=============================================================<>
    //||                                                             ||
    //||                    NON-VIEW FUNCTIONS                       ||
    //||                                                             ||
    //<>=============================================================<>

    //<>=============================================================<>
    //||                                                             ||
    //||                    SETTER FUNCTIONS                         ||
    //||                                                             ||
    //<>=============================================================<>
    // Function to set return values for gasLimit
    function setGasLimitReturn(uint128 _value0) public {
        _gasLimitReturn_0 = _value0;
    }

    // Function to set return values for maxBatchSize
    function setMaxBatchSizeReturn(uint128 _value0) public {
        _maxBatchSizeReturn_0 = _value0;
    }

    /**
     *
     *   ⚠️ WARNING ⚠️ WARNING ⚠️ WARNING ⚠️ WARNING ⚠️ WARNING ⚠️  *
     * -----------------------------------------------------------------*
     *      Generally you only need to modify the sections above.      *
     *          The code below handles system operations.              *
     *
     */

    //<>=============================================================<>
    //||                                                             ||
    //||         ⚠️  INTERNAL STORAGE - DO NOT MODIFY  ⚠️           ||
    //||                                                             ||
    //<>=============================================================<>
    uint128 private _gasLimitReturn_0;
    uint128 private _maxBatchSizeReturn_0;

    //<>=============================================================<>
    //||                                                             ||
    //||          ⚠️  VIEW FUNCTIONS - DO NOT MODIFY  ⚠️            ||
    //||                                                             ||
    //<>=============================================================<>
    /// --- Estimations ---
    function estimate(uint32, /*chainId*/ bytes calldata /* payload */ ) public pure returns (uint256) {
        // uses propMaxGas from echidna config
        return 0;
    }

    /// @notice Gas limit for the execution cost of an individual message in a remote chain.
    function gasLimit(uint16 centrifugeId, bytes calldata message) public view returns (uint128) {
        return _gasLimitReturn_0;
    }

    /// @notice Gas limit for the execution cost of a batch in a remote chain.
    function maxBatchSize(uint16 centrifugeId) public view returns (uint128) {
        return _maxBatchSizeReturn_0;
    }
}
