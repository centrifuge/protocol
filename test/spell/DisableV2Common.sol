// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {IRoot} from "src/common/interfaces/IRoot.sol";
import {ISpoke} from "src/spoke/interfaces/ISpoke.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

/// @notice Interface for interacting with V2 vaults
interface VaultLike {
    function root() external view returns (address);
    function manager() external view returns (address);
}

/// @notice Interface for interacting with V2 investment managers
interface InvestmentManagerLike {
    function poolManager() external view returns (address);
}

/// @notice Base contract for disabling V2 USDC share token/vault permissions and setting V3 hook
abstract contract DisableV2Common {
    bool public done;
    string public constant description = "Disable V2 permissions and set V3 hook";

    IRoot public constant V2_ROOT = IRoot(0x0C1fDfd6a1331a875EA013F3897fc8a76ada5DfC);
    IRoot public constant V3_ROOT = IRoot(0x7Ed48C31f2fdC40d37407cBaBf0870B2b688368f);

    ISpoke public constant V3_SPOKE = ISpoke(0xd30Da1d7F964E5f6C2D9fE2AAA97517F6B23FA2B);
    address public constant V3_FULL_RESTRICTIONS_HOOK = 0xa2C98F0F76Da0C97039688CA6280d082942d0b48;

    PoolId public constant JTRSY_POOL_ID = PoolId.wrap(281474976710662);
    address public constant V3_JTRSY_VAULT = 0xFE6920eB6C421f1179cA8c8d4170530CDBdfd77A;

    IShareToken public constant JTRSY_SHARE_TOKEN = IShareToken(0x8c213ee79581Ff4984583C6a801e5263418C4b86);
    ShareClassId public constant JTRSY_SHARE_CLASS_ID = ShareClassId.wrap(0x00010000000000060000000000000001);

    function cast() external {
        require(!done, "spell-already-cast");
        done = true;
        execute();
    }

    function execute() internal virtual {
        _disableV2Permissions(JTRSY_SHARE_TOKEN, getJTRSYVaultV2Address());
        _setV3Hook(JTRSY_SHARE_TOKEN);
        _linkTokenToV3Vault(JTRSY_SHARE_TOKEN, V3_JTRSY_VAULT, JTRSY_POOL_ID, JTRSY_SHARE_CLASS_ID);
    }

    function _cleanupRootPermissions() internal virtual {
        IAuth(address(V2_ROOT)).deny(address(this));
        IAuth(address(V3_ROOT)).deny(address(this));
    }

    /// @notice Disables V2 permissions for a share token and its associated vault
    /// @param shareToken The share token to disable permissions for
    /// @param vaultAddress The V2 vault address associated with the share token
    function _disableV2Permissions(IShareToken shareToken, address vaultAddress) internal {
        VaultLike vault = VaultLike(vaultAddress);

        // Query V2 system addresses from vault
        address v2InvestmentManager = vault.manager();
        address v2PoolManager = InvestmentManagerLike(v2InvestmentManager).poolManager();
        address shareTokenAddress = address(shareToken);

        // Remove V2 permissions from share token
        V2_ROOT.denyContract(shareTokenAddress, v2PoolManager);
        V2_ROOT.denyContract(shareTokenAddress, v2InvestmentManager);

        // Remove vault permissions from investment manager to disable operations
        V2_ROOT.denyContract(v2InvestmentManager, vaultAddress);
    }

    /// @notice Sets the V3 hook on a share token
    /// @param shareToken The share token to set the hook on
    function _setV3Hook(IShareToken shareToken) internal {
        V3_ROOT.relyContract(address(shareToken), address(this));
        shareToken.file("hook", V3_FULL_RESTRICTIONS_HOOK);
        V3_ROOT.denyContract(address(shareToken), address(this));
    }

    /// @notice Links a share token to the V3 system via pool and share class IDs
    /// @param shareToken The share token to link
    /// @param poolId The V3 pool ID to link to
    /// @param scId The V3 share class ID to link to
    function _linkTokenToV3Vault(IShareToken shareToken, address, /* vaultAddress */ PoolId poolId, ShareClassId scId)
        internal
    {
        // Grant temporary permissions to this spell
        V3_ROOT.relyContract(address(V3_SPOKE), address(this));

        // Link the share token to the pool/share class
        V3_SPOKE.linkToken(poolId, scId, shareToken);

        // Remove permissions from this spell
        V3_ROOT.denyContract(address(V3_SPOKE), address(this));
    }

    /// @notice Returns the JTRSY vault address for the specific network
    /// @dev Must be overridden by child contracts to provide network-specific addresses
    /// @return The JTRSY V2 vault address for this network
    function getJTRSYVaultV2Address() internal pure virtual returns (address);
}
