// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {vm} from "@chimera/Hevm.sol";
import {OpType} from "../BeforeAfter.sol";
import {Properties} from "../properties/Properties.sol";
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";

/// @notice Investor-to-investor share transfers under the pool's FullRestrictions hook.
abstract contract ShareTokenTargets is BaseTargetFunctions, Properties {
    /// @dev Must revert to or from a frozen investor, and to a recipient who is not a member.
    function token_transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) public updateGhosts(OpType.USER) {
        address from = _shareHolder(fromSeed);
        address to = _recipient(toSeed);
        uint256 balance = shareA.balanceOf(from);
        if (from == to || balance == 0) return;
        amount = between(amount, 1, balance);

        (bool success,) = _callAs(from, address(shareA), abi.encodeCall(shareA.transfer, (to, amount)));
        _checkTransfer(success, from, to, "token_transfer");
    }

    function token_transferFrom(uint256 fromSeed, uint256 toSeed, uint256 amount) public updateGhosts(OpType.USER) {
        address from = _shareHolder(fromSeed);
        address to = _recipient(toSeed);
        address spender = _actor(fromSeed + 1);
        uint256 balance = shareA.balanceOf(from);
        if (from == to || balance == 0) return;
        amount = between(amount, 1, balance);

        vm.prank(from);
        shareA.approve(spender, amount);
        (bool success,) = _callAs(spender, address(shareA), abi.encodeCall(shareA.transferFrom, (from, to, amount)));
        _checkTransfer(success, from, to, "token_transferFrom");
    }

    function _checkTransfer(bool success, address from, address to, bytes32 action) internal {
        if (!success) return _reverted(action);
        t(!frozen[from] && !frozen[to], "a transfer to or from a frozen investor went through");
        t(to != OUTSIDER || block.timestamp <= outsiderValidUntil, "a transfer to a non-member went through");
        _ok(action);
    }

    /// @dev Mostly investors, sometimes the outsider whose membership the fuzzer toggles. Endorsed
    ///      contracts are left out: the hook admits them as recipients by design.
    function _recipient(uint256 seed) internal view returns (address) {
        return seed % 5 == 4 ? OUTSIDER : _actor(seed);
    }
}
