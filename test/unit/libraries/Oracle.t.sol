// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "forge-std/mocks/MockERC20.sol";
import "src/Oracle.sol";
import "src/interfaces/IERC7726.sol";

contract TestOracle is Test {
    address constant FEEDER = address(1);
    bytes32 constant SALT = bytes32(uint256(42));

    MockERC20 ERC20_A = new MockERC20();

    address CURR_A = address(ERC20_A); //ERC20 contract address => 6 decimals
    address CURR_B = address(this); // Contract address => 18 decimals
    address CURR_C = address(100); // Non contract address => 18 decimals

    OracleFactory factory = new OracleFactory();

    function setUp() public {
        ERC20_A.initialize("", "", 6);
    }

    function testDeploy() public {
        vm.expectEmit();
        emit OracleFactory.NewOracleDeployed(factory.getAddress(FEEDER, SALT));

        factory.deploy(FEEDER, SALT);
    }

    function testSetQuote() public {
        Oracle oracle = factory.deploy(FEEDER, SALT);

        vm.expectEmit();
        vm.warp(1 days);
        emit Oracle.NewQuoteSet(CURR_A, CURR_B, 100, 1 days);

        vm.prank(FEEDER);
        oracle.setQuote(CURR_A, CURR_B, 100);
    }

    function testGetQuoteERC20() public {
        Oracle oracle = factory.deploy(address(this), SALT);
        oracle.setQuote(CURR_A, CURR_B, 100);

        assertEq(oracle.getQuote(5 * 10 ** ERC20_A.decimals(), CURR_A, CURR_B), 500);
    }

    function testGetQuoteNonERC20Contract() public {
        Oracle oracle = factory.deploy(address(this), SALT);
        oracle.setQuote(CURR_B, CURR_A, 100);

        assertEq(oracle.getQuote(5 * 10 ** 18, CURR_B, CURR_A), 500);
    }

    function testGetQuoteNonContract() public {
        Oracle oracle = factory.deploy(address(this), SALT);
        oracle.setQuote(CURR_C, CURR_A, 100);

        assertEq(oracle.getQuote(5 * 10 ** 18, CURR_C, CURR_A), 500);
    }

    function testNonFeeder() public {
        Oracle oracle = factory.deploy(FEEDER, SALT);
        vm.expectRevert(abi.encodeWithSelector(Oracle.NotValidFeeder.selector));
        oracle.setQuote(CURR_A, CURR_B, 100);
    }

    function testNeverFed() public {
        Oracle oracle = factory.deploy(FEEDER, SALT);
        vm.expectRevert(abi.encodeWithSelector(Oracle.NoQuote.selector));
        oracle.getQuote(1, CURR_A, CURR_B);
    }
}
