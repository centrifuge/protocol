// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "src/misc/ERC20.sol";
import {IERC20Wrapper, IERC20Metadata} from "src/misc/interfaces/IERC20.sol";
import {Mock} from "test/common/mocks/Mock.sol";
import "forge-std/Test.sol";

contract MockERC20Wrapper is ERC20, Mock, IERC20Wrapper {
    address public underlying;
    bool shouldDepositFail;
    bool shouldWithdrawFail;

    constructor(address underlying_) ERC20(IERC20Metadata(underlying_).decimals()) {
        underlying = underlying_;
    }

    function depositFor(address account, uint256 value) external returns (bool) {
        if (method_fail["depositFor"]) return false;
        require(
            IERC20Metadata(underlying).transferFrom(msg.sender, address(this), value),
            "MockERC20Wrapper/failed-transfer"
        );

        // Obviously unsafe, just for testing purposes
        _setBalance(account, _balanceOf(account) + value);
        totalSupply = totalSupply + value;
        emit Transfer(address(0), account, value);

        return true;
    }

    function withdrawTo(address account, uint256 value) external returns (bool) {
        if (method_fail["withdrawTo"]) return false;
        _setBalance(msg.sender, _balanceOf(msg.sender) - value);
        totalSupply = totalSupply - value;

        IERC20Metadata(underlying).transfer(account, value);
        return true;
    }
}
