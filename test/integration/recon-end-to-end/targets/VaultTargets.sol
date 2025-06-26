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
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";
import {IAsyncVault} from "src/vaults/interfaces/IAsyncVault.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";

// Test Utils
import {OpType} from "test/integration/recon-end-to-end/BeforeAfter.sol";
import {Helpers} from "test/hub/fuzzing/recon-hub/utils/Helpers.sol";
import {Properties} from "../properties/Properties.sol";

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
    /// @dev Property: after successfully calling requestDeposit for an investor, their depositRequest[..].lastUpdate
    /// equals the current nowDepositEpoch
    /// @dev Property: _updateDepositRequest should never revert due to underflow
    function vault_requestDeposit(uint256 assets, uint256 toEntropy) public updateGhosts {
        assets = between(assets, 0, _getTokenAndBalanceForVault());
        address to = _getRandomActor(toEntropy);

        vm.prank(_getActor());
        MockERC20(IBaseVault(_getVault()).asset()).approve(_getVault(), assets);

        // B4 Balances
        uint256 balanceB4 = MockERC20(IBaseVault(_getVault()).asset()).balanceOf(_getActor());
        uint256 balanceOfEscrowB4 = MockERC20(IBaseVault(_getVault()).asset()).balanceOf(address(globalEscrow));

        bool hasReverted;

        // NOTE: external calls above so need to prank directly here
        vm.prank(_getActor());
        try IAsyncVault(_getVault()).requestDeposit(assets, to, _getActor()) {
            // ghost tracking
            requestDeposited[IBaseVault(_getVault()).scId()][hubRegistry.currency(IBaseVault(_getVault()).poolId())][to]
            += assets;
            sumOfDepositRequests[IBaseVault(_getVault()).asset()] += assets;
            requestDepositAssets[to][IBaseVault(_getVault()).asset()] += assets;

            (uint128 pending, uint32 lastUpdate) = shareClassManager.depositRequest(
                IBaseVault(_getVault()).scId(), hubRegistry.currency(IBaseVault(_getVault()).poolId()), to.toBytes32()
            );
            (uint32 depositEpochId,,,) = shareClassManager.epochId(
                IBaseVault(_getVault()).scId(), hubRegistry.currency(IBaseVault(_getVault()).poolId())
            );

            // precondition: if user queues a cancellation but it doesn't get immediately executed, the epochId should
            // not change
            if (Helpers.canMutate(lastUpdate, pending, depositEpochId)) {
                // nowDepositEpoch = depositEpochId + 1
                eq(lastUpdate, depositEpochId + 1, "lastUpdate != nowDepositEpoch2");
            }
        } catch (bytes memory reason) {
            hasReverted = true;

            // precondition: check that it wasn't an overflow because we only care about underflow
            uint128 pendingDeposit = shareClassManager.pendingDeposit(
                IBaseVault(_getVault()).scId(), hubRegistry.currency(IBaseVault(_getVault()).poolId())
            );
            if (uint256(pendingDeposit) + uint256(assets) < uint256(type(uint128).max)) {
                bool arithmeticRevert = checkError(reason, Panic.arithmeticPanic);
                t(!arithmeticRevert, "depositRequest reverts with arithmetic panic");
            }
        }

        // If not member
        (bool isMemberTo,) = fullRestrictions.isMember(IBaseVault(_getVault()).share(), to);
        if (!isMemberTo) {
            t(hasReverted, "LP-1 Must Revert");
        }

        bool isToFrozen = fullRestrictions.isFrozen(IBaseVault(_getVault()).share(), to);
        if (isToFrozen) {
            t(hasReverted, "LP-2 Must Revert");
        }

        // After Balances and Checks
        uint256 balanceAfter = MockERC20(IBaseVault(_getVault()).asset()).balanceOf(_getActor());
        uint256 balanceOfEscrowAfter = MockERC20(IBaseVault(_getVault()).asset()).balanceOf(address(globalEscrow));

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
        assets = between(assets, 0, MockERC20(IBaseVault(_getVault()).asset()).balanceOf(_getActor()));
        address to = _getRandomActor(toEntropy);

        vault_requestDeposit(assets, toEntropy);
    }

    /// @dev Property: After successfully calling requestRedeem for an investor, their redeemRequest[..].lastUpdate
    /// equals nowRedeemEpoch
    function vault_requestRedeem(uint256 shares, uint256 toEntropy) public updateGhosts {
        address to = _getRandomActor(toEntropy); // TODO: donation / changes
        IBaseVault vault = IBaseVault(_getVault());

        // B4 Balances
        uint256 balanceB4 = IShareToken(vault.share()).balanceOf(_getActor());
        uint256 balanceOfEscrowB4 = IShareToken(vault.share()).balanceOf(address(globalEscrow));

        vm.prank(_getActor());
        IShareToken(vault.share()).approve(_getVault(), shares);

        bool hasReverted;
        // NOTE: external calls above so need to prank directly here
        vm.prank(_getActor());
        try IAsyncVault(_getVault()).requestRedeem(shares, to, _getActor()) {
            // ghost tracking
            sumOfRedeemRequests[vault.share()] += shares; // E-2
            requestRedeemShares[to][vault.share()] += shares;
            requestRedeemed[vault.scId()][hubRegistry.currency(vault.poolId())][to] += shares;

            requestRedeemedAssets[vault.scId()][hubRegistry.currency(vault.poolId())][to] +=
                vault.convertToAssets(shares);

            (uint128 pending, uint32 lastUpdate) =
                shareClassManager.redeemRequest(vault.scId(), hubRegistry.currency(vault.poolId()), to.toBytes32());
            (, uint32 redeemEpochId,,) = shareClassManager.epochId(
                IBaseVault(_getVault()).scId(), hubRegistry.currency(IBaseVault(_getVault()).poolId())
            );

            // precondition: if user queues a cancellation but it doesn't get immediately executed, the epochId should
            // not change
            if (Helpers.canMutate(lastUpdate, pending, redeemEpochId)) {
                // nowRedeemEpoch = redeemEpochId + 1
                eq(lastUpdate, redeemEpochId + 1, "lastUpdate != nowRedeemEpoch after redeemRequest");
            }
        } catch {
            hasReverted = true;
        }

        if (
            fullRestrictions.isFrozen(vault.share(), _getActor()) == true
                || fullRestrictions.isFrozen(vault.share(), to) == true
        ) {
            t(hasReverted, "LP-2 Must Revert");
        }

        // After Balances and Checks
        uint256 balanceAfter = IShareToken(vault.share()).balanceOf(_getActor());
        uint256 balanceOfEscrowAfter = IShareToken(vault.share()).balanceOf(address(globalEscrow));

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
        shares = between(shares, 0, IShareToken(IBaseVault(_getVault()).share()).balanceOf(_getActor()));
        vault_requestRedeem(shares, toEntropy);
    }

    // === CANCEL === //

    /// @dev Property: after successfully calling cancelDepositRequest for an investor, their
    /// depositRequest[..].lastUpdate equals the current nowDepositEpoch
    /// @dev Property: after successfully calling cancelDepositRequest for an investor, their depositRequest[..].pending
    /// is zero
    /// @dev Property: cancelDepositRequest absolute value should never be higher than pendingDeposit (would result in
    /// underflow revert)
    function vault_cancelDepositRequest() public updateGhostsWithType(OpType.NOTIFY) {
        address controller = _getActor();
        IBaseVault vault = IBaseVault(_getVault());

        (uint128 pendingBefore, uint32 lastUpdateBefore) =
            shareClassManager.depositRequest(vault.scId(), hubRegistry.currency(vault.poolId()), controller.toBytes32());
        (uint32 depositEpochId,,,) = shareClassManager.epochId(
            IBaseVault(_getVault()).scId(), hubRegistry.currency(IBaseVault(_getVault()).poolId())
        );
        uint256 pendingCancelBefore = IAsyncVault(_getVault()).claimableCancelDepositRequest(REQUEST_ID, controller);

        vm.prank(_getActor());
        // REQUEST_ID is always passed as 0 (unused in the function)
        try IAsyncVault(_getVault()).cancelDepositRequest(REQUEST_ID, controller) {
            (uint128 pendingAfter, uint32 lastUpdateAfter) = shareClassManager.depositRequest(
                vault.scId(), hubRegistry.currency(vault.poolId()), controller.toBytes32()
            );
            uint256 pendingCancelAfter = IAsyncVault(_getVault()).claimableCancelDepositRequest(REQUEST_ID, controller);

            // update ghosts
            cancelledDeposits[vault.scId()][hubRegistry.currency(vault.poolId())][controller] +=
                (pendingCancelAfter - pendingCancelBefore); // cancelled pending decreases since it's a queued request

            // precondition: if user queues a cancellation but it doesn't get immediately executed, the epochId should
            // not change
            if (Helpers.canMutate(lastUpdateBefore, pendingBefore, depositEpochId)) {
                // nowDepositEpoch = depositEpochId + 1
                eq(lastUpdateAfter, depositEpochId + 1, "lastUpdate != nowDepositEpoch3");
                eq(pendingAfter, 0, "pending is not zero");
            }
        } catch (bytes memory reason) {
            (depositEpochId,,,) = shareClassManager.epochId(vault.scId(), hubRegistry.currency(vault.poolId()));
            uint128 previousDepositApproved;
            if (depositEpochId > 0) {
                // we also check the previous epoch because approvals can increment the epochId
                (, previousDepositApproved,,,,) = shareClassManager.epochInvestAmounts(
                    vault.scId(), hubRegistry.currency(vault.poolId()), depositEpochId - 1
                );
            }

            (, uint128 currentDepositApproved,,,,) =
                shareClassManager.epochInvestAmounts(vault.scId(), hubRegistry.currency(vault.poolId()), depositEpochId);
            // we only care about arithmetic reverts in the case of 0 approvals because if there have been any
            // approvals, it's expected that user won't be able to cancel their request
            if (previousDepositApproved == 0 && currentDepositApproved == 0) {
                bool arithmeticRevert = checkError(reason, Panic.arithmeticPanic);
                t(!arithmeticRevert, "cancelDepositRequest reverts with arithmetic panic");
            }
        }
    }

    /// @dev Property: After successfully calling cancelRedeemRequest for an investor, their
    /// redeemRequest[..].lastUpdate equals the current nowRedeemEpoch
    /// @dev Property: After successfully calling cancelRedeemRequest for an investor, their redeemRequest[..].pending
    /// is zero
    /// @dev Property: cancelRedeemRequest absolute value should never be higher than pendingRedeem (would result in
    /// underflow revert)
    function vault_cancelRedeemRequest() public updateGhostsWithType(OpType.NOTIFY) {
        address controller = _getActor();
        IBaseVault vault = IBaseVault(_getVault());

        (uint128 pendingBefore, uint32 lastUpdateBefore) =
            shareClassManager.redeemRequest(vault.scId(), hubRegistry.currency(vault.poolId()), controller.toBytes32());
        uint256 pendingCancelBefore = IAsyncVault(_getVault()).claimableCancelRedeemRequest(REQUEST_ID, controller);

        vm.prank(controller);
        try IAsyncVault(_getVault()).cancelRedeemRequest(REQUEST_ID, controller) {
            (uint128 pendingAfter, uint32 lastUpdateAfter) = shareClassManager.redeemRequest(
                vault.scId(), hubRegistry.currency(vault.poolId()), controller.toBytes32()
            );
            (, uint32 redeemEpochId,,) = shareClassManager.epochId(
                IBaseVault(_getVault()).scId(), hubRegistry.currency(IBaseVault(_getVault()).poolId())
            );
            uint256 pendingCancelAfter = IAsyncVault(_getVault()).claimableCancelRedeemRequest(REQUEST_ID, controller);

            // update ghosts
            // cancelled pending increases since it's a queued request
            uint256 delta = pendingCancelAfter - pendingCancelBefore;
            cancelledRedemptions[vault.scId()][hubRegistry.currency(vault.poolId())][controller] += delta;
            cancelRedeemShareTokenPayout[vault.share()] += delta;

            // precondition: if user queues a cancellation but it doesn't get immediately executed, the epochId should
            // not change
            if (Helpers.canMutate(lastUpdateBefore, pendingBefore, redeemEpochId)) {
                // nowRedeemEpoch = redeemEpochId + 1
                eq(lastUpdateAfter, redeemEpochId + 1, "lastUpdate != nowRedeemEpoch");
                eq(pendingAfter, 0, "pending != 0");
            }
        } catch (bytes memory reason) {
            (, uint32 redeemEpochId,,) = shareClassManager.epochId(vault.scId(), hubRegistry.currency(vault.poolId()));
            (, uint128 currentRedeemApproved,,,,) =
                shareClassManager.epochInvestAmounts(vault.scId(), hubRegistry.currency(vault.poolId()), redeemEpochId);
            uint128 previousRedeemApproved;
            if (redeemEpochId > 0) {
                // we also check the previous epoch because approvals can increment the epochId
                (, previousRedeemApproved,,,,) = shareClassManager.epochInvestAmounts(
                    vault.scId(), hubRegistry.currency(vault.poolId()), redeemEpochId - 1
                );
            }

            // we only care about arithmetic reverts in the case of 0 approvals because if there have been any
            // approvals, it's expected that user won't be able to cancel their request
            if (previousRedeemApproved == 0 && currentRedeemApproved == 0) {
                bool arithmeticRevert = checkError(reason, Panic.arithmeticPanic);
                t(!arithmeticRevert, "cancelRedeemRequest reverts with arithmetic panic");
            }
        }
    }

    function vault_claimCancelDepositRequest(uint256 toEntropy) public updateGhosts asActor {
        address to = _getRandomActor(toEntropy);

        uint256 assets = IAsyncVault(_getVault()).claimCancelDepositRequest(REQUEST_ID, to, _getActor());
        sumOfClaimedDepositCancelations[IBaseVault(_getVault()).asset()] += assets;
        cancelDepositCurrencyPayout[IBaseVault(_getVault()).asset()] += assets;
    }

    function vault_claimCancelRedeemRequest(uint256 toEntropy) public updateGhosts asActor {
        address to = _getRandomActor(toEntropy);

        uint256 shares = IAsyncVault(_getVault()).claimCancelRedeemRequest(REQUEST_ID, to, _getActor());

        sumOfClaimedRedeemCancelations[IBaseVault(_getVault()).share()] += shares;
    }

    function vault_deposit(uint256 assets) public updateGhostsWithType(OpType.ADD) {
        // check if vault is sync or async
        bool isAsyncVault = Helpers.isAsyncVault(_getVault());
        // Get vault
        IBaseVault vault = IBaseVault(_getVault());

        uint256 shareUserB4 = IShareToken(vault.share()).balanceOf(_getActor());
        uint256 shareEscrowB4 = IShareToken(vault.share()).balanceOf(address(globalEscrow));
        (uint128 pendingBefore,) = shareClassManager.depositRequest(
            vault.scId(), hubRegistry.currency(vault.poolId()), _getActor().toBytes32()
        );

        // NOTE: external calls above so need to prank directly here
        vm.prank(_getActor());
        uint256 shares = vault.deposit(assets, _getActor());

        (uint128 pendingAfter,) = shareClassManager.depositRequest(
            vault.scId(), hubRegistry.currency(vault.poolId()), _getActor().toBytes32()
        );

        // Processed Deposit | E-2 | Global-1
        // for sync vaults, deposits are fulfilled and claimed immediately
        if (!isAsyncVault) {
            sumOfFullfilledDeposits[vault.share()] += (pendingBefore - pendingAfter);
            sumOfClaimedDeposits[vault.share()] += (pendingBefore - pendingAfter);
            executedInvestments[vault.share()] += shares;

            sumOfSyncDepositsAsset[vault.asset()] += assets;
            sumOfSyncDepositsShare[vault.share()] += shares;
            depositProcessed[vault.scId()][hubRegistry.currency(vault.poolId())][_getActor()] += assets;
            requestDeposited[vault.scId()][hubRegistry.currency(vault.poolId())][_getActor()] += assets;
        }

        // Bal after
        uint256 shareUserAfter = IShareToken(vault.share()).balanceOf(_getActor());
        uint256 shareEscrowAfter = IShareToken(vault.share()).balanceOf(address(globalEscrow));

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
            if (isAsyncVault) {
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
    function vault_mint(uint256 shares) public updateGhostsWithType(OpType.ADD) {
        address to = _getActor();
        // Get vault
        IBaseVault vault = IBaseVault(_getVault());

        // check if vault is sync or async
        bool isAsyncVault = Helpers.isAsyncVault(_getVault());

        // Bal b4
        uint256 shareUserB4 = IShareToken(vault.share()).balanceOf(to);
        uint256 shareEscrowB4 = IShareToken(vault.share()).balanceOf(address(globalEscrow));
        (uint128 pendingBefore,) =
            shareClassManager.depositRequest(vault.scId(), hubRegistry.currency(vault.poolId()), to.toBytes32());

        // NOTE: external calls above so need to prank directly here
        vm.prank(_getActor());
        uint256 assets = IBaseVault(_getVault()).mint(shares, to);

        (uint128 pendingAfter,) =
            shareClassManager.depositRequest(vault.scId(), hubRegistry.currency(vault.poolId()), to.toBytes32());

        // Bal after
        uint256 shareUserAfter = IShareToken(vault.share()).balanceOf(to);
        uint256 shareEscrowAfter = IShareToken(vault.share()).balanceOf(address(globalEscrow));

        // Processed Deposit | E-2
        // for sync vaults, deposits are fulfilled immediately
        // NOTE: async vaults don't request deposits but we need to track this value for the escrow balance property
        if (!isAsyncVault) {
            requestDeposited[vault.scId()][hubRegistry.currency(vault.poolId())][_getActor()] += assets;
            depositProcessed[vault.scId()][hubRegistry.currency(vault.poolId())][_getActor()] += assets;
            sumOfSyncDepositsAsset[vault.asset()] += assets;

            sumOfSyncDepositsShare[vault.share()] += shares;
            sumOfFullfilledDeposits[vault.share()] += (pendingBefore - pendingAfter);
            sumOfClaimedDeposits[vault.share()] += (pendingBefore - pendingAfter);
            executedInvestments[vault.share()] += shares;
        }

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
            if (isAsyncVault) {
                eq(deltaUser, deltaEscrow, "7540-13");
            }

            // NOTE: sync vaults mint shares directly to the user
        }
    }

    function vault_redeem(uint256 shares, uint256 toEntropy) public updateGhostsWithType(OpType.REMOVE) {
        address to = _getRandomActor(toEntropy);
        address escrow = address(poolEscrowFactory.escrow(IBaseVault(_getVault()).poolId()));

        // Bal b4
        uint256 tokenUserB4 = MockERC20(IBaseVault(_getVault()).asset()).balanceOf(_getActor());
        uint256 tokenEscrowB4 = MockERC20(IBaseVault(_getVault()).asset()).balanceOf(escrow);

        // NOTE: external calls above so need to prank directly here
        vm.prank(_getActor());
        uint256 assets = IBaseVault(_getVault()).redeem(shares, to, _getActor());

        // Bal after
        uint256 tokenUserAfter = MockERC20(IBaseVault(_getVault()).asset()).balanceOf(_getActor());
        uint256 tokenEscrowAfter = MockERC20(IBaseVault(_getVault()).asset()).balanceOf(escrow);

        // E-1
        sumOfClaimedRedemptions[IBaseVault(_getVault()).asset()] += assets;

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

    function vault_withdraw(uint256 assets, uint256 toEntropy) public updateGhostsWithType(OpType.REMOVE) {
        address to = _getRandomActor(toEntropy);
        address escrow = address(poolEscrowFactory.escrow(IBaseVault(_getVault()).poolId()));

        // Bal b4
        uint256 tokenUserB4 = MockERC20(IBaseVault(_getVault()).asset()).balanceOf(_getActor());
        uint256 tokenEscrowB4 = MockERC20(IBaseVault(_getVault()).asset()).balanceOf(escrow);

        // NOTE: external calls above so need to prank directly here
        vm.prank(_getActor());

        // Bal after
        uint256 tokenUserAfter = MockERC20(IBaseVault(_getVault()).asset()).balanceOf(_getActor());
        uint256 tokenEscrowAfter = MockERC20(IBaseVault(_getVault()).asset()).balanceOf(escrow);

        // E-1
        sumOfClaimedRedemptions[IBaseVault(_getVault()).asset()] += (tokenEscrowB4 - tokenEscrowAfter);

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
