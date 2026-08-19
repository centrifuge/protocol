// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PROTOCOL_SAFE} from "../utils/Admin.s.sol";
import {Env, EnvConfig} from "../utils/EnvConfig.s.sol";
import {IDeployGate} from "../utils/gate/IDeployGate.sol";
import {DeployGateScript} from "../utils/gate/DeployGateScript.sol";

/// @title  ProposeSetDelegate
/// @notice Proposes a DeployGate.setDelegate call through the protocol Safe, which is the validator every
///         mainnet address derives from.
/// @dev    The Safe is the validator because it is the same address on every chain and can never be
///         replaced, but it cannot sign a forge broadcast, so it does not sign the deployment phases: it
///         names a delegate here, once per chain, and that delegate signs `validate()` from a key.
///
///         Nothing here is broadcast. A chain with no gate needs one before a delegate can be named in it,
///         so the gate's deployment rides along in the same Safe transaction rather than being broadcast
///         beside it: the proposal is posted over ffi the moment it is signed, while a broadcast is deferred
///         to the end of the run, so a run that did both would post the proposal and then fail to send the
///         deployment, leaving the delegate named in a gate that is not there.
///
///         The network comes from the chain `--rpc-url` points at. DELEGATE_ADDR is the account being named,
///         and is the only env var this needs.
///
///         Example usage:
///           DELEGATE_ADDR=0xabc... forge script script/ops/ProposeSetDelegate.s.sol --sig 'grant()' \
///             --rpc-url ethereum --sender <proposer> --ffi
///           DELEGATE_ADDR=0xabc... forge script script/ops/ProposeSetDelegate.s.sol --sig 'revoke()' \
///             --rpc-url ethereum --sender <proposer> --ffi
///
///         Granting and revoking are separate entry points rather than a boolean, because this ends in a
///         Safe transaction that people sign off on: what it does should be in the command, not in a
///         variable that reads the same either way.
contract ProposeSetDelegate is DeployGateScript {
    /// @notice Lets the delegate commit in the validator's namespace
    function grant() external {
        _propose(true);
    }

    /// @notice Stops it. One call, unlike an executor, which lives in the commitment and needs a new one
    function revoke() external {
        _propose(false);
    }

    function run() external pure {
        revert("Pass --sig 'grant()' to name a delegate, or --sig 'revoke()' to drop one");
    }

    function _propose(bool isValid) internal {
        EnvConfig memory config = Env.load();

        // Off mainnet the validator is a key, which names its own delegates without a proposal, and
        // protocolAdmin is an EOA that would not answer as a Safe below
        require(config.network.isMainnet(), "The validator is a Safe only on mainnet");

        // Has to be the very account LaunchDeployer commits under, or the delegate lands in a namespace
        // no deployment reads
        address validator = config.network.protocolAdmin;
        require(validator == PROTOCOL_SAFE, "protocolAdmin is not the validator LaunchDeployer commits under");

        address delegate = vm.envAddress("DELEGATE_ADDR");

        proposeGateCall(validator, abi.encodeCall(IDeployGate.setDelegate, (delegate, isValid)));
    }
}
