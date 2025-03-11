// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "src/misc/ERC20.sol";
import {IERC20Wrapper, IERC20Metadata} from "src/misc/interfaces/IERC20.sol";
import {ICentrifugeRouter} from "src/vaults/interfaces/ICentrifugeRouter.sol";
import {Mock} from "test/common/mocks/Mock.sol";
import "forge-std/Test.sol";

contract MockReentrantERC20Wrapper1 is ERC20, Mock, IERC20Wrapper {
    address public underlying;
    bool shouldDepositFail;
    bool shouldWithdrawFail;

    ICentrifugeRouter public reentrancyTarget;

    constructor(address underlying_, address reentrancyTarget_) ERC20(IERC20Metadata(underlying_).decimals()) {
        underlying = underlying_;
        reentrancyTarget = ICentrifugeRouter(reentrancyTarget_);
    }

    function depositFor(address account, uint256 value) external returns (bool) {
        reentrancyTarget.wrap(makeAddr("Vault"), value, makeAddr("Receiver"), account);
        return true;
    }

    function withdrawTo(address, /* account */ uint256 /* value */ ) external pure returns (bool) {
        return true;
    }
}

contract MockReentrantERC20Wrapper2 is ERC20, Mock, IERC20Wrapper {
    address public underlying;
    bool shouldDepositFail;
    bool shouldWithdrawFail;

    ICentrifugeRouter public reentrancyTarget;

    constructor(address underlying_, address reentrancyTarget_) ERC20(IERC20Metadata(underlying_).decimals()) {
        underlying = underlying_;
        reentrancyTarget = ICentrifugeRouter(reentrancyTarget_);
    }

    function depositFor(address, /* account */ uint256 /* value */ ) external returns (bool) {
        bytes[] memory calls = new bytes[](0);
        reentrancyTarget.multicall(calls);
        return true;
    }

    function withdrawTo(address, /* account */ uint256 /* value */ ) external pure returns (bool) {
        return true;
    }
}
