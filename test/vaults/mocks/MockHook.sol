// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC165} from "src/vaults/interfaces/IERC7575.sol";
import {IHook} from "src/vaults/interfaces/token/IHook.sol";
import "test/common/mocks/Mock.sol";

contract MockHook is Mock {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function updateRestriction(address token, bytes memory update) external {}
}
