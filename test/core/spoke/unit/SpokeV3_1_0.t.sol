// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "../../../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {ISpoke} from "../../../../src/core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {SpokeV3_1_0} from "../../../../src/core/spoke/legacy/SpokeV3_1_0.sol";
import {ISpokeRegistry} from "../../../../src/core/spoke/interfaces/ISpokeRegistry.sol";

import "forge-std/Test.sol";

import {IShareToken} from "../../../../src/token/interfaces/IShareToken.sol";

// Need it to overpass a mockCall issue: https://github.com/foundry-rs/foundry/issues/10703
contract IsContract {}

contract SpokeV3_1_0Test is Test {
    using CastLib for *;

    uint16 constant REMOTE_CENTRIFUGE_ID = 2;

    address immutable AUTH = makeAddr("AUTH");
    address immutable GROVE = makeAddr("GROVE");
    address immutable RECEIVER = makeAddr("RECEIVER");

    ISpoke spoke = ISpoke(address(new IsContract()));
    ISpokeRegistry spokeRegistry = ISpokeRegistry(address(new IsContract()));
    IShareToken share = IShareToken(address(new IsContract()));

    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("sc1"));

    uint128 constant AMOUNT = 200;
    uint256 constant COST = 123;

    SpokeV3_1_0 spokeV3_1_0 = new SpokeV3_1_0(AUTH);

    function setUp() public {
        vm.deal(GROVE, 1 ether);
        vm.startPrank(AUTH);
        spokeV3_1_0.file("spoke", address(spoke));
        spokeV3_1_0.file("spokeRegistry", address(spokeRegistry));
        vm.stopPrank();

        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.shareToken.selector, POOL_A, SC_1),
            abi.encode(share)
        );
    }

    /// @dev The v3.1.0 6-arg signature forwards the caller as the share `owner` to Spoke (extraGasLimit 0, refund
    ///      the caller). The transfer-restriction check now lives in core Spoke via the registrar, not in this facade.
    function testCrosschainTransferSharesForwardsCallerAsOwner() public {
        uint128 remoteExtraGasLimit = 100;

        vm.mockCall(address(spoke), abi.encodeWithSelector(ISpoke.crosschainTransferShares.selector), abi.encode());

        vm.expectCall(
            address(spoke),
            COST,
            abi.encodeCall(
                ISpoke.crosschainTransferShares,
                (
                    REMOTE_CENTRIFUGE_ID,
                    POOL_A,
                    SC_1,
                    RECEIVER.toBytes32(),
                    GROVE,
                    GROVE,
                    AMOUNT,
                    0,
                    remoteExtraGasLimit,
                    GROVE
                )
            )
        );

        vm.prank(GROVE);
        spokeV3_1_0.crosschainTransferShares{value: COST}(
            REMOTE_CENTRIFUGE_ID, POOL_A, SC_1, RECEIVER.toBytes32(), AMOUNT, remoteExtraGasLimit
        );
    }
}
