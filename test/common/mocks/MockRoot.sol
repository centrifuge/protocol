// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "test/common/mocks/Mock.sol";

contract MockRoot is Mock {
    function endorsed(address) public view returns (bool) {
        return values_bool_return["endorsed_user"];
    }

    function paused() public view returns (bool isPaused) {
        isPaused = values_bool_return["isPaused"];
    }
}
