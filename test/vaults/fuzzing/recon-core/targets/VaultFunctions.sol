// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Recon Deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {vm} from "@chimera/Hevm.sol";
import {MockERC20} from "@recon/MockERC20.sol";

// Dependencies
import {ERC7540Vault} from "src/vaults/ERC7540Vault.sol";

import {Properties} from "../Properties.sol";

/**
 * A collection of handlers that interact with the Liquidity Pool
 * NOTE: The following external functions have been skipped
 * - requestDepositWithPermit
 * - vault_emitDepositClaimable
 * - vault_emitRedeemClaimable
 * - vault_file
 */
abstract contract VaultFunctions is BaseTargetFunctions, Properties {
    /// @dev Get the balance of the current asset and actor
    function _getTokenAndBalanceForVault() internal view returns (uint256) {
        // Token
        uint256 amt = MockERC20(_getAsset()).balanceOf(_getActor());

        return amt;
    }

    // === REQUEST === //
    function vault_requestDeposit(uint256 assets, uint256 toEntropy) public updateGhosts {
        assets = between(assets, 0, _getTokenAndBalanceForVault());

        MockERC20(_getAsset()).approve(address(vault), assets);
        address to = _getRandomActor(toEntropy); // request for any of the actors

        // B4 Balances
        uint256 balanceB4 = MockERC20(_getAsset()).balanceOf(_getActor());
        uint256 balanceOfEscrowB4 = MockERC20(_getAsset()).balanceOf(address(escrow));

        bool hasReverted;

        // NOTE: external calls above so need to prank directly here
        vm.prank(_getActor());
        try vault.requestDeposit(assets, to, _getActor()) {
            // TF-1
            sumOfDepositRequests[address(MockERC20(_getAsset()))] += assets;

            requestDepositAssets[_getActor()][address(MockERC20(_getAsset()))] += assets;
        } catch {
            hasReverted = true;
        }

        // If not member
        (bool isMember,) = restrictionManager.isMember(address(trancheToken), to);
        if (!isMember) {
            t(hasReverted, "LP-1 Must Revert");
        }

        if (
            restrictionManager.isFrozen(address(trancheToken), _getActor()) == true
                || restrictionManager.isFrozen(address(trancheToken), to) == true
        ) {
            t(hasReverted, "LP-2 Must Revert");
        }

        if (!poolManager.isAllowedAsset(poolId, _getAsset())) {
            // TODO: Ensure this works via _getActor() switch
            t(hasReverted, "LP-3 Must Revert");
        }

        // After Balances and Checks
        uint256 balanceAfter = MockERC20(_getAsset()).balanceOf(_getActor());
        uint256 balanceOfEscrowAfter = MockERC20(_getAsset()).balanceOf(address(escrow));

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

    function vault_requestRedeem(uint256 shares, uint256 toEntropy) public updateGhosts {
        address to = _getRandomActor(toEntropy); // TODO: donation / changes

        // B4 Balances
        uint256 balanceB4 = trancheToken.balanceOf(_getActor());
        uint256 balanceOfEscrowB4 = trancheToken.balanceOf(address(escrow));

        trancheToken.approve(address(vault), shares);

        bool hasReverted;
        // NOTE: external calls above so need to prank directly here
        vm.prank(_getActor());
        try vault.requestRedeem(shares, to, _getActor()) {
            sumOfRedeemRequests[address(trancheToken)] += shares; // E-2
            requestRedeemShares[_getActor()][address(trancheToken)] += shares;
        } catch {
            hasReverted = true;
        }

        if (
            restrictionManager.isFrozen(address(trancheToken), _getActor()) == true
                || restrictionManager.isFrozen(address(trancheToken), to) == true
        ) {
            t(hasReverted, "LP-2 Must Revert");
        }

        // After Balances and Checks
        uint256 balanceAfter = trancheToken.balanceOf(_getActor());
        uint256 balanceOfEscrowAfter = trancheToken.balanceOf(address(escrow));

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

    function vault_cancelDepositRequest() public updateGhosts asActor {
        vault.cancelDepositRequest(REQUEST_ID, _getActor());
    }

    function vault_cancelRedeemRequest() public updateGhosts asActor {
        vault.cancelRedeemRequest(REQUEST_ID, _getActor());
    }

    function vault_claimCancelDepositRequest(uint256 toEntropy) public updateGhosts asActor {
        address to = _getRandomActor(toEntropy);

        uint256 assets = vault.claimCancelDepositRequest(REQUEST_ID, to, _getActor());
        sumOfClaimedDepositCancelations[_getAsset()] += assets;
    }

    function vault_claimCancelRedeemRequest(uint256 toEntropy) public updateGhosts asActor {
        address to = _getRandomActor(toEntropy);

        uint256 shares = vault.claimCancelRedeemRequest(REQUEST_ID, to, _getActor());
        sumOfClaimedRedeemCancelations[address(trancheToken)] += shares;
    }

    function vault_deposit(uint256 assets) public updateGhosts {
        // Bal b4
        uint256 trancheUserB4 = trancheToken.balanceOf(_getActor());
        uint256 trancheEscrowB4 = trancheToken.balanceOf(address(escrow));

        // NOTE: external calls above so need to prank directly here
        vm.prank(_getActor());
        uint256 shares = vault.deposit(assets, _getActor());

        // Processed Deposit | E-2 | Global-1
        sumOfClaimedDeposits[address(trancheToken)] += shares;

        // Bal after
        uint256 trancheUserAfter = trancheToken.balanceOf(_getActor());
        uint256 trancheEscrowAfter = trancheToken.balanceOf(address(escrow));

        // Extra check | // TODO: This math will prob overflow
        // NOTE: Unchecked so we get broken property and debug faster
        unchecked {
            uint256 deltaUser = trancheUserAfter - trancheUserB4; // B4 - after -> They pay
            uint256 deltaEscrow = trancheEscrowB4 - trancheEscrowAfter; // After - B4 -> They gain
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
    function vault_mint(uint256 shares, uint256 toEntropy) public updateGhosts {
        address to = _getRandomActor(toEntropy);

        // Bal b4
        uint256 trancheUserB4 = trancheToken.balanceOf(_getActor());
        uint256 trancheEscrowB4 = trancheToken.balanceOf(address(escrow));

        // NOTE: external calls above so need to prank directly here
        vm.prank(_getActor());
        vault.mint(shares, to);

        // Processed Deposit | E-2
        sumOfClaimedDeposits[address(trancheToken)] += shares;

        // Bal after
        uint256 trancheUserAfter = trancheToken.balanceOf(_getActor());
        uint256 trancheEscrowAfter = trancheToken.balanceOf(address(escrow));

        // Extra check | // TODO: This math will prob overflow
        // NOTE: Unchecked so we get broken property and debug faster
        unchecked {
            uint256 deltaUser = trancheUserAfter - trancheUserB4; // B4 - after -> They pay
            uint256 deltaEscrow = trancheEscrowB4 - trancheEscrowAfter; // After - B4 -> They gain
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
    function vault_redeem(uint256 shares, uint256 toEntropy) public updateGhosts {
        address to = _getRandomActor(toEntropy);

        // Bal b4
        uint256 balanceUserB4 = MockERC20(_getAsset()).balanceOf(_getActor());
        uint256 balanceEscrowB4 = MockERC20(_getAsset()).balanceOf(address(escrow));

        // NOTE: external calls above so need to prank directly here
        vm.prank(_getActor());
        uint256 assets = vault.redeem(shares, _getActor(), to);

        // E-1
        sumOfClaimedRedemptions[address(MockERC20(_getAsset()))] += assets;

        // Bal after
        uint256 balanceUserAfter = MockERC20(_getAsset()).balanceOf(_getActor());
        uint256 balanceEscrowAfter = MockERC20(_getAsset()).balanceOf(address(escrow));

        // Extra check | // TODO: This math will prob overflow
        // NOTE: Unchecked so we get broken property and debug faster
        unchecked {
            uint256 deltaUser = balanceUserAfter - balanceUserB4;

            // TODO: NOTE FOT extra, verifies the transfer amount matches the returned amount
            t(deltaUser == assets, "FoT-1");

            uint256 deltaEscrow = balanceEscrowB4 - balanceEscrowAfter;
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
    function vault_withdraw(uint256 assets, uint256 toEntropy) public updateGhosts {
        address to = _getRandomActor(toEntropy);

        // Bal b4
        uint256 balanceUserB4 = MockERC20(_getAsset()).balanceOf(_getActor());
        uint256 balanceEscrowB4 = MockERC20(_getAsset()).balanceOf(address(escrow));

        // NOTE: external calls above so need to prank directly here
        vm.prank(_getActor());
        vault.withdraw(assets, _getActor(), to);

        // E-1
        sumOfClaimedRedemptions[_getAsset()] += assets;

        // Bal after
        uint256 balanceUserAfter = MockERC20(_getAsset()).balanceOf(_getActor());
        uint256 balanceEscrowAfter = MockERC20(_getAsset()).balanceOf(address(escrow));

        // Extra check | // TODO: This math will prob overflow
        // NOTE: Unchecked so we get broken property and debug faster
        unchecked {
            uint256 deltaUser = balanceUserAfter - balanceUserB4;
            uint256 deltaEscrow = balanceEscrowB4 - balanceEscrowAfter;
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
