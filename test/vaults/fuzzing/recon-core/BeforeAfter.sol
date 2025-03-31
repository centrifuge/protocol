// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {Setup} from "./Setup.sol";
import {InvestmentState} from "src/vaults/interfaces/IInvestmentManager.sol";
import {Ghosts} from "./Ghosts.sol";

abstract contract BeforeAfter is Ghosts {

    struct BeforeAfterVars {
        mapping(address investor => InvestmentState) investments;
        uint256 escrowTokenBalance;
        uint256 escrowTrancheTokenBalance;
    }

    BeforeAfterVars internal _before;
    BeforeAfterVars internal _after;

    modifier updateBeforeAfter() {
        __before();
        _;
        __after();
    }

    function __before() internal {
        address[] memory actors = _getActors();
        for (uint256 i = 0; i < actors.length; i++) {
            (
                uint128 maxMint,
                uint128 maxWithdraw,
                uint256 depositPrice,
                uint256 redeemPrice,
                uint128 pendingDepositRequest,
                uint128 pendingRedeemRequest,
                uint128 claimableCancelDepositRequest,
                uint128 claimableCancelRedeemRequest,
                bool pendingCancelDepositRequest,
                bool pendingCancelRedeemRequest
            ) = investmentManager.investments(address(vault), actors[i]);
            _before.investments[actors[i]] = InvestmentState(
                maxMint,
                maxWithdraw,
                depositPrice,
                redeemPrice,
                pendingDepositRequest,
                pendingRedeemRequest,
                claimableCancelDepositRequest,
                claimableCancelRedeemRequest,
                pendingCancelDepositRequest,
                pendingCancelRedeemRequest
            );
        }
        _before.escrowTokenBalance = token.balanceOf(address(escrow));
        _before.escrowTrancheTokenBalance = trancheToken.balanceOf(address(escrow));
    }

    function __after() internal {
        address[] memory actors = _getActors();
        for (uint256 i = 0; i < actors.length; i++) {
            (
                uint128 maxMint,
                uint128 maxWithdraw,
                uint256 depositPrice,
                uint256 redeemPrice,
                uint128 pendingDepositRequest,
                uint128 pendingRedeemRequest,
                uint128 claimableCancelDepositRequest,
                uint128 claimableCancelRedeemRequest,
                bool pendingCancelDepositRequest,
                bool pendingCancelRedeemRequest
            ) = investmentManager.investments(address(vault), actors[i]);
            _after.investments[actors[i]] = InvestmentState(
                maxMint,
                maxWithdraw,
                depositPrice,
                redeemPrice,
                pendingDepositRequest,
                pendingRedeemRequest,
                claimableCancelDepositRequest,
                claimableCancelRedeemRequest,
                pendingCancelDepositRequest,
                pendingCancelRedeemRequest
            );
        }
        _after.escrowTokenBalance = token.balanceOf(address(escrow));
        _after.escrowTrancheTokenBalance = trancheToken.balanceOf(address(escrow));
    }
}
