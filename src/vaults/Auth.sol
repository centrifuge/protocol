// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/vaults/interfaces/IAuth.sol";

/// @title  Auth
/// @notice Simple authentication pattern
/// @author Based on code from https://github.com/makerdao/dss
abstract contract Auth is IAuth {
    /// @inheritdoc IAuth
    mapping(address => uint256) public wards;

    constructor(address initialWard) {
        wards[initialWard] = 1;
        emit Rely(initialWard);
    }

    /// @dev Check if the msg.sender has permissions
    modifier auth() {
        require(wards[msg.sender] == 1, "Auth/not-authorized");
        _;
    }

    /// @inheritdoc IAuth
    function rely(address user) external auth {
        wards[user] = 1;
        emit Rely(user);
    }

    /// @inheritdoc IAuth
    function deny(address user) external auth {
        wards[user] = 0;
        emit Deny(user);
    }
}
