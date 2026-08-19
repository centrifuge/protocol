// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IProtocolGuardian} from "../../src/admin/interfaces/IProtocolGuardian.sol";

import "forge-std/Script.sol";

import {Safe, Enum} from "safe-utils/Safe.sol";
import {PROTOCOL_SAFE, ledgerDerivationPath} from "../utils/Admin.s.sol";

contract ProposeUnpause is Script {
    using Safe for *;

    address constant PROTOCOL_GUARDIAN = 0xCEb7eD5d5B3bAD3088f6A1697738B60d829635c6;

    Safe.Client safe;

    function run() public {
        vm.startBroadcast();

        safe.initialize(PROTOCOL_SAFE);

        bytes memory data = abi.encodeCall(IProtocolGuardian.unpause, ());

        safe.proposeTransactionWithSignature(
            PROTOCOL_GUARDIAN,
            data,
            msg.sender,
            safe.sign(PROTOCOL_GUARDIAN, data, Enum.Operation.Call, msg.sender, ledgerDerivationPath())
        );

        vm.stopBroadcast();
    }
}
