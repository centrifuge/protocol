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
import {Helpers} from "test/integration/recon-end-to-end/utils/Helpers.sol";
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

    // === REQUEST === //
    /// @dev Property: _updateDepositRequest should never revert due to underflow
    function vault_requestDeposit(
        uint256 assets,
        uint256 toEntropy
    ) public updateGhostsWithType(OpType.REQUEST_DEPOSIT) {
        assets = between(assets, 0, _getTokenAndBalanceForVault());
        address to = _getRandomActor(toEntropy);

        vm.prank(_getActor());
        MockERC20(_getVault().asset()).approve(address(_getVault()), assets);

        // NOTE: external calls above so need to prank directly here
        vm.prank(_getActor());
        try
            IAsyncVault(address(_getVault())).requestDeposit(
                assets,
                to,
                _getActor()
            )
        {
            // ghost tracking
            userRequestDeposited[_getVault().scId()][
                spoke.vaultDetails(_getVault()).assetId
            ][to] += assets;
            sumOfDepositRequests[_getVault().asset()] += assets;
            requestDepositAssets[to][_getVault().asset()] += assets;
        } catch (bytes memory reason) {
            // precondition: check that it wasn't an overflow because we only care about underflow
            uint128 pendingDeposit = shareClassManager.pendingDeposit(
                _getVault().scId(),
                spoke.vaultDetails(_getVault()).assetId
            );
            if (
                uint256(pendingDeposit) + uint256(assets) <
                uint256(type(uint128).max)
            ) {
                bool arithmeticRevert = checkError(
                    reason,
                    Panic.arithmeticPanic
                );
                t(
                    !arithmeticRevert,
                    "depositRequest reverts with arithmetic panic"
                );
            }

            // If not member
            (bool isMemberTo, ) = fullRestrictions.isMember(
                _getVault().share(),
                to
            );
            if (!isMemberTo) {
                t(false, "LP-1 Must Revert");
            }

            // If to address is frozen
            if (fullRestrictions.isFrozen(_getVault().share(), to)) {
                t(false, "LP-2 Must Revert");
            }
        }
    }

    function vault_requestDeposit_clamped(
        uint256 assets,
        uint256 toEntropy
    ) public {
        assets = between(
            assets,
            0,
            MockERC20(_getVault().asset()).balanceOf(_getActor())
        );

        vault_requestDeposit(assets, toEntropy);
    }

    /// @dev Property: sender or recipient can't be frozen for requested redemption
    function vault_requestRedeem(
        uint256 shares,
        uint256 toEntropy
    ) public updateGhostsWithType(OpType.REQUEST_REDEEM) {
        address to = _getRandomActor(toEntropy); // TODO: donation / changes
        IBaseVault vault = _getVault();

        vm.prank(_getActor());
        IShareToken(vault.share()).approve(address(_getVault()), shares);

        // NOTE: external calls above so need to prank directly here
        vm.prank(_getActor());
        try
            IAsyncVault(address(_getVault())).requestRedeem(
                shares,
                to,
                _getActor()
            )
        {
            // ghost tracking
            sumOfRedeemRequests[vault.share()] += shares; // E-2
            requestRedeemShares[to][vault.share()] += shares;
            userRequestRedeemed[vault.scId()][
                spoke.vaultDetails(vault).assetId
            ][to] += shares;

            userRequestRedeemedAssets[vault.scId()][
                spoke.vaultDetails(vault).assetId
            ][to] += vault.convertToAssets(shares);
        } catch {
            if (
                fullRestrictions.isFrozen(vault.share(), _getActor()) == true ||
                fullRestrictions.isFrozen(vault.share(), to) == true
            ) {
                t(false, "LP-2 Must Revert");
            }
        }
    }

    function vault_requestRedeem_clamped(
        uint256 shares,
        uint256 toEntropy
    ) public {
        shares = between(
            shares,
            0,
            IShareToken(_getVault().share()).balanceOf(_getActor())
        );
        vault_requestRedeem(shares, toEntropy);
    }

    // === CANCEL === //

    /// @dev Property: after successfully calling cancelDepositRequest for an investor, their
    /// depositRequest[..].lastUpdate equals the current nowDepositEpoch
    /// @dev Property: after successfully calling cancelDepositRequest for an investor, their depositRequest[..].pending
    /// is zero
    /// @dev Property: cancelDepositRequest absolute value should never be higher than pendingDeposit (would result in
    /// underflow revert)
    function vault_cancelDepositRequest()
        public
        updateGhostsWithType(OpType.NOTIFY)
    {
        address controller = _getActor();
        IBaseVault vault = _getVault();

        (uint128 pendingBefore, uint32 lastUpdateBefore) = shareClassManager
            .depositRequest(
                vault.scId(),
                spoke.vaultDetails(vault).assetId,
                controller.toBytes32()
            );
        (uint32 depositEpochId, , , ) = shareClassManager.epochId(
            _getVault().scId(),
            spoke.vaultDetails(_getVault()).assetId
        );
        uint256 pendingCancelBefore = IAsyncVault(address(_getVault()))
            .claimableCancelDepositRequest(REQUEST_ID, controller);

        vm.prank(_getActor());
        // REQUEST_ID is always passed as 0 (unused in the function)
        try
            IAsyncVault(address(_getVault())).cancelDepositRequest(
                REQUEST_ID,
                controller
            )
        {
            (uint128 pendingAfter, uint32 lastUpdateAfter) = shareClassManager
                .depositRequest(
                    vault.scId(),
                    spoke.vaultDetails(vault).assetId,
                    controller.toBytes32()
                );
            uint256 pendingCancelAfter = IAsyncVault(address(_getVault()))
                .claimableCancelDepositRequest(REQUEST_ID, controller);

            // update ghosts
            userCancelledDeposits[vault.scId()][
                spoke.vaultDetails(vault).assetId
            ][controller] += (pendingCancelAfter - pendingCancelBefore); // cancelled pending decreases since it's a queued request

            // precondition: if user queues a cancellation but it doesn't get immediately executed, the epochId should
            // not change
            if (
                Helpers.canMutate(
                    lastUpdateBefore,
                    pendingBefore,
                    depositEpochId
                )
            ) {
                // nowDepositEpoch = depositEpochId + 1
                eq(
                    lastUpdateAfter,
                    depositEpochId + 1,
                    "lastUpdate != nowDepositEpoch3"
                );
                eq(pendingAfter, 0, "pending is not zero");
            }
        } catch (bytes memory reason) {
            // Checks that should be made if there's a revert
            (depositEpochId, , , ) = shareClassManager.epochId(
                vault.scId(),
                spoke.vaultDetails(vault).assetId
            );
            uint128 previousDepositApproved;
            if (depositEpochId > 0) {
                // we also check the previous epoch because approvals can increment the epochId
                (, previousDepositApproved, , , , ) = shareClassManager
                    .epochInvestAmounts(
                        vault.scId(),
                        spoke.vaultDetails(vault).assetId,
                        depositEpochId - 1
                    );
            }

            (, uint128 currentDepositApproved, , , , ) = shareClassManager
                .epochInvestAmounts(
                    vault.scId(),
                    spoke.vaultDetails(vault).assetId,
                    depositEpochId
                );
            // we only care about arithmetic reverts in the case of 0 approvals because if there have been any
            // approvals, it's expected that user won't be able to cancel their request
            if (previousDepositApproved == 0 && currentDepositApproved == 0) {
                bool arithmeticRevert = checkError(
                    reason,
                    Panic.arithmeticPanic
                );
                t(
                    !arithmeticRevert,
                    "cancelDepositRequest reverts with arithmetic panic"
                );
            }
        }
    }

    /// @dev Property: After successfully calling cancelRedeemRequest for an investor, their
    /// redeemRequest[..].lastUpdate equals the current nowRedeemEpoch
    /// @dev Property: After successfully calling cancelRedeemRequest for an investor, their redeemRequest[..].pending
    /// is zero
    /// @dev Property: cancelRedeemRequest absolute value should never be higher than pendingRedeem (would result in
    /// underflow revert)
    function vault_cancelRedeemRequest()
        public
        updateGhostsWithType(OpType.NOTIFY)
    {
        address controller = _getActor();
        IBaseVault vault = _getVault();

        (uint128 pendingBefore, uint32 lastUpdateBefore) = shareClassManager
            .redeemRequest(
                vault.scId(),
                spoke.vaultDetails(vault).assetId,
                controller.toBytes32()
            );
        uint256 pendingCancelBefore = IAsyncVault(address(_getVault()))
            .claimableCancelRedeemRequest(REQUEST_ID, controller);

        vm.prank(controller);
        try
            IAsyncVault(address(_getVault())).cancelRedeemRequest(
                REQUEST_ID,
                controller
            )
        {
            (uint128 pendingAfter, uint32 lastUpdateAfter) = shareClassManager
                .redeemRequest(
                    vault.scId(),
                    spoke.vaultDetails(vault).assetId,
                    controller.toBytes32()
                );
            (, uint32 redeemEpochId, , ) = shareClassManager.epochId(
                _getVault().scId(),
                spoke.vaultDetails(_getVault()).assetId
            );
            uint256 pendingCancelAfter = IAsyncVault(address(_getVault()))
                .claimableCancelRedeemRequest(REQUEST_ID, controller);

            // update ghosts
            // cancelled pending increases since it's a queued request
            uint256 delta = pendingCancelAfter - pendingCancelBefore;
            userCancelledRedeems[vault.scId()][
                spoke.vaultDetails(vault).assetId
            ][controller] += delta;

            // precondition: if user queues a cancellation but it doesn't get immediately executed, the epochId should
            // not change
            if (
                Helpers.canMutate(
                    lastUpdateBefore,
                    pendingBefore,
                    redeemEpochId
                )
            ) {
                // nowRedeemEpoch = redeemEpochId + 1
                eq(
                    lastUpdateAfter,
                    redeemEpochId + 1,
                    "lastUpdate != nowRedeemEpoch"
                );
                eq(pendingAfter, 0, "pending != 0");
            }
        } catch (bytes memory reason) {
            // Checks that should be made if there's a revert
            (, uint32 redeemEpochId, , ) = shareClassManager.epochId(
                vault.scId(),
                spoke.vaultDetails(vault).assetId
            );
            (, uint128 currentRedeemApproved, , , , ) = shareClassManager
                .epochInvestAmounts(
                    vault.scId(),
                    spoke.vaultDetails(vault).assetId,
                    redeemEpochId
                );
            uint128 previousRedeemApproved;
            if (redeemEpochId > 0) {
                // we also check the previous epoch because approvals can increment the epochId
                (, previousRedeemApproved, , , , ) = shareClassManager
                    .epochInvestAmounts(
                        vault.scId(),
                        spoke.vaultDetails(vault).assetId,
                        redeemEpochId - 1
                    );
            }

            // we only care about arithmetic reverts in the case of 0 approvals because if there have been any
            // approvals, it's expected that user won't be able to cancel their request
            if (previousRedeemApproved == 0 && currentRedeemApproved == 0) {
                bool arithmeticRevert = checkError(
                    reason,
                    Panic.arithmeticPanic
                );
                t(
                    !arithmeticRevert,
                    "cancelRedeemRequest reverts with arithmetic panic"
                );
            }
        }
    }

    function vault_claimCancelDepositRequest(
        uint256 toEntropy
    ) public updateGhosts asActor {
        address to = _getRandomActor(toEntropy);

        uint256 assets = IAsyncVault(address(_getVault()))
            .claimCancelDepositRequest(REQUEST_ID, to, _getActor());
        sumOfClaimedCancelledDeposits[_getVault().asset()] += assets;
    }

    function vault_claimCancelRedeemRequest(
        uint256 toEntropy
    ) public updateGhosts asActor {
        address to = _getRandomActor(toEntropy);

        uint256 shares = IAsyncVault(address(_getVault()))
            .claimCancelRedeemRequest(REQUEST_ID, to, _getActor());

        sumOfClaimedCancelledRedeemShares[_getVault().share()] += shares;
    }

    function vault_deposit(
        uint256 assets
    ) public updateGhostsWithType(OpType.ADD) {
        // check if vault is sync or async
        bool isAsyncVault = Helpers.isAsyncVault(address(_getVault()));
        // Get vault
        IBaseVault vault = _getVault();

        uint256 shareUserB4 = IShareToken(vault.share()).balanceOf(_getActor());
        uint256 shareEscrowB4 = IShareToken(vault.share()).balanceOf(
            address(globalEscrow)
        );
        (uint128 pendingBefore, ) = shareClassManager.depositRequest(
            vault.scId(),
            spoke.vaultDetails(vault).assetId,
            _getActor().toBytes32()
        );

        // NOTE: external calls above so need to prank directly here
        vm.prank(_getActor());
        uint256 shares = vault.deposit(assets, _getActor());

        (uint128 pendingAfter, ) = shareClassManager.depositRequest(
            vault.scId(),
            spoke.vaultDetails(vault).assetId,
            _getActor().toBytes32()
        );

        // Processed Deposit | E-2 | Global-1
        // for sync vaults, deposits are fulfilled and claimed immediately
        if (!isAsyncVault) {
            if (pendingBefore >= pendingAfter) {
                sumOfFulfilledDeposits[vault.share()] += shares;
                sumOfClaimedDeposits[vault.share()] += (pendingBefore -
                    pendingAfter);
            }
            executedInvestments[vault.share()] += shares;

            sumOfSyncDepositsAsset[vault.asset()] += assets;
            sumOfSyncDepositsShare[vault.share()] += shares;
            userDepositProcessed[vault.scId()][
                spoke.vaultDetails(vault).assetId
            ][_getActor()] += assets;
            userRequestDeposited[vault.scId()][
                spoke.vaultDetails(vault).assetId
            ][_getActor()] += assets;
        }
    }
    // Given a random value, see if the other one would yield more shares or lower cost
    // Not only check view
    // Also do it and test it via revert test
    // TODO: Mint Deposit Arb Test
    // TODO: Withdraw Redeem Arb Test

    // TODO: See how these go
    // TODO: Receiver -> Not this
    function vault_mint(
        uint256 shares
    ) public updateGhostsWithType(OpType.ADD) {
        address to = _getActor();
        // Get vault
        IBaseVault vault = _getVault();

        // check if vault is sync or async
        bool isAsyncVault = Helpers.isAsyncVault(address(_getVault()));

        // Bal b4
        uint256 shareUserB4 = IShareToken(vault.share()).balanceOf(to);
        uint256 shareEscrowB4 = IShareToken(vault.share()).balanceOf(
            address(globalEscrow)
        );
        (uint128 pendingBefore, ) = shareClassManager.depositRequest(
            vault.scId(),
            spoke.vaultDetails(vault).assetId,
            to.toBytes32()
        );

        // NOTE: external calls above so need to prank directly here
        vm.prank(_getActor());
        uint256 assets = _getVault().mint(shares, to);

        (uint128 pendingAfter, ) = shareClassManager.depositRequest(
            vault.scId(),
            spoke.vaultDetails(vault).assetId,
            to.toBytes32()
        );

        // Bal after
        uint256 shareUserAfter = IShareToken(vault.share()).balanceOf(to);
        uint256 shareEscrowAfter = IShareToken(vault.share()).balanceOf(
            address(globalEscrow)
        );

        // Processed Deposit | E-2
        // for sync vaults, deposits are fulfilled immediately
        // NOTE: async vaults don't request deposits but we need to track this value for the escrow balance property
        if (!isAsyncVault) {
            userRequestDeposited[vault.scId()][
                spoke.vaultDetails(vault).assetId
            ][_getActor()] += assets;
            userDepositProcessed[vault.scId()][
                spoke.vaultDetails(vault).assetId
            ][_getActor()] += assets;
            sumOfSyncDepositsAsset[vault.asset()] += assets;

            sumOfSyncDepositsShare[vault.share()] += shares;
            if (pendingBefore >= pendingAfter) {
                sumOfFulfilledDeposits[vault.share()] += shares;
                sumOfClaimedDeposits[vault.share()] += (pendingBefore -
                    pendingAfter);
            }
            executedInvestments[vault.share()] += shares;
        }
    }

    function vault_redeem(
        uint256 shares,
        uint256 toEntropy
    ) public updateGhostsWithType(OpType.REMOVE) {
        address to = _getRandomActor(toEntropy);
        address escrow = address(
            poolEscrowFactory.escrow(_getVault().poolId())
        );

        // Bal b4
        uint256 tokenUserB4 = MockERC20(_getVault().asset()).balanceOf(
            _getActor()
        );
        uint256 tokenEscrowB4 = MockERC20(_getVault().asset()).balanceOf(
            escrow
        );

        // NOTE: external calls above so need to prank directly here
        vm.prank(_getActor());
        uint256 assets = _getVault().redeem(shares, to, _getActor());

        // Bal after
        uint256 tokenUserAfter = MockERC20(_getVault().asset()).balanceOf(
            _getActor()
        );
        uint256 tokenEscrowAfter = MockERC20(_getVault().asset()).balanceOf(
            escrow
        );

        // E-1
        sumOfClaimedRedemptions[_getVault().asset()] += assets;

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

    function vault_withdraw(
        uint256 assets,
        uint256 toEntropy
    ) public updateGhostsWithType(OpType.REMOVE) {
        // address to = _getRandomActor(toEntropy); // Unused
        address escrow = address(
            poolEscrowFactory.escrow(_getVault().poolId())
        );

        // Bal b4
        uint256 tokenEscrowB4 = MockERC20(_getVault().asset()).balanceOf(
            escrow
        );

        // NOTE: external calls above so need to prank directly here
        vm.prank(_getActor());

        uint256 tokenEscrowAfter = MockERC20(_getVault().asset()).balanceOf(
            escrow
        );

        // E-1
        sumOfClaimedRedemptions[_getVault().asset()] += (tokenEscrowB4 -
            tokenEscrowAfter);
    }

    /// Helpers

    /// @dev Get the balance of the current assetErc20 and _getActor()
    function _getTokenAndBalanceForVault() internal view returns (uint256) {
        // Token
        uint256 amt = MockERC20(_getAsset()).balanceOf(_getActor());

        return amt;
    }
}
