// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

interface RootLike {
    function relyContract(address, address) external;
    function executeScheduledRely(address) external;
    function delay() external view returns (uint64);
}

interface AuthLike {
    function rely(address) external;
    function deny(address) external;
}

interface OldEscrowLike {
    function approve(address token, address spender, uint256 value) external;
}

// Spell to migrate the escrow balances
contract Spell {
    bool public done;
    string public constant description = "Liquidity Pool escrow migration spell";

    address public constant LP_MULTISIG = 0xD9D30ab47c0f096b0AA67e9B8B1624504a63e7FD;
    address public constant OLD_DELAYED_ADMIN = 0x2559998026796Ca6fd057f3aa66F2d6ecdEd9028;
    address public constant OLD_ROOT = 0x498016d30Cd5f0db50d7ACE329C07313a0420502;
    address public constant OLD_ESCROW = 0xd595E1483c507E74E2E6A3dE8e7D08d8f6F74936;
    address public constant NEW_ESCROW = 0x0000000005F458Fd6ba9EEb5f365D83b7dA913dD;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    function cast() public {
        require(!done, "spell-already-cast");
        done = true;
        execute();
    }

    function execute() internal {
        RootLike root = RootLike(OLD_ROOT);
        root.relyContract(OLD_ESCROW, address(this));

        migrateBalance(USDC);

        AuthLike(OLD_ROOT).deny(address(this));
        AuthLike(OLD_ESCROW).deny(address(this));
    }

    function migrateBalance(address token) internal {
        OldEscrowLike escrow = OldEscrowLike(OLD_ESCROW);
        escrow.approve(token, address(this), type(uint256).max);
        IERC20(token).transferFrom(OLD_ESCROW, NEW_ESCROW, IERC20(token).balanceOf(OLD_ESCROW));
        escrow.approve(token, address(this), 0);
    }
}
