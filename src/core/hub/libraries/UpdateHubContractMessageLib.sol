// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "../../../misc/libraries/CastLib.sol";
import {BytesLib} from "../../../misc/libraries/BytesLib.sol";

/// @dev Update types for hub-side contract updates
/// @dev Currently no payload types defined, reserved for future integrations
enum UpdateHubContractType {
    /// @dev Placeholder for null update type
    Invalid
}

/// @title UpdateHubContractMessageLib
/// @notice Library for encoding/decoding UpdateHubContract message payloads
library UpdateHubContractMessageLib {
    using UpdateHubContractMessageLib for bytes;
    using BytesLib for bytes;
    using CastLib for *;

    error UnknownMessageType();

    /// @notice Extracts the update type from a payload
    /// @param message The payload bytes
    /// @return The update type enum value
    function updateHubContractType(bytes memory message) internal pure returns (UpdateHubContractType) {
        return UpdateHubContractType(message.toUint8(0));
    }
}
