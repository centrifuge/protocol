// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "../../../../src/misc/interfaces/IERC20.sol";
import {CastLib} from "../../../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {ISpoke} from "../../../../src/core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {ISpokeRegistry} from "../../../../src/core/spoke/interfaces/ISpokeRegistry.sol";

import {ShareManager} from "../../../../src/managers/spoke/ShareManager.sol";
import {IShareManager} from "../../../../src/managers/spoke/interfaces/IShareManager.sol";

import "forge-std/Test.sol";

// Need it to overpass a mockCall issue: https://github.com/foundry-rs/foundry/issues/10703
contract IsContract {}

contract ShareManagerTest is Test {
    ISpoke spoke = ISpoke(address(new IsContract()));
    IERC20 share = IERC20(address(new IsContract()));
    ISpokeRegistry spokeRegistry = ISpokeRegistry(address(new IsContract()));

    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("sc1"));

    address envoy = makeAddr("envoy");
    address investor = makeAddr("investor");

    ShareManager manager;

    function setUp() public virtual {
        vm.mockCall(
            address(spokeRegistry), abi.encodeWithSelector(ISpokeRegistry.shareToken.selector), abi.encode(share)
        );
        vm.mockCall(address(share), abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));
        vm.mockCall(address(spoke), abi.encodeWithSelector(ISpoke.issue.selector), abi.encode());
        vm.mockCall(address(spoke), abi.encodeWithSelector(ISpoke.revoke.selector), abi.encode());
        vm.mockCall(address(spoke), abi.encodeWithSelector(ISpoke.transferSharesFrom.selector), abi.encode());

        manager = new ShareManager(envoy, spoke, spokeRegistry);
    }

    function _payload(IShareManager.ManagerCall kind, ShareClassId scId, address account, uint128 shares)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(uint8(kind), scId, CastLib.toBytes32(account), shares);
    }
}

contract ShareManagerFromHubFailureTests is ShareManagerTest {
    function testInvalidSource(address notEnvoy, uint128 shares) public {
        vm.assume(notEnvoy != envoy);

        vm.expectRevert(IShareManager.NotEnvoy.selector);
        vm.prank(notEnvoy);
        manager.fromHub(POOL_A, _payload(IShareManager.ManagerCall.Issue, SC_1, investor, shares));
    }

    function testUnexpectedValue(uint128 shares) public {
        vm.deal(envoy, 1 ether);

        vm.expectRevert(IShareManager.UnexpectedValue.selector);
        vm.prank(envoy);
        manager.fromHub{value: 1}(POOL_A, _payload(IShareManager.ManagerCall.Issue, SC_1, investor, shares));
    }

    function testUnknownManagerCall() public {
        vm.expectRevert(IShareManager.UnknownManagerCall.selector);
        vm.prank(envoy);
        manager.fromHub(POOL_A, abi.encode(uint8(99), SC_1, CastLib.toBytes32(investor), uint128(1)));
    }

    function testEmptyAmount(uint8 kind) public {
        vm.assume(kind <= uint8(type(IShareManager.ManagerCall).max));

        vm.expectRevert(IShareManager.EmptyAmount.selector);
        vm.prank(envoy);
        manager.fromHub(POOL_A, _payload(IShareManager.ManagerCall(kind), SC_1, investor, 0));
    }
}

contract ShareManagerIssueTests is ShareManagerTest {
    function testIssue(uint64 poolId, uint128 shares) public {
        shares = uint128(bound(shares, 1, type(uint128).max));

        vm.expectEmit();
        emit IShareManager.Issue(PoolId.wrap(poolId), SC_1, investor, shares);
        vm.expectCall(
            address(spoke), abi.encodeWithSelector(ISpoke.issue.selector, PoolId.wrap(poolId), SC_1, investor, shares)
        );

        vm.prank(envoy);
        manager.fromHub(PoolId.wrap(poolId), _payload(IShareManager.ManagerCall.Issue, SC_1, investor, shares));
    }
}

contract ShareManagerRevokeTests is ShareManagerTest {
    function testRevoke(uint128 shares) public {
        shares = uint128(bound(shares, 1, type(uint128).max));

        vm.expectEmit();
        emit IShareManager.Revoke(POOL_A, SC_1, investor, shares);
        vm.expectCall(
            address(spoke),
            abi.encodeWithSelector(
                ISpoke.transferSharesFrom.selector, POOL_A, SC_1, investor, investor, address(manager), uint256(shares)
            )
        );
        vm.expectCall(address(share), abi.encodeWithSelector(IERC20.approve.selector, address(spoke), uint256(shares)));
        vm.expectCall(address(spoke), abi.encodeWithSelector(ISpoke.revoke.selector, POOL_A, SC_1, shares));

        vm.prank(envoy);
        manager.fromHub(POOL_A, _payload(IShareManager.ManagerCall.Revoke, SC_1, investor, shares));
    }
}
