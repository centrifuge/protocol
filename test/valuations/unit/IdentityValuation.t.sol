// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {AssetId} from "../../../src/common/types/AssetId.sol";
import {ShareClassId} from "../../../src/common/types/ShareClassId.sol";

import {IHubRegistry} from "../../../src/hub/interfaces/IHubRegistry.sol";

import {IdentityValuation} from "../../../src/valuations/IdentityValuation.sol";

import "forge-std/Test.sol";

PoolId constant POOL_A = PoolId.wrap(42);
PoolId constant POOL_B = PoolId.wrap(43);
ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("1"));
AssetId constant C6 = AssetId.wrap(6);
AssetId constant C18 = AssetId.wrap(18);

contract TestIdentityValuation is Test {
    address hubRegistry = makeAddr("hubRegistry");
    IdentityValuation valuation = new IdentityValuation(IHubRegistry(hubRegistry));

    function setUp() public {
        vm.mockCall(address(hubRegistry), abi.encodeWithSignature("decimals(uint128)", C6), abi.encode(6));
        vm.mockCall(address(hubRegistry), abi.encodeWithSignature("decimals(uint128)", C18), abi.encode(18));
        vm.mockCall(address(hubRegistry), abi.encodeWithSignature("decimals(uint64)", POOL_A), abi.encode(6));
        vm.mockCall(address(hubRegistry), abi.encodeWithSignature("decimals(uint64)", POOL_B), abi.encode(18));
    }

    function testSameDecimals() public view {
        assertEq(valuation.getQuote(POOL_A, SC_1, C6, 100 * 1e6), 100 * 1e6);
    }

    function testFromMoreDecimalsToLess() public view {
        assertEq(valuation.getQuote(POOL_A, SC_1, C18, 100 * 1e18), 100 * 1e6);
    }

    function testFromLessDecimalsToMore() public view {
        assertEq(valuation.getQuote(POOL_B, SC_1, C6, 100 * 1e6), 100 * 1e18);
    }
}
