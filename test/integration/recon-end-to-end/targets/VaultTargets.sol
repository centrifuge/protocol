// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Recon Deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {vm} from "@chimera/Hevm.sol";
import {MockERC20} from "@recon/MockERC20.sol";
import {Panic} from "@recon/Panic.sol";
import {console2} from "forge-std/console2.sol";

// Dependencies
import {AsyncVault} from "src/vaults/AsyncVault.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";

import {Helpers} from "test/hub/fuzzing/recon-hub/utils/Helpers.sol";
import {Properties} from "test/integration/recon-end-to-end/properties/Properties.sol";

/**
 * A collection of handlers that interact with the Liquidity Pool
 * NOTE: The following external functions have been skipped
 * - requestDepositWithPermit
 * - vault_emitDepositClaimable
 * - vault_emitRedeemClaimable
 * - vault_file
 */
abstract contract VaultTargets is BaseTargetFunctions, Properties {
    using CastLib for *;
    
    /// @dev Get the balance of the current assetErc20 and _getActor()
    function _getTokenAndBalanceForVault() internal view returns (uint256) {
        // Token
        uint256 amt = MockERC20(_getAsset()).balanceOf(_getActor());

        return amt;
    }

    // === REQUEST === //
    /// @dev Property: after successfully calling requestDeposit for an investor, their depositRequest[..].lastUpdate equals the current nowDepositEpoch
    /// @dev Property: _updateDepositRequest should never revert due to underflow
    /// @dev Property: The total pending deposit amount pendingDeposit[..] is always >= the sum of pending user deposit amounts depositRequest[..]
    function vault_requestDeposit(uint256 assets, uint256 toEntropy) public updateGhosts {
        assets = between(assets, 0, _getTokenAndBalanceForVault());
        address to = _getRandomActor(toEntropy);

        vm.prank(_getActor());
        MockERC20(_getAsset()).approve(address(vault), assets);

        // B4 Balances
        uint256 balanceB4 = MockERC20(_getAsset()).balanceOf(_getActor());
        uint256 balanceOfEscrowB4 = MockERC20(_getAsset()).balanceOf(address(globalEscrow));

        bool hasReverted;

        // NOTE: external calls above so need to prank directly here
        vm.prank(_getActor());
        try vault.requestDeposit(assets, to, _getActor()) {
            // ghost tracking
            requestDeposited[to] += assets;
            sumOfDepositRequests[address(_getAsset())] += assets;
            requestDepositAssets[to][address(_getAsset())] += assets;

            (uint128 pending, uint32 lastUpdate) = shareClassManager.depositRequest(ShareClassId.wrap(_getShareClassId()), AssetId.wrap(assetId), to.toBytes32());
            (uint32 depositEpochId,,, )= shareClassManager.epochId(ShareClassId.wrap(_getShareClassId()), AssetId.wrap(assetId));

            address[] memory _actors = _getActors();
            uint128 totalPendingDeposit = shareClassManager.pendingDeposit(ShareClassId.wrap(_getShareClassId()), AssetId.wrap(assetId));
            uint128 totalPendingUserDeposit = 0;
            for (uint256 k = 0; k < _actors.length; k++) {
                address actor = _actors[k];
                (uint128 pendingUserDeposit,) = shareClassManager.depositRequest(ShareClassId.wrap(_getShareClassId()), AssetId.wrap(assetId), actor.toBytes32());
                totalPendingUserDeposit += pendingUserDeposit;
            }

            // precondition: if user queues a cancellation but it doesn't get immediately executed, the epochId should not change
            if(Helpers.canMutate(lastUpdate, pending, depositEpochId)) {
                // nowDepositEpoch = depositEpochId + 1
                eq(lastUpdate, depositEpochId + 1, "lastUpdate != nowDepositEpoch"); 
                gte(totalPendingDeposit, totalPendingUserDeposit, "total pending deposit < sum of pending user deposit amounts"); 
            }
        } catch (bytes memory reason) {
            hasReverted = true;

            // precondition: check that it wasn't an overflow because we only care about underflow
            uint128 pendingDeposit = shareClassManager.pendingDeposit(ShareClassId.wrap(_getShareClassId()), AssetId.wrap(assetId));
            if(uint256(pendingDeposit) + uint256(assets) < uint256(type(uint128).max)) {
                bool arithmeticRevert = checkError(reason, Panic.arithmeticPanic);
                t(!arithmeticRevert, "depositRequest reverts with arithmetic panic");
            }
        }

        // If not member
        (bool isMember,) = fullRestrictions.isMember(address(token), _getActor());
        (bool isMemberTo,) = fullRestrictions.isMember(address(token), to);
        if (!isMember) {
            t(hasReverted, "LP-1 Must Revert");
        }

        if (
            fullRestrictions.isFrozen(address(token), _getActor()) == true
                || fullRestrictions.isFrozen(address(token), to) == true
        ) {
            t(hasReverted, "LP-2 Must Revert");
        }

        // After Balances and Checks
        uint256 balanceAfter = MockERC20(_getAsset()).balanceOf(_getActor());
        uint256 balanceOfEscrowAfter = MockERC20(_getAsset()).balanceOf(address(globalEscrow));

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

    function vault_requestDeposit_clamped(uint256 assets, uint256 toEntropy) public {
        assets = between(assets, 0, MockERC20(_getAsset()).balanceOf(_getActor()));
        address to = _getRandomActor(toEntropy);

        vault_requestDeposit(assets, toEntropy);
    }

    /// @dev Property: After successfully calling requestRedeem for an investor, their redeemRequest[..].lastUpdate equals nowRedeemEpoch
    function vault_requestRedeem(uint256 shares, uint256 toEntropy) public updateGhosts {
        address to = _getRandomActor(toEntropy); // TODO: donation / changes

        // B4 Balances
        uint256 balanceB4 = token.balanceOf(_getActor());
        uint256 balanceOfEscrowB4 = token.balanceOf(address(globalEscrow));

        vm.prank(_getActor());
        token.approve(address(vault), shares);

        bool hasReverted;
        // NOTE: external calls above so need to prank directly here
        vm.prank(_getActor());
        try vault.requestRedeem(shares, to, _getActor()) {
            // ghost tracking
            sumOfRedeemRequests[address(token)] += shares; // E-2
            requestRedeemShares[to][address(token)] += shares;
            requestRedeeemed[to] += shares;

            (, uint32 lastUpdate) = shareClassManager.redeemRequest(ShareClassId.wrap(_getShareClassId()), AssetId.wrap(assetId), to.toBytes32());
            (, uint32 redeemEpochId,, ) = shareClassManager.epochId(ShareClassId.wrap(_getShareClassId()), AssetId.wrap(assetId));

            // nowRedeemEpoch = redeemEpochId + 1
            eq(lastUpdate, redeemEpochId + 1, "lastUpdate != nowRedeemEpoch after redeemRequest");
        } catch {
            hasReverted = true;
        }

        if (
            fullRestrictions.isFrozen(address(token), _getActor()) == true
                || fullRestrictions.isFrozen(address(token), to) == true
        ) {
            t(hasReverted, "LP-2 Must Revert");
        }

        // After Balances and Checks
        uint256 balanceAfter = token.balanceOf(_getActor());
        uint256 balanceOfEscrowAfter = token.balanceOf(address(globalEscrow));

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

    function vault_requestRedeem_clamped(uint256 shares, uint256 toEntropy) public {
        shares = between(shares, 0, token.balanceOf(_getActor()));
        vault_requestRedeem(shares, toEntropy);
    }

    // === CANCEL === //

    /// @dev Property: after successfully calling cancelDepositRequest for an investor, their depositRequest[..].lastUpdate equals the current nowDepositEpoch
    /// @dev Property: after successfully calling cancelDepositRequest for an investor, their depositRequest[..].pending is zero
    /// @dev Property: cancelDepositRequest absolute value should never be higher than pendingDeposit (would result in underflow revert)
    /// @dev Property: _updateDepositRequest should never revert due to underflow
    /// @dev Property: The total pending deposit amount pendingDeposit[..] is always >= the sum of pending user deposit amounts depositRequest[..]
    function vault_cancelDepositRequest() public updateGhosts asActor {
        address controller = _getActor();
        (uint128 pendingBefore, uint32 lastUpdateBefore) = shareClassManager.depositRequest(ShareClassId.wrap(_getShareClassId()), AssetId.wrap(assetId), controller.toBytes32());
        (uint32 depositEpochId,,, )= shareClassManager.epochId(ShareClassId.wrap(_getShareClassId()), AssetId.wrap(assetId));
        uint256 pendingCancelBefore = vault.claimableCancelDepositRequest(0, _getActor());

        // REQUEST_ID is always passed as 0 (unused in the function)
        try vault.cancelDepositRequest(REQUEST_ID, controller) {
            (uint128 pendingAfter, uint32 lastUpdateAfter) = shareClassManager.depositRequest(ShareClassId.wrap(_getShareClassId()), AssetId.wrap(assetId), controller.toBytes32());
            uint256 pendingCancelAfter = vault.claimableCancelDepositRequest(0, _getActor());

            // update ghosts
            cancelledDeposits[controller] += (pendingBefore - pendingAfter);
            cancelDepositCurrencyPayout[_getAsset()] += pendingCancelAfter - pendingCancelBefore;

            // precondition: if user queues a cancellation but it doesn't get immediately executed, the epochId should not change
            if(Helpers.canMutate(lastUpdateBefore, pendingBefore, depositEpochId)) {
                // nowDepositEpoch = depositEpochId + 1
                eq(lastUpdateAfter, depositEpochId + 1, "lastUpdate != nowDepositEpoch");
                eq(pendingAfter, 0, "pending is not zero");
            }
        } catch (bytes memory reason) {
            (uint32 depositEpochId,,,) = shareClassManager.epochId(ShareClassId.wrap(_getShareClassId()), AssetId.wrap(assetId));
            uint128 previousDepositApproved;
            if(depositEpochId > 0) {
                // we also check the previous epoch because approvals can increment the epochId
                (, previousDepositApproved,,,,) = shareClassManager.epochInvestAmounts(ShareClassId.wrap(_getShareClassId()), AssetId.wrap(assetId), depositEpochId - 1);
            }

            (, uint128 currentDepositApproved,,,,) = shareClassManager.epochInvestAmounts(ShareClassId.wrap(_getShareClassId()), AssetId.wrap(assetId), depositEpochId);
            // we only care about arithmetic reverts in the case of 0 approvals because if there have been any approvals, it's expected that user won't be able to cancel their request 
            if(previousDepositApproved == 0 && currentDepositApproved == 0) {
                bool arithmeticRevert = checkError(reason, Panic.arithmeticPanic);
                t(!arithmeticRevert, "cancelDepositRequest reverts with arithmetic panic");
            }
        }
    }

    /// @dev Property: After successfully calling cancelRedeemRequest for an investor, their redeemRequest[..].lastUpdate equals the current nowRedeemEpoch
    /// @dev Property: After successfully calling cancelRedeemRequest for an investor, their redeemRequest[..].pending is zero
    /// @dev Property: cancelRedeemRequest absolute value should never be higher than pendingRedeem (would result in underflow revert)
    function vault_cancelRedeemRequest() public updateGhosts asActor {
        address controller = _getActor();
        (uint128 pendingBefore, uint32 lastUpdateBefore) = shareClassManager.redeemRequest(ShareClassId.wrap(_getShareClassId()), AssetId.wrap(assetId), controller.toBytes32());
        
        try vault.cancelRedeemRequest(REQUEST_ID, controller) {
            (uint128 pendingAfter, uint32 lastUpdateAfter) = shareClassManager.redeemRequest(ShareClassId.wrap(_getShareClassId()), AssetId.wrap(assetId), controller.toBytes32());
            (, uint32 redeemEpochId,, )= shareClassManager.epochId(ShareClassId.wrap(_getShareClassId()), AssetId.wrap(assetId));

            // update ghosts
            cancelledRedemptions[controller] += (pendingBefore - pendingAfter);

            // precondition: if user queues a cancellation but it doesn't get immediately executed, the epochId should not change
            if(Helpers.canMutate(lastUpdateBefore, pendingBefore, redeemEpochId)) {
                // nowRedeemEpoch = redeemEpochId + 1
                eq(lastUpdateAfter, redeemEpochId + 1, "lastUpdate != nowRedeemEpoch");
                eq(pendingAfter, 0, "pending != 0");
            }
        } catch (bytes memory reason) {
            (, uint32 redeemEpochId,, )= shareClassManager.epochId(ShareClassId.wrap(_getShareClassId()), AssetId.wrap(assetId));
            (, uint128 currentRedeemApproved,,,,) = shareClassManager.epochInvestAmounts(ShareClassId.wrap(_getShareClassId()), AssetId.wrap(assetId), redeemEpochId);
            uint128 previousRedeemApproved;
            if(redeemEpochId > 0) {
                // we also check the previous epoch because approvals can increment the epochId
                (, previousRedeemApproved,,,,) = shareClassManager.epochInvestAmounts(ShareClassId.wrap(_getShareClassId()), AssetId.wrap(assetId), redeemEpochId - 1);
            }

            // we only care about arithmetic reverts in the case of 0 approvals because if there have been any approvals, it's expected that user won't be able to cancel their request 
            if(previousRedeemApproved == 0 && currentRedeemApproved == 0) {
                bool arithmeticRevert = checkError(reason, Panic.arithmeticPanic);
                t(!arithmeticRevert, "cancelRedeemRequest reverts with arithmetic panic");
            }
        }
    }

    function vault_claimCancelDepositRequest(uint256 toEntropy) public updateGhosts asActor {
        address to = _getRandomActor(toEntropy);

        uint256 assets = vault.claimCancelDepositRequest(REQUEST_ID, to, _getActor());
        sumOfClaimedDepositCancelations[address(_getAsset())] += assets;
    }

    function vault_claimCancelRedeemRequest(uint256 toEntropy) public updateGhosts asActor {
        address to = _getRandomActor(toEntropy);

        uint256 shares = vault.claimCancelRedeemRequest(REQUEST_ID, to, _getActor());
        sumOfClaimedRedeemCancelations[address(token)] += shares;
    }

    function vault_deposit(uint256 assets) public updateGhosts {
        // check if vault is sync or async
        bool isAsyncVault = Helpers.isAsyncVault(address(vault));

        uint256 shareUserB4 = token.balanceOf(_getActor());
        uint256 shareEscrowB4 = token.balanceOf(address(globalEscrow));

        // NOTE: external calls above so need to prank directly here
        vm.prank(_getActor());
        uint256 shares = vault.deposit(assets, _getActor());

        // Processed Deposit | E-2 | Global-1
        sumOfClaimedDeposits[address(token)] += shares;
        // for sync vaults, deposits are fulfilled immediately
        if(!Helpers.isAsyncVault(address(vault))) {
            sumOfFullfilledDeposits[address(token)] += shares;
            executedInvestments[address(token)] += shares;
        }

        // Bal after
        uint256 shareUserAfter = token.balanceOf(_getActor());
        uint256 shareEscrowAfter = token.balanceOf(address(globalEscrow));

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

            // NOTE: async vaults transfer shares from global escrow
            if(isAsyncVault) {
                eq(deltaUser, deltaEscrow, "7540-13");
            }

            // NOTE: sync vaults mint shares directly to the user
        }
    }

    // Given a random value, see if the other one would yield more shares or lower cost
    // Not only check view
    // Also do it and test it via revert test
    // TODO: Mint Deposit Arb Test
    // TODO: Withdraw Redeem Arb Test

    // TODO: See how these go
    // TODO: Receiver -> Not this
    function vault_mint(uint256 shares) public updateGhosts {
        address to = _getActor();

        // check if vault is sync or async
        bool isAsyncVault = Helpers.isAsyncVault(address(vault));

        // Bal b4
        uint256 shareUserB4 = token.balanceOf(_getActor());
        uint256 shareEscrowB4 = token.balanceOf(address(globalEscrow));

        // NOTE: external calls above so need to prank directly here
        vm.prank(_getActor());
        vault.mint(shares, to);

        // Processed Deposit | E-2
        sumOfClaimedDeposits[address(token)] += shares;
        // for sync vaults, deposits are fulfilled immediately
        if(!Helpers.isAsyncVault(address(vault))) {
            sumOfFullfilledDeposits[address(token)] += shares;
            executedInvestments[address(token)] += shares;
        }

        // Bal after
        uint256 shareUserAfter = token.balanceOf(_getActor());
        uint256 shareEscrowAfter = token.balanceOf(address(globalEscrow));

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

            // NOTE: async vaults transfer shares from global escrow
            if(isAsyncVault) {
                eq(deltaUser, deltaEscrow, "7540-13");
            }

            // NOTE: sync vaults mint shares directly to the user
        }
    }

    function vault_redeem(uint256 shares, uint256 toEntropy) public updateGhosts {
        address to = _getRandomActor(toEntropy);

        address escrow = address(poolEscrowFactory.deployedEscrow(PoolId.wrap(_getPool())));

        // Bal b4
        uint256 tokenUserB4 = MockERC20(_getAsset()).balanceOf(_getActor());
        uint256 tokenEscrowB4 = MockERC20(_getAsset()).balanceOf(escrow);

        // NOTE: external calls above so need to prank directly here
        vm.prank(_getActor());
        uint256 assets = vault.redeem(shares, to, _getActor());

        // E-1
        sumOfClaimedRedemptions[address(_getAsset())] += assets;
        
        // if sync vault, redeem is fulfilled immediately
        if(!Helpers.isAsyncVault(address(vault))) {
            executedRedemptions[address(token)] += assets;
        }

        // Bal after
        uint256 tokenUserAfter = MockERC20(_getAsset()).balanceOf(_getActor());
        uint256 tokenEscrowAfter = MockERC20(_getAsset()).balanceOf(escrow);

        // Extra check | // TODO: This math will prob overflow
        // NOTE: Unchecked so we get broken property and debug faster
        unchecked {
            uint256 deltaUser = tokenUserAfter - tokenUserB4;

            // TODO: NOTE FOT extra, verifies the transfer amount matches the returned amount
            eq(deltaUser, assets, "FoT-1");

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

    function vault_withdraw(uint256 assets, uint256 toEntropy) public updateGhosts {
        address to = _getRandomActor(toEntropy);

        address escrow = address(poolEscrowFactory.deployedEscrow(PoolId.wrap(_getPool())));
        // Bal b4
        uint256 tokenUserB4 = MockERC20(_getAsset()).balanceOf(_getActor());
        uint256 tokenEscrowB4 = MockERC20(_getAsset()).balanceOf(escrow);

        // NOTE: external calls above so need to prank directly here
        vm.prank(_getActor());
        vault.withdraw(assets, to, _getActor());

        // E-1
        sumOfClaimedRedemptions[address(_getAsset())] += assets;

        // Bal after
        uint256 tokenUserAfter = MockERC20(_getAsset()).balanceOf(_getActor());
        uint256 tokenEscrowAfter = MockERC20(_getAsset()).balanceOf(escrow);

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
