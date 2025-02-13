// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

/// @dev Helpful Abstract Contract to set up stateful fuzz tests
/// By using this you can undo all state changes, without using vm.snapshot and vm.revertTo
/// Which are currently not supported by Medusa
abstract contract CallTestAndUndo {
    /// @dev Convenience internal function to perform an encoded call and capture the bool return value
    function _doTestAndReturnResult(bytes memory encoded) internal returns (bool) {
        // Call self with encoded params
        bool asBool;
        try this.callAndRevertWithBoolCatch(encoded) {}
        catch (bytes memory reason) {
            asBool = abi.decode(reason, (bool));
        }

        return asBool;
    }

    /// @dev Utility function to call self and revert, this allows compatibility with a lack of vm.snapshot
    // NOTE: On failure, we return true! Since Medusa skips reverting calls and we're capturing all reverts
    function callAndRevertWithBoolCatch(bytes memory theCalldata) external returns (bool) {
        (bool success, bytes memory returnData) = address(this).call(theCalldata);

        if (!success) {
            /// @audit Reverts return success just like a normal invariant test!
            bytes memory trueValue = abi.encode(true);
            assembly {
                revert(add(trueValue, 0x20), trueValue)
            }
        }

        // Else check returnData
        assembly {
            revert(add(returnData, 0x20), returnData)
        }
    }
}
