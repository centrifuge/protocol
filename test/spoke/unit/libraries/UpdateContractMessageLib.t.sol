// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {UpdateContractMessageLib} from "src/spoke/libraries/UpdateContractMessageLib.sol";
import {AssetId} from "src/common/types/AssetId.sol";

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

    function testUpdateContractUpdateAddress(bytes32 kind, bytes32 what, bytes32 who, bytes32 where, bool isEnabled)
        public
        pure
    {
        UpdateContractMessageLib.UpdateContractUpdateAddress memory a = UpdateContractMessageLib
            .UpdateContractUpdateAddress({kind: kind, what: what, who: who, where: where, isEnabled: isEnabled});
        UpdateContractMessageLib.UpdateContractUpdateAddress memory b =
            UpdateContractMessageLib.deserializeUpdateContractUpdateAddress(a.serialize());

        assertEq(a.kind, b.kind);
        assertEq(a.what, b.what);
        assertEq(a.who, b.who);
        assertEq(a.where, b.where);
        assertEq(a.isEnabled, b.isEnabled);
        // This message is a submessage and has not static message length defined
    }
}
