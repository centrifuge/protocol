// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {CastLib} from "src/misc/libraries/CastLib.sol";

import {IRoot} from "src/common/interfaces/IRoot.sol";
import {ITokenRecoverer} from "src/common/interfaces/ITokenRecoverer.sol";
import {MessageProcessor, IMessageProcessor} from "src/common/MessageProcessor.sol";
import {MessageLib} from "src/common/libraries/MessageLib.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {IUpdateContract} from "src/common/interfaces/IUpdateContract.sol";

contract TestMessageProcessor is Test {
    using MessageLib for *;
    using CastLib for *;

    MessageProcessor processor = new MessageProcessor(IRoot(address(0)), ITokenRecoverer(address(0)), address(this));

    function testUpdateContract(PoolId poolId, ShareClassId scId, address target, bytes memory payload) public {
        bytes memory message = MessageLib.UpdateContract({
            poolId: poolId.raw(),
            scId: scId.raw(),
            target: target.toBytes32(),
            payload: payload
        }).serialize();

        vm.mockCall(
            target, abi.encodeWithSelector(IUpdateContract.update.selector, poolId, scId, payload), abi.encode()
        );

        vm.expectEmit();
        emit IMessageProcessor.UpdateContract(poolId, scId, target, payload);
        processor.handle(poolId.centrifugeId(), message);
    }
}
