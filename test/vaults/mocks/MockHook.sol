// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {IERC165} from "src/interfaces/IERC7575.sol";
import {IHook} from "src/interfaces/token/IHook.sol";
import "test/mocks/Mock.sol";

contract MockHook is Mock {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
