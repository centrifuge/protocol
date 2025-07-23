// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {UpdateContractMessageLib} from "../../../../src/spoke/libraries/UpdateContractMessageLib.sol";

import "forge-std/Test.sol";

// The following tests check that the function composition of deserializing and serializing equals to the identity:
//       I = deserialize º serialize
// NOTE. To fully ensure a good testing, use different values for each field.
contract TestUpdateContractMessageLibIdentities is Test {
    using UpdateContractMessageLib for *;

    function testUpdateContractValuation(bytes32 valuation) public pure {
        UpdateContractMessageLib.UpdateContractValuation memory a =
            UpdateContractMessageLib.UpdateContractValuation({valuation: valuation});
        UpdateContractMessageLib.UpdateContractValuation memory b =
            UpdateContractMessageLib.deserializeUpdateContractValuation(a.serialize());

        assertEq(a.valuation, b.valuation);
    }

    function testUpdateContractSyncDepositMaxReserve(uint128 assetId, uint128 maxReserve) public pure {
        UpdateContractMessageLib.UpdateContractSyncDepositMaxReserve memory a =
            UpdateContractMessageLib.UpdateContractSyncDepositMaxReserve({assetId: assetId, maxReserve: maxReserve});
        UpdateContractMessageLib.UpdateContractSyncDepositMaxReserve memory b =
            UpdateContractMessageLib.deserializeUpdateContractSyncDepositMaxReserve(a.serialize());

        assertEq(a.assetId, b.assetId);
        assertEq(a.maxReserve, b.maxReserve);
    }

    function testUpdateContractUpdateAddress(bytes32 kind, uint128 assetId, bytes32 what, bool isEnabled) public pure {
        UpdateContractMessageLib.UpdateContractUpdateAddress memory a = UpdateContractMessageLib
            .UpdateContractUpdateAddress({kind: kind, assetId: assetId, what: what, isEnabled: isEnabled});
        UpdateContractMessageLib.UpdateContractUpdateAddress memory b =
            UpdateContractMessageLib.deserializeUpdateContractUpdateAddress(a.serialize());

        assertEq(a.kind, b.kind);
        assertEq(a.assetId, b.assetId);
        assertEq(a.what, b.what);
        assertEq(a.isEnabled, b.isEnabled);
    }

    function testUpdateContractPolicy(bytes32 who, bytes32 what) public pure {
        UpdateContractMessageLib.UpdateContractPolicy memory a =
            UpdateContractMessageLib.UpdateContractPolicy({who: who, what: what});
        UpdateContractMessageLib.UpdateContractPolicy memory b =
            UpdateContractMessageLib.deserializeUpdateContractPolicy(a.serialize());

        assertEq(a.who, b.who);
        assertEq(a.what, b.what);
    }
}
