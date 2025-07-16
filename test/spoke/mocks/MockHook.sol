// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC165} from "centrifuge-v3/src/misc/interfaces/IERC7575.sol";

import {ITransferHook} from "centrifuge-v3/src/common/interfaces/ITransferHook.sol";

import "centrifuge-v3/test/common/mocks/Mock.sol";

contract MockHook is Mock {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ITransferHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function updateRestriction(address token, bytes memory update) external {}
}
