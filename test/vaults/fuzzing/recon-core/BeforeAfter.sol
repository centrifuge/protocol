// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {MockERC20} from "@recon/MockERC20.sol";

import {Setup} from "./Setup.sol";
import {AsyncInvestmentState} from "src/vaults/interfaces/investments/IAsyncRequests.sol";
import {Ghosts} from "./helpers/Ghosts.sol";

enum OpType {
    GENERIC, // generic operations can be performed by both users and admins
    ADMIN // admin operations can only be performed by admins
}

abstract contract BeforeAfter is Ghosts {

    struct BeforeAfterVars {
        mapping(address investor => AsyncInvestmentState) investments;
        uint256 escrowTokenBalance;
        uint256 escrowTrancheTokenBalance;
        uint256 totalAssets;
        uint256 actualAssets;
        uint256 pricePerShare;
    }

    BeforeAfterVars internal _before;
    BeforeAfterVars internal _after;
    OpType internal currentOperation;

    modifier updateGhosts() {
        currentOperation = OpType.GENERIC;
        __before();
        _;
        __after();
    }

    modifier updateGhostsWithType(OpType op) {
        currentOperation = op;
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
            ) = asyncRequests.investments(address(vault), actors[i]);
            _before.investments[actors[i]] = AsyncInvestmentState(
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
        _before.escrowTokenBalance = MockERC20(_getAsset()).balanceOf(address(escrow));
        _before.escrowTrancheTokenBalance = token.balanceOf(address(escrow));
        _before.totalAssets = vault.totalAssets();
        _before.actualAssets = MockERC20(vault.asset()).balanceOf(address(vault));
        _before.pricePerShare = vault.pricePerShare();
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
            ) = asyncRequests.investments(address(vault), actors[i]);
            _after.investments[actors[i]] = AsyncInvestmentState(
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
        _after.escrowTokenBalance = MockERC20(_getAsset()).balanceOf(address(escrow));
        _after.escrowTrancheTokenBalance = token.balanceOf(address(escrow));
        _after.totalAssets = vault.totalAssets();
        _after.actualAssets = MockERC20(vault.asset()).balanceOf(address(vault));
        _after.pricePerShare = vault.pricePerShare();
    }
}
