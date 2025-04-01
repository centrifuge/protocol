// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Recon Deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {Properties} from "../Properties.sol";
import {vm} from "@chimera/Hevm.sol";

// Dependencies
import {ERC20} from "src/misc/ERC20.sol";
import {AsyncVault} from "src/vaults/AsyncVault.sol";

/**
 * A collection of handlers that interact with the Liquidity Pool
 * NOTE: The following external functions have been skipped
 * - requestDepositWithPermit
 * - vault_emitDepositClaimable
 * - vault_emitRedeemClaimable
 * - vault_file
 */
abstract contract VaultFunctions is BaseTargetFunctions, Properties {
    /// @dev Get the balance of the current assetErc20 and actor
    function _getTokenAndBalanceForVault() internal view returns (uint256) {
        // Token
        uint256 amt = assetErc20.balanceOf(actor);

        return amt;
    }

    // === REQUEST === //
    function vault_requestDeposit(uint256 assets) public {
        assets = between(assets, 0, _getTokenAndBalanceForVault());

        assetErc20.approve(address(vault), assets);
        address to = actor; // NOTE: We transfer to self for now

        // B4 Balances
        uint256 balanceB4 = assetErc20.balanceOf(actor);
        uint256 balanceOfEscrowB4 = assetErc20.balanceOf(address(escrow));

        bool hasReverted;
        try vault.requestDeposit(assets, to, actor) {
            // TF-1
            sumOfDepositRequests[address(assetErc20)] += assets;

            requestDepositAssets[actor][address(assetErc20)] += assets;
        } catch {
            hasReverted = true;
        }

        // If not member
        (bool isMember,) = restrictionManager.isMember(address(token), actor);
        if (!isMember) {
            t(hasReverted, "LP-1 Must Revert");
        }

        if (
            restrictionManager.isFrozen(address(token), actor) == true
                || restrictionManager.isFrozen(address(token), to) == true
        ) {
            t(hasReverted, "LP-2 Must Revert");
        }

        // After Balances and Checks
        uint256 balanceAfter = assetErc20.balanceOf(actor);
        uint256 balanceOfEscrowAfter = assetErc20.balanceOf(address(escrow));

        // NOTE: We only enforce the check if the tx didn't revert
        if (!hasReverted) {
            // Extra check
            // NOTE: Unchecked so we get broken property and debug faster
            uint256 deltaUser = balanceB4 - balanceAfter;
            uint256 deltaEscrow = balanceOfEscrowAfter - balanceOfEscrowB4;

            if (RECON_EXACT_BAL_CHECK) {
                eq(deltaUser, assets, "Extra LP-1");
            }

            eq(deltaUser, deltaEscrow, "7540-11");
        }
    }

    function vault_requestRedeem(uint256 shares) public {
        address to = actor; // TODO: donation / changes

        // B4 Balances
        uint256 balanceB4 = token.balanceOf(actor);
        uint256 balanceOfEscrowB4 = token.balanceOf(address(escrow));

        token.approve(address(vault), shares);

        bool hasReverted;
        try vault.requestRedeem(shares, to, actor) {
            sumOfRedeemRequests[address(token)] += shares; // E-2
            requestRedeemShares[actor][address(token)] += shares;
        } catch {
            hasReverted = true;
        }

        if (
            restrictionManager.isFrozen(address(token), actor) == true
                || restrictionManager.isFrozen(address(token), to) == true
        ) {
            t(hasReverted, "LP-2 Must Revert");
        }

        // After Balances and Checks
        uint256 balanceAfter = token.balanceOf(actor);
        uint256 balanceOfEscrowAfter = token.balanceOf(address(escrow));

        // NOTE: We only enforce the check if the tx didn't revert
        if (!hasReverted) {
            // Extra check
            unchecked {
                uint256 deltaUser = balanceB4 - balanceAfter;
                uint256 deltaEscrow = balanceOfEscrowAfter - balanceOfEscrowB4;
                emit DebugNumber(deltaUser);
                emit DebugNumber(shares);
                emit DebugNumber(deltaEscrow);

                if (RECON_EXACT_BAL_CHECK) {
                    eq(deltaUser, shares, "Extra LP-1");
                }

                eq(deltaUser, deltaEscrow, "7540-12");
            }
        }
    }

    // === CANCEL === //

    function vault_cancelDepositRequest() public {
        vault.cancelDepositRequest(REQUEST_ID, actor);
    }

    function vault_cancelRedeemRequest() public {
        vault.cancelRedeemRequest(REQUEST_ID, actor);
    }

    function vault_claimCancelDepositRequest() public {
        address to = actor; // NOTE: We transfer to self for now

        uint256 assets = vault.claimCancelDepositRequest(REQUEST_ID, to, actor);
        sumOfClaimedDepositCancelations[address(assetErc20)] += assets;
    }

    function vault_claimCancelRedeemRequest() public {
        address to = actor; // NOTE: We transfer to self for now

        uint256 shares = vault.claimCancelRedeemRequest(REQUEST_ID, to, actor);
        sumOfClaimedRedeemCancelations[address(token)] += shares;
    }

    function vault_deposit(uint256 assets) public {
        // Bal b4
        uint256 shareUserB4 = token.balanceOf(actor);
        uint256 shareEscrowB4 = token.balanceOf(address(escrow));

        uint256 shares = vault.deposit(assets, address(this));

        // Processed Deposit | E-2 | Global-1
        sumOfClaimedDeposits[address(token)] += shares;

        // Bal after
        uint256 shareUserAfter = token.balanceOf(actor);
        uint256 shareEscrowAfter = token.balanceOf(address(escrow));

        // Extra check | // TODO: This math will prob overflow
        // NOTE: Unchecked so we get broken property and debug faster
        unchecked {
            uint256 deltaUser = shareUserAfter - shareUserB4; // B4 - after -> They pay
            uint256 deltaEscrow = shareEscrowB4 - shareEscrowAfter; // After - B4 -> They gain
            emit DebugNumber(deltaUser);
            emit DebugNumber(assets);
            emit DebugNumber(deltaEscrow);

            if (RECON_EXACT_BAL_CHECK) {
                eq(deltaUser, assets, "Extra LP-2");
            }

            eq(deltaUser, deltaEscrow, "7540-13");
        }
    }

    // Given a random value, see if the other one would yield more shares or lower cost
    // Not only check view
    // Also do it and test it via revert test
    // TODO: Mint Deposit Arb Test
    // TODO: Withdraw Redeem Arb Test

    // TODO: See how these go
    // TODO: Receiver -> Not this
    function vault_mint(uint256 shares) public {
        address to = actor; // TODO: donation / changes

        // Bal b4
        uint256 shareUserB4 = token.balanceOf(actor);
        uint256 shareEscrowB4 = token.balanceOf(address(escrow));

        vault.mint(shares, to);

        // Processed Deposit | E-2
        sumOfClaimedDeposits[address(token)] += shares;

        // Bal after
        uint256 shareUserAfter = token.balanceOf(actor);
        uint256 shareEscrowAfter = token.balanceOf(address(escrow));

        // Extra check | // TODO: This math will prob overflow
        // NOTE: Unchecked so we get broken property and debug faster
        unchecked {
            uint256 deltaUser = shareUserAfter - shareUserB4; // B4 - after -> They pay
            uint256 deltaEscrow = shareEscrowB4 - shareEscrowAfter; // After - B4 -> They gain
            emit DebugNumber(deltaUser);
            emit DebugNumber(shares);
            emit DebugNumber(deltaEscrow);

            if (RECON_EXACT_BAL_CHECK) {
                eq(deltaUser, shares, "Extra LP-2");
            }

            eq(deltaUser, deltaEscrow, "7540-13");
        }
    }

    // TODO: Params
    function vault_redeem(uint256 shares) public {
        address to = actor; // TODO: donation / changes

        // Bal b4
        uint256 tokenUserB4 = assetErc20.balanceOf(actor);
        uint256 tokenEscrowB4 = assetErc20.balanceOf(address(escrow));

        uint256 assets = vault.redeem(shares, actor, to);

        // E-1
        sumOfClaimedRedemptions[address(assetErc20)] += assets;

        // Bal after
        uint256 tokenUserAfter = assetErc20.balanceOf(actor);
        uint256 tokenEscrowAfter = assetErc20.balanceOf(address(escrow));

        // Extra check | // TODO: This math will prob overflow
        // NOTE: Unchecked so we get broken property and debug faster
        unchecked {
            uint256 deltaUser = tokenUserAfter - tokenUserB4;

            // TODO: NOTE FOT extra, verifies the transfer amount matches the returned amount
            t(deltaUser == assets, "FoT-1");

            uint256 deltaEscrow = tokenEscrowB4 - tokenEscrowAfter;
            emit DebugNumber(deltaUser);
            emit DebugNumber(shares);
            emit DebugNumber(deltaEscrow);

            if (RECON_EXACT_BAL_CHECK) {
                eq(deltaUser, shares, "Extra LP-3");
            }

            eq(deltaUser, deltaEscrow, "7540-14");
        }
    }

    // TODO: Params
    function vault_withdraw(uint256 assets) public {
        address to = actor; // TODO: donation / changes

        // Bal b4
        uint256 tokenUserB4 = assetErc20.balanceOf(actor);
        uint256 tokenEscrowB4 = assetErc20.balanceOf(address(escrow));

        vault.withdraw(assets, actor, to);

        // E-1
        sumOfClaimedRedemptions[address(assetErc20)] += assets;

        // Bal after
        uint256 tokenUserAfter = assetErc20.balanceOf(actor);
        uint256 tokenEscrowAfter = assetErc20.balanceOf(address(escrow));

        // Extra check | // TODO: This math will prob overflow
        // NOTE: Unchecked so we get broken property and debug faster
        unchecked {
            uint256 deltaUser = tokenUserAfter - tokenUserB4;
            uint256 deltaEscrow = tokenEscrowB4 - tokenEscrowAfter;
            emit DebugNumber(deltaUser);
            emit DebugNumber(assets);
            emit DebugNumber(deltaEscrow);

            if (RECON_EXACT_BAL_CHECK) {
                eq(deltaUser, assets, "Extra LP-3");
            }

            eq(deltaUser, deltaEscrow, "7540-14");
        }
    }
}
