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
import {D18} from "src/misc/types/D18.sol";

import {BalanceSheet} from "src/spoke/BalanceSheet.sol";
import {BeforeAfter} from "test/integration/recon-end-to-end/BeforeAfter.sol";
import {Properties} from "test/integration/recon-end-to-end/properties/Properties.sol";

abstract contract BalanceSheetTargets is BaseTargetFunctions, Properties {
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///

    function balanceSheet_deny() public updateGhosts asActor {
        balanceSheet.deny(_getActor());
    }

    function balanceSheet_deposit(uint256 tokenId, uint128 amount) public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = spoke.vaultDetails(vault).assetId; 
        
        // Track for property iteration
        _trackPoolAndShareClass(poolId, scId);
        _trackAsset(assetId);
        
        balanceSheet.deposit(poolId, scId, vault.asset(), tokenId, amount);

        sumOfManagerDeposits[vault.asset()] += amount;
        
        // Update queue ghost variables
        bytes32 assetKey = keccak256(abi.encode(poolId, scId, assetId));
        ghost_assetQueueDeposits[assetKey] += amount;
    }

    // NOTE: removed because not useful for fuzzing
    // function balanceSheet_file(bytes32 what, address data) public updateGhosts asActor {
    //     balanceSheet.file(what, data);
    // }

    function balanceSheet_issue(uint128 shares) public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();

        // Track for property iteration
        _trackPoolAndShareClass(poolId, scId);

        // Track previous net position for flip detection
        bytes32 shareKey = keccak256(abi.encode(poolId, scId));
        int256 prevNetPosition = ghost_netSharePosition[shareKey];
        
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
        
        balanceSheet.noteDeposit(poolId, scId, vault.asset(), tokenId, amount);
        
        // Update queue ghost variables
        bytes32 assetKey = keccak256(abi.encode(poolId, scId, assetId));
        ghost_assetQueueDeposits[assetKey] += amount;
    }

    function balanceSheet_overridePricePoolPerAsset(D18 value) public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        AssetId assetId = spoke.vaultDetails(vault).assetId;  // Fixed: Use proper asset ID resolution
        balanceSheet.overridePricePoolPerAsset(vault.poolId(), vault.scId(), assetId, value);
    }

    function balanceSheet_overridePricePoolPerShare(D18 value) public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        balanceSheet.overridePricePoolPerShare(vault.poolId(), vault.scId(), value);
    }

    function balanceSheet_recoverTokens(address token, uint256 amount) public updateGhosts asActor {
        balanceSheet.recoverTokens(token, _getActor(), amount);
    }

    function balanceSheet_recoverTokens(address token, uint256 tokenId, uint256 amount) public updateGhosts asActor {
        balanceSheet.recoverTokens(token, tokenId, _getActor(), amount);
    }

    function balanceSheet_rely() public updateGhosts asActor {
        balanceSheet.rely(_getActor());
    }

    function balanceSheet_resetPricePoolPerAsset() public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        AssetId assetId = spoke.vaultDetails(vault).assetId;  // Fixed: Use proper asset ID resolution
        balanceSheet.resetPricePoolPerAsset(vault.poolId(), vault.scId(), assetId);
    }

    function balanceSheet_resetPricePoolPerShare() public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        balanceSheet.resetPricePoolPerShare(vault.poolId(), vault.scId());
    }

    function balanceSheet_revoke(uint128 shares) public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();

        // Track for property iteration
        _trackPoolAndShareClass(poolId, scId);

        // Track previous net position for flip detection
        bytes32 shareKey = keccak256(abi.encode(poolId, scId));
        int256 prevNetPosition = ghost_netSharePosition[shareKey];
        
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
        balanceSheet.transferSharesFrom(
            vault.poolId(), vault.scId(), _getActor(), _getActor(), _getRandomActor(uint256(uint160(to))), amount
        );
    }

    function balanceSheet_withdraw(uint256 tokenId, uint128 amount) public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = spoke.vaultDetails(vault).assetId;  // Fixed: Use proper asset ID resolution
        
        balanceSheet.withdraw(poolId, scId, vault.asset(), tokenId, _getActor(), amount);

        sumOfManagerWithdrawals[vault.asset()] += amount;
        
        // Update queue ghost variables
        bytes32 assetKey = keccak256(abi.encode(poolId, scId, assetId));
        ghost_assetQueueWithdrawals[assetKey] += amount;
    }

    // === NEW TARGET FUNCTIONS FOR QUEUE OPERATIONS ===
    
    function balanceSheet_reserve(uint256 tokenId, uint128 amount) public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        balanceSheet.reserve(vault.poolId(), vault.scId(), vault.asset(), tokenId, amount);
    }
    
    function balanceSheet_unreserve(uint256 tokenId, uint128 amount) public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        balanceSheet.unreserve(vault.poolId(), vault.scId(), vault.asset(), tokenId, amount);
    }
    
    function balanceSheet_submitQueuedAssets(uint128 extraGasLimit) public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = spoke.vaultDetails(vault).assetId;  // Fixed: Use proper asset ID resolution
        
        // Track nonce before submission
        bytes32 assetKey = keccak256(abi.encode(poolId, scId, assetId));
        bytes32 shareKey = keccak256(abi.encode(poolId, scId));
        ghost_assetQueueNonce[assetKey]++;
        
        balanceSheet.submitQueuedAssets(poolId, scId, assetId, extraGasLimit);
    }
    
    function balanceSheet_submitQueuedShares(uint128 extraGasLimit) public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        
        // Track nonce before submission
        bytes32 shareKey = keccak256(abi.encode(poolId, scId));
        ghost_shareQueueNonce[shareKey]++;
        
        balanceSheet.submitQueuedShares(poolId, scId, extraGasLimit);
    }
}
