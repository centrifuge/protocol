// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {
    UpdateHubContractMessageLib,
    UpdateHubContractType
} from "../../../../src/core/hub/libraries/UpdateHubContractMessageLib.sol";

import "forge-std/Test.sol";

contract UpdateHubContractMessageLibTest is Test {
    using UpdateHubContractMessageLib for bytes;

    function testEnumValues() public pure {
        assertEq(uint8(UpdateHubContractType.Invalid), 0);
    }
}
