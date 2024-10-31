// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "src/Oracle.sol";
import "src/interfaces/IERC7726.sol";

contract SomeContract {}

contract TestCommon is Test {
    address constant FEEDER = address(1);
    bytes32 constant SALT = bytes32(uint256(42));

    OracleFactory factory = new OracleFactory();
}

contract TestDeploy is TestCommon {
    function testSuccess() public {
        vm.expectEmit();
        emit IOracleFactory.NewOracleDeployed(factory.getAddress(FEEDER, SALT));

        factory.deploy(FEEDER, SALT);
    }

    function testSeveral() public {
        factory.deploy(FEEDER, SALT);
        factory.deploy(FEEDER, bytes32(uint256(43)));
    }

    function testFailOverrideDeploy() public {
        factory.deploy(FEEDER, SALT);
        factory.deploy(FEEDER, SALT);
    }
}

contract TestSetQuote is TestCommon {
    address BASE = address(10);
    address QUOTE = address(12);

    function testSuccess() public {
        IOracle oracle = factory.deploy(FEEDER, SALT);

        vm.expectEmit();
        vm.warp(1 days);
        emit IOracle.NewQuoteSet(BASE, QUOTE, 100, 1 days);

        vm.prank(FEEDER);
        oracle.setQuote(BASE, QUOTE, 100);
    }

    function testErrNotValidFeeder() public {
        IOracle oracle = factory.deploy(FEEDER, SALT);

        vm.expectRevert(abi.encodeWithSelector(IOracle.NotValidFeeder.selector));
        oracle.setQuote(BASE, QUOTE, 100);
    }

    function testErrNoQuote() public {
        IOracle oracle = factory.deploy(address(this), SALT);

        vm.expectRevert(abi.encodeWithSelector(IOracle.NoQuote.selector));
        oracle.getQuote(1, BASE, QUOTE);
    }
}

contract TestGetQuote is TestCommon {
    address CURR_FROM_CONTRACT = address(new SomeContract()); //ERC20 contract address => 6 decimals
    address CURR_NO_CONTRACT = address(123); // Non contract address => 18 decimals
    address BASE = address(1000); // Anyone

    function testERC20() public {
        IOracle oracle = factory.deploy(address(this), SALT);
        oracle.setQuote(CURR_FROM_CONTRACT, BASE, 100);

        vm.mockCall(CURR_FROM_CONTRACT, abi.encodeWithSelector(IERC20.decimals.selector), abi.encode(uint8(6)));
        assertEq(oracle.getQuote(5 * 10 ** 6, CURR_FROM_CONTRACT, BASE), 500);
    }

    function testNonERC20Contract() public {
        IOracle oracle = factory.deploy(address(this), SALT);
        oracle.setQuote(CURR_FROM_CONTRACT, BASE, 100);

        assertEq(oracle.getQuote(5 * 10 ** 18, CURR_FROM_CONTRACT, BASE), 500);
    }

    function testERC20ContractWithErr() public {
        IOracle oracle = factory.deploy(address(this), SALT);
        oracle.setQuote(CURR_FROM_CONTRACT, BASE, 100);

        vm.mockCallRevert(CURR_FROM_CONTRACT, abi.encodeWithSelector(IERC20.decimals.selector), abi.encode("error"));
        assertEq(oracle.getQuote(5 * 10 ** 18, CURR_FROM_CONTRACT, BASE), 500);
    }

    function testNonContract() public {
        IOracle oracle = factory.deploy(address(this), SALT);
        oracle.setQuote(CURR_NO_CONTRACT, BASE, 100);

        assertEq(oracle.getQuote(5 * 10 ** 18, CURR_NO_CONTRACT, BASE), 500);
    }
}
