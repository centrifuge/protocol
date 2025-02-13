// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import "test/mocks/Mock.sol";

contract MockRoot is Mock {
    function endorsed(address) public view returns (bool) {
        return values_bool_return["endorsed_user"];
    }

    function paused() public view returns (bool isPaused) {
        isPaused = values_bool_return["isPaused"];
    }
}
