// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Recon Deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {vm} from "@chimera/Hevm.sol";
import {console2} from "forge-std/console2.sol";

// Dependencies
import {ERC20} from "src/misc/ERC20.sol";
import {AsyncVault} from "src/vaults/AsyncVault.sol";
import {CentrifugeToken} from "src/vaults/token/ShareToken.sol";
import {RestrictedTransfers} from "src/hooks/RestrictedTransfers.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";

// Component
import {ShareTokenTargets} from "./targets/ShareTokenTargets.sol";
import {RestrictedTransfersTargets} from "./targets/RestrictedTransfersTargets.sol";
import {VaultTargets} from "./targets/VaultTargets.sol";
import {PoolManagerTargets} from "./targets/PoolManagerTargets.sol";
import {VaultCallbackTargets} from "./targets/VaultCallbackTargets.sol";
import {ManagerTargets} from "./targets/ManagerTargets.sol";
import {Properties} from "./properties/Properties.sol";
import {AdminTargets} from "./targets/AdminTargets.sol";
import {HubTargets} from "./targets/HubTargets.sol";
import {ToggleTargets} from "./targets/ToggleTargets.sol";

abstract contract TargetFunctions is
    BaseTargetFunctions,
    Properties,
    ShareTokenTargets,
    RestrictedTransfersTargets,
    VaultTargets,
    PoolManagerTargets,
    VaultCallbackTargets, 
    ManagerTargets,
    HubTargets,
    AdminTargets,
    ToggleTargets 
{
    bool hasDoneADeploy;

    /// === Canaries === ///
    function canary_doesTokenGetDeployed() public view returns (bool) {
        if (RECON_TOGGLE_CANARY_TESTS) {
            return _getAssets().length < 10;
        }

        return true;
    }

    function canary_doesShareGetDeployed() public view returns (bool) {
        if (RECON_TOGGLE_CANARY_TESTS) {
            return shareClassTokens.length < 10;
        }

        return true;
    }

    function canary_doesVaultGetDeployed() public view returns (bool) {
        if (RECON_TOGGLE_CANARY_TESTS) {
            return vaults.length < 10;
        }

        return true;
    }


    /// === Shortcut Functions === ///
    /// @dev This is the main system setup function done like this to explore more possible states
    /// @dev Deploy new asset, add asset to pool, deploy share class, deploy vault
    function shortcut_deployNewTokenPoolAndShare(uint8 decimals, uint256 salt, bool isIdentityValuation, bool isDebitNormal)
        public
        returns (address _token, address _shareToken, address _vault, uint128 _assetId, bytes16 _scId)
    {
        // NOTE: TEMPORARY
        require(!hasDoneADeploy); // This bricks the function for this one for Medusa
        // Meaning we only deploy one token, one Pool, one share class

        if (RECON_USE_SINGLE_DEPLOY) {
            hasDoneADeploy = true;
        }

        if (RECON_USE_HARDCODED_DECIMALS) {
            decimals = 18;
        }

        // NOTE END TEMPORARY

        /// @audit NOTE: This works because we only deploy once!!
        decimals = decimals % RECON_MODULO_DECIMALS;

        // 1. Deploy new token and register it as an asset
        _token = _newAsset(decimals);
        PoolId _poolId;

        {
            _assetId = poolManager_registerAsset(address(_token), 0);
            console2.log("assetId", _assetId);

            hub_registerAsset(_assetId);
        }

        // 2. Deploy new pool and register it
        {
            _poolId = hub_createPool(address(this), _assetId);

            poolManager_addPool(_poolId.raw());
        }

        // 3. Deploy new share class and register it
        {
            hub_addShareClass(_poolId.raw(), salt);

            ShareClassId scIdTemp = shareClassManager.previewNextShareClassId(_poolId);
            _scId = scIdTemp.raw();
            // TODO: Should we customize decimals and permissions here?
            (_shareToken,) = poolManager_addShareClass(_poolId.raw(), _scId, 18, address(restrictedTransfers));
        }

        // 4. Create accounts and holding
        {
            IERC7726 valuation = isIdentityValuation ? 
                        IERC7726(address(identityValuation)) : 
                        IERC7726(address(transientValuation));
                        
            hub_createAccount(_poolId.raw(), ASSET_ACCOUNT, isDebitNormal);
            hub_createAccount(_poolId.raw(), EQUITY_ACCOUNT, isDebitNormal);
            hub_createAccount(_poolId.raw(), LOSS_ACCOUNT, isDebitNormal);
            hub_createAccount(_poolId.raw(), GAIN_ACCOUNT, isDebitNormal);
            
            hub_createHolding(_poolId.raw(), _scId, valuation, ASSET_ACCOUNT, EQUITY_ACCOUNT, LOSS_ACCOUNT, GAIN_ACCOUNT);
        }

        // 5. Deploy new vault and register it
        _vault = poolManager_deployVault(_poolId.raw(), _scId, _assetId);
        poolManager_linkVault(_poolId.raw(), _scId, _assetId, _vault);
        asyncRequests.rely(address(_vault));

        // 6. approve and mint initial amount of underlying asset to all actors
        address[] memory approvals = new address[](2);
        approvals[0] = address(poolManager);
        approvals[1] = address(vault);
        _finalizeAssetDeployment(_getActors(), approvals, type(uint88).max);

        vault = AsyncVault(_vault);
        token = CentrifugeToken(_shareToken);
        restrictedTransfers = RestrictedTransfers(address(token.hook()));

        // NOTE: Add to storage so these can be clamped in other functions
        scId = _scId;
        poolId = _poolId.raw();
        assetId = _assetId;
    }

    /// === Permission Functions === ///
    // TODO: can probably remove these
    function root_scheduleRely(address target) public asAdmin {
        root.scheduleRely(target);
    }

    function root_cancelRely(address target) public asAdmin {
        root.cancelRely(target);
    }
}
