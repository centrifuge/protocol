// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "src/Oracle.sol";
import "src/interfaces/IERC7726.sol";

contract SomeContract {}

contract TestOracle is Test {
    address constant FEEDER = address(1);
    bytes32 constant SALT = bytes32(uint256(42));

    address CURR_FROM_CONTRACT = address(new SomeContract()); //ERC20 contract address => 6 decimals
    address CURR_NO_CONTRACT = address(123); // Non contract address => 18 decimals

    OracleFactory factory = new OracleFactory();

    function testDeploy() public {
        vm.expectEmit();
        emit IOracleFactory.NewOracleDeployed(factory.getAddress(FEEDER, SALT));

        factory.deploy(FEEDER, SALT);
    }

    function testSetQuote() public {
        IOracle oracle = factory.deploy(FEEDER, SALT);

        vm.expectEmit();
        vm.warp(1 days);
        emit IOracle.NewQuoteSet(address(1), address(2), 100, 1 days);

        vm.prank(FEEDER);
        oracle.setQuote(address(1), address(2), 100);
    }

    function testNonFeeder() public {
        IOracle oracle = factory.deploy(FEEDER, SALT);

        vm.expectRevert(abi.encodeWithSelector(IOracle.NotValidFeeder.selector));
        oracle.setQuote(address(1), address(2), 100);
    }

    function testNeverFed() public {
        IOracle oracle = factory.deploy(address(this), SALT);

        vm.expectRevert(abi.encodeWithSelector(IOracle.NoQuote.selector));
        oracle.getQuote(1, address(1), address(2));
    }

    function testGetQuoteERC20() public {
        IOracle oracle = factory.deploy(address(this), SALT);
        oracle.setQuote(CURR_FROM_CONTRACT, CURR_NO_CONTRACT, 100);

        vm.mockCall(CURR_FROM_CONTRACT, abi.encodeWithSelector(IERC20.decimals.selector), abi.encode(uint8(6)));
        assertEq(oracle.getQuote(5 * 10 ** 6, CURR_FROM_CONTRACT, CURR_NO_CONTRACT), 500);
    }

    function testGetQuoteNonERC20Contract() public {
        IOracle oracle = factory.deploy(address(this), SALT);
        oracle.setQuote(CURR_FROM_CONTRACT, CURR_NO_CONTRACT, 100);

        assertEq(oracle.getQuote(5 * 10 ** 18, CURR_FROM_CONTRACT, CURR_NO_CONTRACT), 500);
    }

    function testGetQuoteERC20ContractWithErr() public {
        IOracle oracle = factory.deploy(address(this), SALT);
        oracle.setQuote(CURR_FROM_CONTRACT, CURR_NO_CONTRACT, 100);

        vm.mockCallRevert(CURR_FROM_CONTRACT, abi.encodeWithSelector(IERC20.decimals.selector), abi.encode("error"));
        assertEq(oracle.getQuote(5 * 10 ** 18, CURR_FROM_CONTRACT, CURR_NO_CONTRACT), 500);
    }

    function testGetQuoteNonContract() public {
        IOracle oracle = factory.deploy(address(this), SALT);
        oracle.setQuote(CURR_NO_CONTRACT, CURR_NO_CONTRACT, 100);

        assertEq(oracle.getQuote(5 * 10 ** 18, CURR_NO_CONTRACT, CURR_NO_CONTRACT), 500);
    }
}
