// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {vm} from "@chimera/Hevm.sol";

import {console2} from "forge-std/console2.sol";

// Helpers
import {Panic} from "@recon/Panic.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";
import {D18, d18} from "src/misc/types/D18.sol";

import {BalanceSheet} from "src/spoke/BalanceSheet.sol";
import {BeforeAfter} from "test/integration/recon-end-to-end/BeforeAfter.sol";
import {Properties} from "test/integration/recon-end-to-end/properties/Properties.sol";

abstract contract BalanceSheetTargets is BaseTargetFunctions, Properties {
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///

    function balanceSheet_deny() public updateGhosts asActor {
        // Track authorization - deny() requires auth (ward only)
        _trackAuthorization(_getActor(), PoolId.wrap(0)); // Global operation, use PoolId 0
        _checkAndRecordAuthChange(_getActor()); // Track auth changes from deny()
        
        balanceSheet.deny(_getActor());
    }

    function balanceSheet_deposit(uint256 tokenId, uint128 amount) public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = spoke.vaultDetails(vault).assetId; 
        
        // Track authorization - deposit() requires authOrManager(poolId)
        _trackAuthorization(_getActor(), poolId);
        
        // Track for property iteration
        _trackPoolAndShareClass(poolId, scId);
        _trackAsset(assetId);
        
        // Update queue ghost variables
        bytes32 assetKey = keccak256(abi.encode(poolId, scId, assetId));
        
        // Track asset counter for Queue State Consistency properties
        (uint128 prevDeposits, uint128 prevWithdrawals) = balanceSheet.queuedAssets(poolId, scId, assetId);
        if (prevDeposits == 0 && prevWithdrawals == 0) {
            ghost_assetCounterPerAsset[assetKey] = 1; // Asset queue becomes non-empty
        }
        
        // Track escrow balance sufficiency
        ghost_escrowSufficiencyTracked[assetKey] = true;
        uint128 prevAvailable = balanceSheet.availableBalanceOf(poolId, scId, vault.asset(), tokenId);
        
        // Track asset-share proportionality for deposits
        // Track deposit amounts and exchange rate before deposit
        ghost_cumulativeAssetsDeposited[assetKey] += amount;
        ghost_depositProportionalityTracked[assetKey] = true;
        
        // Get current exchange rate (price per asset in pool terms)
        try spoke.pricePoolPerAsset(poolId, scId, assetId, true) returns (D18 pricePerAsset) {
            // Store weighted average exchange rate
            uint256 totalOps = 1; // Simplified tracking
            if (totalOps == 1) {
                ghost_depositExchangeRate[assetKey] = D18.unwrap(pricePerAsset);
            } else {
                // Update running average: new_avg = (old_avg * (n-1) + new_value) / n
                uint256 oldAvg = ghost_depositExchangeRate[assetKey];
                ghost_depositExchangeRate[assetKey] = (oldAvg * (totalOps - 1) + D18.unwrap(pricePerAsset)) / totalOps;
            }
        } catch {
            // If price fetch fails, use 1:1 ratio as fallback
            ghost_depositExchangeRate[assetKey] = D18.unwrap(d18(1 ether));
        }
        
        balanceSheet.deposit(poolId, scId, vault.asset(), tokenId, amount);

        sumOfManagerDeposits[vault.asset()] += amount;
        
        ghost_assetQueueDeposits[assetKey] += amount;
        
        // Update escrow tracking: total balance increases by deposit amount
        uint128 newAvailable = balanceSheet.availableBalanceOf(poolId, scId, vault.asset(), tokenId);
        ghost_escrowAvailableBalance[assetKey] = newAvailable;
        ghost_escrowReservedBalance[assetKey] = ghost_netReserved[assetKey];
    }


    function balanceSheet_issue(uint128 shares) public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();

        // Track authorization - issue() requires authOrManager(poolId)
        _trackAuthorization(_getActor(), poolId);

        // Track for property iteration
        _trackPoolAndShareClass(poolId, scId);

        // Track previous net position for flip detection
        bytes32 shareKey = keccak256(abi.encode(poolId, scId));
        bytes32 userKey = keccak256(abi.encode(shareKey, _getActor()));
        int256 prevNetPosition = ghost_netSharePosition[shareKey];
        
        // Track supply operations
        ghost_supplyOperationOccurred[shareKey] = true;
        ghost_totalShareSupply[shareKey] += shares;
        ghost_individualBalances[shareKey][_getActor()] += shares;
        ghost_supplyMintEvents[shareKey] += shares;
        
        // Track asset-share proportionality for share issuance
        // Track shares issued for deposits - need to iterate through tracked assets for this pool/shareClass
        AssetId[] memory assets = trackedAssets;
        for (uint256 i = 0; i < assets.length; i++) {
            bytes32 assetKey = keccak256(abi.encode(poolId, scId, assets[i]));
            // If this asset has proportionality tracking enabled, update cumulative shares
            if (ghost_depositProportionalityTracked[assetKey]) {
                ghost_cumulativeSharesIssuedForDeposits[assetKey] += shares;
            }
        }
        
        balanceSheet.issue(poolId, scId, _getActor(), shares);

        issuedBalanceSheetShares[poolId][scId] += shares;
        shareMints[vault.share()] += shares;
        
        // Update ghost variables
        ghost_totalIssued[shareKey] += shares;
        ghost_netSharePosition[shareKey] += int256(uint256(shares));
        
        // Check for position flip
        if (prevNetPosition < 0 && ghost_netSharePosition[shareKey] >= 0) {
            ghost_flipCount[shareKey]++;
        }
    }

    function balanceSheet_noteDeposit(uint256 tokenId, uint128 amount) public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = spoke.vaultDetails(vault).assetId;  // Fixed: Use proper asset ID resolution
        
        // Track authorization - noteDeposit() requires authOrManager(poolId)
        _trackAuthorization(_getActor(), poolId);
        
        balanceSheet.noteDeposit(poolId, scId, vault.asset(), tokenId, amount);
        
        // Update queue ghost variables
        bytes32 assetKey = keccak256(abi.encode(poolId, scId, assetId));
        ghost_assetQueueDeposits[assetKey] += amount;
    }

    function balanceSheet_overridePricePoolPerAsset(D18 value) public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        AssetId assetId = spoke.vaultDetails(vault).assetId;  // Fixed: Use proper asset ID resolution
        
        // Track authorization - overridePricePoolPerAsset() requires authOrManager(poolId)
        _trackAuthorization(_getActor(), vault.poolId());
        
        balanceSheet.overridePricePoolPerAsset(vault.poolId(), vault.scId(), assetId, value);
    }

    function balanceSheet_overridePricePoolPerShare(D18 value) public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        
        // Track authorization - overridePricePoolPerShare() requires authOrManager(poolId)
        _trackAuthorization(_getActor(), vault.poolId());
        
        balanceSheet.overridePricePoolPerShare(vault.poolId(), vault.scId(), value);
    }

    function balanceSheet_recoverTokens(address token, uint256 amount) public updateGhosts asActor {
        balanceSheet.recoverTokens(token, _getActor(), amount);
    }

    function balanceSheet_recoverTokens(address token, uint256 tokenId, uint256 amount) public updateGhosts asActor {
        balanceSheet.recoverTokens(token, tokenId, _getActor(), amount);
    }

    function balanceSheet_rely() public updateGhosts asActor {
        // Track authorization - rely() requires auth (ward only)
        _trackAuthorization(_getActor(), PoolId.wrap(0)); // Global operation, use PoolId 0
        _checkAndRecordAuthChange(_getActor()); // Track auth changes from rely()
        
        balanceSheet.rely(_getActor());
    }

    function balanceSheet_resetPricePoolPerAsset() public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        AssetId assetId = spoke.vaultDetails(vault).assetId;  // Fixed: Use proper asset ID resolution
        
        // Track authorization - resetPricePoolPerAsset() requires authOrManager(poolId)
        _trackAuthorization(_getActor(), vault.poolId());
        
        balanceSheet.resetPricePoolPerAsset(vault.poolId(), vault.scId(), assetId);
    }

    function balanceSheet_resetPricePoolPerShare() public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        
        // Track authorization - resetPricePoolPerShare() requires authOrManager(poolId)
        _trackAuthorization(_getActor(), vault.poolId());
        
        balanceSheet.resetPricePoolPerShare(vault.poolId(), vault.scId());
    }

    function balanceSheet_revoke(uint128 shares) public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();

        // Track authorization - revoke() requires authOrManager(poolId)
        _trackAuthorization(_getActor(), poolId);

        // Track for property iteration
        _trackPoolAndShareClass(poolId, scId);

        // Track previous net position for flip detection
        bytes32 shareKey = keccak256(abi.encode(poolId, scId));
        int256 prevNetPosition = ghost_netSharePosition[shareKey];
        
        // Track supply operations
        ghost_supplyOperationOccurred[shareKey] = true;
        ghost_totalShareSupply[shareKey] -= shares;
        ghost_individualBalances[shareKey][_getActor()] -= shares;
        ghost_supplyBurnEvents[shareKey] += shares;
        
        // Track share revocation for withdrawals
        // Track shares revoked for all assets in this pool/shareClass
        AssetId[] memory assets = trackedAssets;
        for (uint256 i = 0; i < assets.length; i++) {
            bytes32 assetKey = keccak256(abi.encode(poolId, scId, assets[i]));
            // If withdrawal proportionality tracking is enabled for this asset, update cumulative shares
            if (ghost_withdrawalProportionalityTracked[assetKey]) {
                ghost_cumulativeSharesRevokedForWithdrawals[assetKey] += shares;
            }
        }
        
        balanceSheet.revoke(poolId, scId, shares);

        revokedBalanceSheetShares[poolId][scId] += shares;
        shareMints[vault.share()] -= shares;
        
        // Update ghost variables
        ghost_totalRevoked[shareKey] += shares;
        ghost_netSharePosition[shareKey] -= int256(uint256(shares));
        
        // Check for position flip
        if (prevNetPosition > 0 && ghost_netSharePosition[shareKey] <= 0) {
            ghost_flipCount[shareKey]++;
        }
    }

    function balanceSheet_transferSharesFrom(address to, uint256 amount) public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        
        // Track authorization - transferSharesFrom() requires authOrManager(poolId)
        _trackAuthorization(_getActor(), poolId);
        
        // Track endorsement status before transfer
        address from = _getActor();
        address recipient = _getRandomActor(uint256(uint160(to)));
        _trackEndorsedTransfer(from, recipient, poolId, scId);
        
        bytes32 key = keccak256(abi.encode(poolId, scId));
        
        // Attempt the transfer - will revert if from is endorsed
        try balanceSheet.transferSharesFrom(poolId, scId, from, from, recipient, amount) {
            // Transfer succeeded - track as valid
            ghost_validTransferCount[key]++;
            
            // Track balance changes for transfers (supply stays same, only balances shift)
            ghost_individualBalances[key][from] -= amount;
            ghost_individualBalances[key][recipient] += amount;
            ghost_supplyOperationOccurred[key] = true;
        } catch {
            // Transfer failed - likely due to endorsement restriction
            if (_isEndorsedContract(from)) {
                ghost_blockedEndorsedTransfers[key]++;
            }
        }
    }

    function balanceSheet_withdraw(uint256 tokenId, uint128 amount) public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = spoke.vaultDetails(vault).assetId;  // Fixed: Use proper asset ID resolution
        
        // Track authorization - withdraw() requires authOrManager(poolId)
        _trackAuthorization(_getActor(), poolId);
        
        // Update queue ghost variables
        bytes32 assetKey = keccak256(abi.encode(poolId, scId, assetId));
        
        // Track asset counter for Queue State Consistency properties
        (uint128 prevDeposits, uint128 prevWithdrawals) = balanceSheet.queuedAssets(poolId, scId, assetId);
        if (prevDeposits == 0 && prevWithdrawals == 0) {
            ghost_assetCounterPerAsset[assetKey] = 1; // Asset queue becomes non-empty
        }
        
        // Track escrow balance sufficiency
        ghost_escrowSufficiencyTracked[assetKey] = true;
        uint128 prevAvailable = balanceSheet.availableBalanceOf(poolId, scId, vault.asset(), tokenId);
        
        // Check if withdrawal would exceed available balance (track failures)
        if (amount > prevAvailable) {
            ghost_failedWithdrawalAttempts[assetKey]++;
        }
        
        try balanceSheet.withdraw(poolId, scId, vault.asset(), tokenId, _getActor(), amount) {
            // Successful withdrawal
            uint128 newAvailable = balanceSheet.availableBalanceOf(poolId, scId, vault.asset(), tokenId);
            ghost_escrowAvailableBalance[assetKey] = newAvailable;
            ghost_escrowReservedBalance[assetKey] = ghost_netReserved[assetKey];
            
            // Track withdrawal proportionality
            ghost_withdrawalProportionalityTracked[assetKey] = true;
            ghost_cumulativeAssetsWithdrawn[assetKey] += amount;
        } catch {
            // Failed withdrawal tracked above
        }

        sumOfManagerWithdrawals[vault.asset()] += amount;
        
        ghost_assetQueueWithdrawals[assetKey] += amount;
    }

    // === NEW TARGET FUNCTIONS FOR QUEUE OPERATIONS ===
    
    function balanceSheet_reserve(uint256 tokenId, uint128 amount) public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = spoke.vaultDetails(vault).assetId; // Proper asset ID resolution
        
        // Track authorization - reserve() requires authOrManager(poolId)
        _trackAuthorization(_getActor(), poolId);
        
        bytes32 key = keccak256(abi.encode(poolId, scId, assetId));
        
        // Track reserve operations
        ghost_totalReserveOperations[key]++;
        
        // Check for overflow before updating
        if (ghost_netReserved[key] > type(uint256).max - amount) {
            ghost_reserveOverflow[key] = true;
            ghost_reserveIntegrityViolations[key]++;
        } else {
            ghost_netReserved[key] += amount;
            
            // Update max reserved if needed
        }
        
        balanceSheet.reserve(poolId, scId, vault.asset(), tokenId, amount);
        
        // Track escrow balance sufficiency
        ghost_escrowSufficiencyTracked[key] = true;
        uint128 newAvailable = balanceSheet.availableBalanceOf(poolId, scId, vault.asset(), tokenId);
        ghost_escrowAvailableBalance[key] = newAvailable;
        ghost_escrowReservedBalance[key] = ghost_netReserved[key];
    }
    
    function balanceSheet_unreserve(uint256 tokenId, uint128 amount) public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = spoke.vaultDetails(vault).assetId; // Proper asset ID resolution
        
        // Track authorization - unreserve() requires authOrManager(poolId)
        _trackAuthorization(_getActor(), poolId);
        
        bytes32 key = keccak256(abi.encode(poolId, scId, assetId));
        
        // Track unreserve operations
        ghost_totalUnreserveOperations[key]++;
        
        // Check for underflow before updating
        if (ghost_netReserved[key] < amount) {
            ghost_reserveUnderflow[key] = true;
            ghost_reserveIntegrityViolations[key]++;
        } else {
            ghost_netReserved[key] -= amount;
        }
        
        balanceSheet.unreserve(poolId, scId, vault.asset(), tokenId, amount);
        
        // Track escrow balance sufficiency
        ghost_escrowSufficiencyTracked[key] = true;
        uint128 newAvailable = balanceSheet.availableBalanceOf(poolId, scId, vault.asset(), tokenId);
        ghost_escrowAvailableBalance[key] = newAvailable;
        ghost_escrowReservedBalance[key] = ghost_netReserved[key];
    }
    
    function balanceSheet_submitQueuedAssets(uint128 extraGasLimit) public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = spoke.vaultDetails(vault).assetId;  // Fixed: Use proper asset ID resolution
        
        // Track authorization - submitQueuedAssets() requires authOrManager(poolId)
        _trackAuthorization(_getActor(), poolId);
        
        // Track nonce monotonicity for Queue State Consistency properties
        bytes32 assetKey = keccak256(abi.encode(poolId, scId, assetId));
        bytes32 shareKey = keccak256(abi.encode(poolId, scId));
        
        // Get current nonce to track monotonicity
        (,, uint32 queuedAssetCounter, uint64 currentNonce) = balanceSheet.queuedShares(poolId, scId);
        ghost_previousNonce[shareKey] = currentNonce; // Store previous nonce
        
        
        balanceSheet.submitQueuedAssets(poolId, scId, assetId, extraGasLimit);
        
        // Mark asset queue as empty after submission
        ghost_assetCounterPerAsset[assetKey] = 0;
    }
    
    function balanceSheet_submitQueuedShares(uint128 extraGasLimit) public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        
        // Track authorization - submitQueuedShares() requires authOrManager(poolId)
        _trackAuthorization(_getActor(), poolId);
        
        // Track nonce monotonicity for Queue State Consistency properties
        bytes32 shareKey = keccak256(abi.encode(poolId, scId));
        
        // Get current nonce to track monotonicity
        (,, uint32 queuedAssetCounter, uint64 currentNonce) = balanceSheet.queuedShares(poolId, scId);
        ghost_previousNonce[shareKey] = currentNonce; // Store previous nonce
        
        ghost_shareQueueNonce[shareKey]++;
        
        balanceSheet.submitQueuedShares(poolId, scId, extraGasLimit);
    }
}
