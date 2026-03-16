// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Root} from "../../../../src/admin/Root.sol";

import {BaseValidator, ValidationContext} from "../../spell/utils/validation/BaseValidator.sol";

/// @title Validate_Endorsements
/// @notice Validates that Root endorsements are set for balanceSheet, asyncRequestManager, and vaultRouter.
contract Validate_Endorsements is BaseValidator("Endorsements") {
    function validate(ValidationContext memory ctx) public override {
        Root root = Root(ctx.contracts.live.root);

        _checkEndorsed(root, ctx.contracts.live.balanceSheet, "balanceSheet");
        _checkEndorsed(root, ctx.contracts.live.asyncRequestManager, "asyncRequestManager");
        _checkEndorsed(root, ctx.contracts.live.vaultRouter, "vaultRouter");
    }

    function _checkEndorsed(Root root, address target, string memory label) internal {
        if (target == address(0)) return;
        if (target.code.length == 0) return;
        if (!root.endorsed(target)) {
            _errors.push(_buildError("endorsed", label, "true", "false", string.concat(label, " not endorsed by Root")));
        }
    }
}
