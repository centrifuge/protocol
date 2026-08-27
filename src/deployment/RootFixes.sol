// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {NonCoreReport} from "./ActionBatchers.sol";

import {Root} from "../admin/Root.sol";

/// @title  RootFixes
/// @notice The part of the deployment wiring that only Root can perform, for a chain whose Root the
///         deployment did not deploy.
/// @dev    The action batchers wire the protocol from their constructors, which works because a Root deployed
///         alongside them wards them from its own. One that was already on the chain wards nobody new, so
///         everything reaching into it has to be deferred: this is deployed with the protocol and does that
///         work once governance has relied it, over the ordinary spell route. `cast()` is permissionless
///         because the authority is the ward, not the caller.
contract RootFixes {
    Root public immutable root;
    address public immutable spoke;
    address public immutable vaultRouter;
    address public immutable tokenBridge;
    address public immutable shareManager;
    address public immutable messageProcessor;
    address public immutable protocolGuardian;
    address public immutable messageDispatcher;
    address public immutable asyncRequestManager;

    bool public done;

    error AlreadyCast();

    constructor(NonCoreReport memory report) {
        root = report.core.root;
        spoke = address(report.core.spoke);
        vaultRouter = address(report.vaultRouter);
        tokenBridge = address(report.tokenBridge);
        shareManager = address(report.shareManager);
        messageProcessor = address(report.core.messageProcessor);
        protocolGuardian = address(report.core.protocolGuardian);
        messageDispatcher = address(report.core.messageDispatcher);
        asyncRequestManager = address(report.asyncRequestManager);
    }

    /// @notice Grants and endorses what the action batchers skipped, then hands the ward back.
    function cast() external {
        require(!done, AlreadyCast());
        done = true;

        root.rely(messageDispatcher);
        root.rely(messageProcessor);
        root.rely(protocolGuardian);

        root.endorse(spoke);
        root.endorse(asyncRequestManager);
        root.endorse(vaultRouter);
        root.endorse(tokenBridge);
        root.endorse(shareManager);

        root.deny(address(this));
    }
}
