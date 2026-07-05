// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {ContractUpdateLib} from "../../../../src/core/utils/ContractUpdateLib.sol";

import "forge-std/Test.sol";

contract ContractUpdateLibTest is Test {
    function testWrapUnwrapRoundTrip(ShareClassId scId, address target, bytes calldata inner) public pure {
        bytes memory payload = ContractUpdateLib.wrap(scId, target, inner);
        (ShareClassId decodedScId, address decodedTarget, bytes memory decodedInner) = ContractUpdateLib.unwrap(payload);

        assertEq(ShareClassId.unwrap(decodedScId), ShareClassId.unwrap(scId));
        assertEq(decodedTarget, target);
        assertEq(decodedInner, inner);
    }

    /// @dev A payload that isn't a valid ABI-encoded (ShareClassId, address, bytes) tuple must revert
    ///      rather than silently decoding into garbage values that get forwarded as a trusted call.
    ///      `unwrap` is inlined (internal pure), so it's called through an external wrapper to give
    ///      `vm.expectRevert` a real call frame to attach to.
    function testUnwrapRevertsOnTruncatedPayload() public {
        vm.expectRevert();
        this.unwrapExternal(hex"0011223344");
    }

    function testUnwrapRevertsOnEmptyPayload() public {
        vm.expectRevert();
        this.unwrapExternal("");
    }

    function unwrapExternal(bytes calldata payload) external pure returns (ShareClassId, address, bytes memory) {
        return ContractUpdateLib.unwrap(payload);
    }
}
