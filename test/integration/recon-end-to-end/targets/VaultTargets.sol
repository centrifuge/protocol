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
import {PoolId} from "src/core/types/PoolId.sol";
import {ShareClassId} from "src/core/types/ShareClassId.sol";
import {AssetId} from "src/core/types/AssetId.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";
import {IAsyncVault} from "src/vaults/interfaces/IAsyncVault.sol";
import {IShareToken} from "src/core/spoke/interfaces/IShareToken.sol";

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
    function vault_requestDeposit(uint256 assets, uint256 toEntropy)
        public
        updateGhostsWithType(OpType.REQUEST_DEPOSIT)
    {
        IBaseVault vault = _getVault();
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();

        _captureShareQueueState(poolId, scId);

        assets = between(assets, 0, _getTokenAndBalanceForVault());
        address to = _getRandomActor(toEntropy);

        vm.prank(_getActor());
        MockERC20(vault.asset()).approve(address(vault), assets);

        AssetId assetId = vaultRegistry.vaultDetails(vault).assetId;

        (uint128 prevDeposits, uint128 prevWithdrawals) = balanceSheet.queuedAssets(poolId, scId, assetId);

        // NOTE: external calls above so need to prank directly here
        vm.prank(_getActor());
        try IAsyncVault(address(vault)).requestDeposit(assets, to, _getActor()) {
            _handleRequestDepositSuccess(vault, poolId, scId, assetId, to, assets, prevDeposits, prevWithdrawals);
        } catch (bytes memory reason) {
            _handleRequestDepositFailure(poolId, scId, assetId, assets, reason);
        }
    }

    function _handleRequestDepositSuccess(
        IBaseVault vault,
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address to,
        uint256 assets,
        uint128 prevDeposits,
        uint128 prevWithdrawals
    ) private {
        // If the request was successful and the queue was previously empty,
        // we can assume it became non-empty (even if not immediately visible)
        if (prevDeposits == 0 && prevWithdrawals == 0 && assets > 0) {
            bytes32 assetKey = keccak256(abi.encode(poolId, scId, assetId));
            ghost_assetCounterPerAsset[assetKey] = 1; // Asset queue becomes non-empty
        }

        // ghost tracking
        userRequestDeposited[scId][assetId][to] += assets;
        sumOfDepositRequests[vault.asset()] += assets;
        requestDepositAssets[to][vault.asset()] += assets;

        // If not member
        (bool isMemberTo,) = fullRestrictions.isMember(vault.share(), to);
        if (!isMemberTo) {
            t(false, "LP-1 Must Revert");
        }

        // If to address is frozen
        if (fullRestrictions.isFrozen(vault.share(), to)) {
            t(false, "LP-2 Must Revert");
        }
    }

    function _handleRequestDepositFailure(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint256 assets,
        bytes memory reason
    ) private {
        // precondition: check that it wasn't an overflow because we only care about underflow
        uint128 pendingDeposit = batchRequestManager.pendingDeposit(poolId, scId, assetId);
        if (uint256(pendingDeposit) + uint256(assets) < uint256(type(uint128).max)) {
            bool arithmeticRevert = checkError(reason, Panic.arithmeticPanic);
            t(!arithmeticRevert, "depositRequest reverts with arithmetic panic");
        }

        // revert like it normally would if no properties break for proper shrinking
        // this make testing global properties not require a check for the call succeeding
        require(false);
    }

    function vault_requestDeposit_clamped(uint256 assets, uint256 toEntropy) public {
        assets = between(assets, 0, MockERC20(_getVault().asset()).balanceOf(_getActor()));

        vault_requestDeposit(assets, toEntropy);
    }

    /// @dev Property: sender or recipient can't be frozen for requested redemption
    function vault_requestRedeem(uint256 shares, uint256 toEntropy)
        public
        updateGhostsWithType(OpType.REQUEST_REDEEM)
    {
        address to = _getRandomActor(toEntropy); // TODO: donation / changes
        IBaseVault vault = _getVault();
        _captureShareQueueState(vault.poolId(), vault.scId());

        vm.prank(_getActor());
        IShareToken(vault.share()).approve(address(_getVault()), shares);

        // NOTE: external calls above so need to prank directly here
        vm.prank(_getActor());
        try IAsyncVault(address(_getVault())).requestRedeem(shares, to, _getActor()) {
            // ghost tracking
            sumOfRedeemRequests[vault.share()] += shares; // E-2
            requestRedeemShares[to][vault.share()] += shares;
            userRequestRedeemed[vault.scId()][vaultRegistry.vaultDetails(vault).assetId][to] += shares;

            userRequestRedeemedAssets[vault.scId()][vaultRegistry.vaultDetails(vault).assetId][to] +=
                vault.convertToAssets(shares);

            bytes32 shareKey = keccak256(abi.encode(vault.poolId(), vault.scId()));
            ghost_individualBalances[shareKey][_getActor()] -= shares;

            if (
                fullRestrictions.isFrozen(vault.share(), _getActor()) == true
                    || fullRestrictions.isFrozen(vault.share(), to) == true
            ) {
                t(false, "LP-2 Must Revert");
            }
        } catch {
            // used to still allow reverts for failing calls to be pruned in shrinking
            require(false);
        }
    }

    function vault_requestRedeem_clamped(uint256 shares, uint256 toEntropy) public {
        shares = between(shares, 0, IShareToken(_getVault().share()).balanceOf(_getActor()));
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
        IBaseVault vault = _getVault();
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = vaultRegistry.vaultDetails(vault).assetId;
        bytes32 controllerBytes = controller.toBytes32();

        _captureShareQueueState(poolId, scId);

        uint128 pendingBefore;
        uint32 lastUpdateBefore;
        uint32 depositEpochId;
        {
            (pendingBefore, lastUpdateBefore) =
                batchRequestManager.depositRequest(poolId, scId, assetId, controllerBytes);
            (depositEpochId,,,) = batchRequestManager.epochId(poolId, scId, assetId);
        }

        uint256 pendingCancelBefore = IAsyncVault(address(vault)).claimableCancelDepositRequest(REQUEST_ID, controller);

        vm.prank(controller);
        // REQUEST_ID is always passed as 0 (unused in the function)
        try IAsyncVault(address(vault)).cancelDepositRequest(REQUEST_ID, controller) {
            _handleCancelDepositSuccess(
                vault,
                poolId,
                scId,
                assetId,
                controller,
                controllerBytes,
                pendingBefore,
                lastUpdateBefore,
                depositEpochId,
                pendingCancelBefore
            );
        } catch (bytes memory reason) {
            _handleCancelDepositFailure(poolId, scId, assetId, depositEpochId, reason);
        }
    }

    function _handleCancelDepositSuccess(
        IBaseVault vault,
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address controller,
        bytes32 controllerBytes,
        uint128 pendingBefore,
        uint32 lastUpdateBefore,
        uint32 depositEpochId,
        uint256 pendingCancelBefore
    ) private {
        (uint128 pendingAfter, uint32 lastUpdateAfter) =
            batchRequestManager.depositRequest(poolId, scId, assetId, controllerBytes);
        uint256 pendingCancelAfter = IAsyncVault(address(vault)).claimableCancelDepositRequest(REQUEST_ID, controller);

        // update ghosts
        userCancelledDeposits[scId][assetId][controller] += (pendingCancelAfter - pendingCancelBefore);

        // precondition: if user queues a cancellation but it doesn't get immediately executed,
        // the epochId should not change
        if (Helpers.canMutate(lastUpdateBefore, pendingBefore, depositEpochId)) {
            // nowDepositEpoch = depositEpochId + 1
            eq(lastUpdateAfter, depositEpochId + 1, "lastUpdate != nowDepositEpoch3");
            eq(pendingAfter, 0, "pending is not zero");
        }
    }

    function _handleCancelDepositFailure(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint32 depositEpochId,
        bytes memory reason
    ) private {
        (depositEpochId,,,) = batchRequestManager.epochId(poolId, scId, assetId);

        uint128 previousDepositApproved;
        if (depositEpochId > 0) {
            (, previousDepositApproved,,,,) =
                batchRequestManager.epochInvestAmounts(poolId, scId, assetId, depositEpochId - 1);
        }

        (, uint128 currentDepositApproved,,,,) =
            batchRequestManager.epochInvestAmounts(poolId, scId, assetId, depositEpochId);

        // we only care about arithmetic reverts in the case of 0 approvals because if there have been any
        // approvals, it's expected that user won't be able to cancel their request
        if (previousDepositApproved == 0 && currentDepositApproved == 0) {
            bool arithmeticRevert = checkError(reason, Panic.arithmeticPanic);
            t(!arithmeticRevert, "cancelDepositRequest reverts with arithmetic panic");
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
        IBaseVault vault = _getVault();
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = vaultRegistry.vaultDetails(vault).assetId;

        _captureShareQueueState(poolId, scId);

        (uint128 pendingBefore, uint32 lastUpdateBefore) =
            batchRequestManager.redeemRequest(poolId, scId, assetId, controller.toBytes32());
        uint256 pendingCancelBefore =
            IAsyncVault(address(_getVault())).claimableCancelRedeemRequest(REQUEST_ID, controller);

        vm.prank(controller);
        try IAsyncVault(address(_getVault())).cancelRedeemRequest(REQUEST_ID, controller) {
            (uint128 pendingAfter, uint32 lastUpdateAfter) =
                batchRequestManager.redeemRequest(poolId, scId, assetId, controller.toBytes32());
            (, uint32 redeemEpochId,,) = batchRequestManager.epochId(poolId, scId, assetId);
            uint256 pendingCancelAfter =
                IAsyncVault(address(_getVault())).claimableCancelRedeemRequest(REQUEST_ID, controller);

            // update ghosts
            // cancelled pending increases since it's a queued request
            uint256 delta = pendingCancelAfter - pendingCancelBefore;
            userCancelledRedeems[scId][assetId][controller] += delta;

            // precondition: if user queues a cancellation but it doesn't get immediately executed, the epochId should
            // not change
            if (Helpers.canMutate(lastUpdateBefore, pendingBefore, redeemEpochId)) {
                // nowRedeemEpoch = redeemEpochId + 1
                eq(lastUpdateAfter, redeemEpochId + 1, "lastUpdate != nowRedeemEpoch");
                eq(pendingAfter, 0, "pending != 0");
            }
        } catch (bytes memory reason) {
            (, uint32 redeemEpochId,,) = batchRequestManager.epochId(poolId, scId, assetId);
            (, uint128 currentRedeemApproved,,,,) =
                batchRequestManager.epochRedeemAmounts(poolId, scId, assetId, redeemEpochId);
            uint128 previousRedeemApproved;
            if (redeemEpochId > 0) {
                // we also check the previous epoch because approvals can increment the epochId
                (, previousRedeemApproved,,,,) =
                    batchRequestManager.epochRedeemAmounts(poolId, scId, assetId, redeemEpochId - 1);
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

        uint256 assets = IAsyncVault(address(_getVault())).claimCancelDepositRequest(REQUEST_ID, to, _getActor());
        sumOfClaimedCancelledDeposits[_getVault().asset()] += assets;
    }

    function vault_claimCancelRedeemRequest(uint256 toEntropy) public updateGhosts asActor {
        address to = _getRandomActor(toEntropy);
        IBaseVault vault = _getVault();

        // Capture balances before claiming
        uint256 shareBalanceBefore = IShareToken(vault.share()).balanceOf(to);

        uint256 shares = IAsyncVault(address(_getVault())).claimCancelRedeemRequest(REQUEST_ID, to, _getActor());

        // Capture balances after claiming
        uint256 shareBalanceAfter = IShareToken(vault.share()).balanceOf(to);

        console2.log("=== VAULT CLAIM CANCEL REDEEM REQUEST ===");
        console2.log("Actor:", _getActor());
        console2.log("To:", to);
        console2.log("Shares returned:", shares);
        console2.log("Share balance before:", shareBalanceBefore);
        console2.log("Share balance after:", shareBalanceAfter);
        console2.log("Balance change:", shareBalanceAfter - shareBalanceBefore);

        // Track the ghost variables
        bytes32 shareKey = keccak256(abi.encode(vault.poolId(), vault.scId()));

        sumOfClaimedCancelledRedeemShares[_getVault().share()] += shares;
        ghost_individualBalances[shareKey][to] += shares;
    }

    function vault_deposit(uint256 assets) public updateGhostsWithType(OpType.ADD) {
        // check if vault is sync or async
        bool isAsyncVault = Helpers.isAsyncVault(address(_getVault()));
        // Get vault
        IBaseVault vault = _getVault();
        _captureShareQueueState(vault.poolId(), vault.scId());

        uint256 shareUserB4 = IShareToken(vault.share()).balanceOf(_getActor());
        uint256 shareEscrowB4 = IShareToken(vault.share()).balanceOf(address(globalEscrow));
        (uint128 pendingBefore,) = batchRequestManager.depositRequest(
            vault.poolId(), vault.scId(), vaultRegistry.vaultDetails(vault).assetId, _getActor().toBytes32()
        );

        // NOTE: external calls above so need to prank directly here
        vm.prank(_getActor());
        uint256 shares = vault.deposit(assets, _getActor());

        // Add ghost flip tracking for share queue state changes
        {
            bytes32 shareKey = keccak256(abi.encode(vault.poolId(), vault.scId()));
            ghost_totalIssued[shareKey] += shares;
            ghost_netSharePosition[shareKey] += int256(uint256(shares));

            // Update ghost_individualBalances when shares are minted to user
            // For sync vaults, shares are minted immediately. For async vaults, they're minted later.
            if (!isAsyncVault) {
                ghost_individualBalances[shareKey][_getActor()] += shares;
                ghost_totalShareSupply[shareKey] += shares;
                ghost_supplyMintEvents[shareKey] += shares;
            }

            // Check for share queue flip
            (uint128 deltaAfter, bool isPositiveAfter,,) = balanceSheet.queuedShares(vault.poolId(), vault.scId());
            bytes32 key = _poolShareKey(vault.poolId(), vault.scId());
            uint128 deltaBefore = before_shareQueueDelta[key];
            bool isPositiveBefore = before_shareQueueIsPositive[key];

            if ((isPositiveBefore != isPositiveAfter) && (deltaBefore != 0 || deltaAfter != 0)) {
                ghost_flipCount[shareKey]++;
                console2.log("=== FLIP DETECTED IN VAULT_DEPOSIT ===");
            }
        }

        (uint128 pendingAfter,) = batchRequestManager.depositRequest(
            vault.poolId(), vault.scId(), vaultRegistry.vaultDetails(vault).assetId, _getActor().toBytes32()
        );

        // Processed Deposit | E-2 | Global-1
        // for sync vaults, deposits are fulfilled and claimed immediately
        if (!isAsyncVault) {
            if (pendingBefore >= pendingAfter) {
                sumOfClaimedDeposits[vault.share()] += (pendingBefore - pendingAfter);
            }

            // Track asset counter for Queue State Consistency properties
            if (assets > 0) {
                bytes32 assetKey =
                    keccak256(abi.encode(vault.poolId(), vault.scId(), vaultRegistry.vaultDetails(vault).assetId));

                // Check if asset queue became non-empty after deposit
                (uint128 currentDeposits, uint128 currentWithdrawals) =
                    balanceSheet.queuedAssets(vault.poolId(), vault.scId(), vaultRegistry.vaultDetails(vault).assetId);

                // For sync deposits, the asset queue becomes non-empty during processing
                if (currentDeposits > 0 || currentWithdrawals > 0) {
                    ghost_assetCounterPerAsset[assetKey] = 1; // Asset queue becomes non-empty
                }
            }

            executedInvestments[vault.share()] += shares;

            sumOfSyncDepositsAsset[vault.asset()] += assets;
            sumOfSyncDepositsShare[vault.share()] += shares;
            userDepositProcessed[vault.scId()][vaultRegistry.vaultDetails(vault).assetId][_getActor()] += assets;
            userRequestDeposited[vault.scId()][vaultRegistry.vaultDetails(vault).assetId][_getActor()] += assets;
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
        IBaseVault vault = _getVault();
        _captureShareQueueState(vault.poolId(), vault.scId());

        // check if vault is sync or async
        bool isAsyncVault = Helpers.isAsyncVault(address(vault));

        // Bal b4
        uint256 shareUserB4 = IShareToken(vault.share()).balanceOf(to);
        uint256 shareEscrowB4 = IShareToken(vault.share()).balanceOf(address(globalEscrow));
        (uint128 pendingBefore,) = batchRequestManager.depositRequest(
            vault.poolId(), vault.scId(), vaultRegistry.vaultDetails(vault).assetId, to.toBytes32()
        );

        // NOTE: external calls above so need to prank directly here
        vm.prank(to);
        uint256 assets = vault.mint(shares, to);

        // Add ghost flip tracking for share queue state changes
        {
            bytes32 shareKey = keccak256(abi.encode(vault.poolId(), vault.scId()));
            ghost_totalIssued[shareKey] += shares;
            ghost_netSharePosition[shareKey] += int256(uint256(shares));

            // Update ghost_individualBalances when shares are minted to user
            ghost_individualBalances[shareKey][to] += shares;
            ghost_totalShareSupply[shareKey] += shares;
            ghost_supplyMintEvents[shareKey] += shares;

            // Check for share queue flip
            (uint128 deltaAfter, bool isPositiveAfter,,) = balanceSheet.queuedShares(vault.poolId(), vault.scId());
            bytes32 key = _poolShareKey(vault.poolId(), vault.scId());
            uint128 deltaBefore = before_shareQueueDelta[key];
            bool isPositiveBefore = before_shareQueueIsPositive[key];

            if ((isPositiveBefore != isPositiveAfter) && (deltaBefore != 0 || deltaAfter != 0)) {
                ghost_flipCount[shareKey]++;
            }
        }

        (uint128 pendingAfter,) = batchRequestManager.depositRequest(
            vault.poolId(), vault.scId(), vaultRegistry.vaultDetails(vault).assetId, to.toBytes32()
        );

        // Processed Deposit | E-2
        // for sync vaults, deposits are fulfilled immediately
        // NOTE: async vaults don't request deposits but we need to track this value for the escrow balance property
        if (!isAsyncVault) {
            // Track asset counter for Queue State Consistency properties
            if (assets > 0) {
                bytes32 assetKey =
                    keccak256(abi.encode(vault.poolId(), vault.scId(), vaultRegistry.vaultDetails(vault).assetId));

                // Check if asset queue became non-empty after deposit
                (uint128 currentDeposits, uint128 currentWithdrawals) =
                    balanceSheet.queuedAssets(vault.poolId(), vault.scId(), vaultRegistry.vaultDetails(vault).assetId);

                // For sync deposits, the asset queue becomes non-empty during processing
                if (currentDeposits > 0 || currentWithdrawals > 0) {
                    ghost_assetCounterPerAsset[assetKey] = 1; // Asset queue becomes non-empty
                }
            }

            userRequestDeposited[vault.scId()][vaultRegistry.vaultDetails(vault).assetId][_getActor()] += assets;
            userDepositProcessed[vault.scId()][vaultRegistry.vaultDetails(vault).assetId][_getActor()] += assets;
            sumOfSyncDepositsAsset[vault.asset()] += assets;

            sumOfSyncDepositsShare[vault.share()] += shares;
            if (pendingBefore >= pendingAfter) {
                sumOfClaimedDeposits[vault.share()] += (pendingBefore - pendingAfter);
            }
            executedInvestments[vault.share()] += shares;
        }
    }

    function vault_redeem(uint256 shares, uint256 toEntropy) public updateGhostsWithType(OpType.REMOVE) {
        IBaseVault vault = _getVault();
        _captureShareQueueState(vault.poolId(), vault.scId());

        address to = _getRandomActor(toEntropy);
        address escrow = address(poolEscrowFactory.escrow(vault.poolId()));

        // Bal b4
        uint256 tokenUserB4 = MockERC20(_getVault().asset()).balanceOf(_getActor());
        uint256 tokenEscrowB4 = MockERC20(_getVault().asset()).balanceOf(escrow);

        // NOTE: external calls above so need to prank directly here
        vm.prank(_getActor());
        uint256 assets = _getVault().redeem(shares, to, _getActor());

        // NOTE: vault.redeem() does NOT call balanceSheet.revoke() - it only transfers assets from escrow
        // Share revocation happens separately via AsyncRequestManager.revokedShares() when hub processes requests
        // Therefore, no ghost tracking needed here

        // Bal after
        uint256 tokenUserAfter = MockERC20(_getVault().asset()).balanceOf(_getActor());
        uint256 tokenEscrowAfter = MockERC20(_getVault().asset()).balanceOf(escrow);

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

    function vault_withdraw(uint256 assets, uint256 toEntropy) public updateGhostsWithType(OpType.REMOVE) {
        IBaseVault vault = _getVault();
        _captureShareQueueState(vault.poolId(), vault.scId());

        // address to = _getRandomActor(toEntropy); // Unused
        address escrow = address(poolEscrowFactory.escrow(vault.poolId()));

        // Bal b4
        uint256 tokenEscrowB4 = MockERC20(_getVault().asset()).balanceOf(escrow);

        // NOTE: external calls above so need to prank directly here
        vm.prank(_getActor());

        uint256 tokenEscrowAfter = MockERC20(_getVault().asset()).balanceOf(escrow);

        // E-1
        sumOfClaimedRedemptions[_getVault().asset()] += (tokenEscrowB4 - tokenEscrowAfter);
    }

    /// Helpers

    /// @dev Get the balance of the current assetErc20 and _getActor()
    function _getTokenAndBalanceForVault() internal view returns (uint256) {
        // Token
        uint256 amt = MockERC20(_getAsset()).balanceOf(_getActor());

        return amt;
    }
}
