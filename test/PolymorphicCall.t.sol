pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {Multicall} from "src/Multicall.sol";

contract Holdings {
    struct Item {
        uint64 id1;
        uint32 id2;
        address id3;
    }

    mapping(address => Item) public items;

    function create(uint64 id1, uint32 id2, address id3) external {
        items[id3] = Item(id1, id2, id3);
    }
}

contract Bonds {
    struct Item {
        uint32 id1;
        address id2;
    }

    mapping(address => Item) public items;

    function create(uint32 id1, address id2) external {
        items[id2] = Item(id1, id2);
    }
}

contract PoolManager {
    function create(address target, bytes calldata encodedCreateSignature) external {
        target.call(encodedCreateSignature);
    }
}

contract IntegrationTest is Test {
    Multicall multicall;
    Holdings holdings;
    Bonds bonds;
    PoolManager poolManager;

    function setUp() public {
        multicall = new Multicall();
        holdings = new Holdings();
        bonds = new Bonds();
        poolManager = new PoolManager();
    }

    function testSettingUpItems() public {
        uint64 h_id1 = 1;
        uint32 h_id2 = 2;
        address h_id3 = makeAddr("id3");

        uint32 b_id1 = 4;
        address b_id2 = makeAddr("id2");
        bytes memory createHoldingItem = abi.encodeCall(Holdings.create, (h_id1, h_id2, h_id3));
        bytes memory createBondItem = abi.encodeCall(Bonds.create, (b_id1, b_id2));

        bytes memory poolManagerCreateHoldingItem =
            abi.encodeCall(PoolManager.create, (address(holdings), createHoldingItem));
        bytes memory poolManagerCreateBondItem = abi.encodeCall(PoolManager.create, (address(bonds), createBondItem));

        address[] memory targets = new address[](2);
        targets[0] = address(poolManager);
        targets[1] = address(poolManager);

        bytes[] memory targetFunctions = new bytes[](2);
        targetFunctions[0] = poolManagerCreateHoldingItem;
        targetFunctions[1] = poolManagerCreateBondItem;

        multicall.aggregate(targets, targetFunctions);

        (, uint32 added_h_id2,) = holdings.items(h_id3);
        assertEq(added_h_id2, h_id2);

        (uint32 added_b_id1,) = bonds.items(b_id2);
        assertEq(added_b_id1, b_id1);
    }
}
