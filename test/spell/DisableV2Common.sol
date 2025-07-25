// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {IRoot} from "src/common/interfaces/IRoot.sol";

import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";

interface VaultLike {
    function root() external view returns (address);
    function manager() external view returns (address);
}

interface InvestmentManagerLike {
    function poolManager() external view returns (address);
}

/// @notice Base contract for disabling V2 USDC share token/vault permissions and setting V3 hook
abstract contract DisableV2Common {
    bool public done;
    string public constant description = "Disable V2 permissions and set V3 hook";

    // Roots (same across all networks)
    IRoot public constant V2_ROOT = IRoot(0x0C1fDfd6a1331a875EA013F3897fc8a76ada5DfC);
    IRoot public constant V3_ROOT = IRoot(0x7Ed48C31f2fdC40d37407cBaBf0870B2b688368f);

    // FullRestrictionsHook
    address public constant V3_HOOK_ADDRESS = 0xa2C98F0F76Da0C97039688CA6280d082942d0b48;

    // JTRSY configuration (exists on all networks except Celo with same addresses)
    IShareToken public constant JTRSY_SHARE_TOKEN = IShareToken(0x8c213ee79581Ff4984583C6a801e5263418C4b86);

    function cast() external {
        require(!done, "spell-already-cast");
        done = true;
        execute();
    }

    function execute() internal virtual {
        _disableV2Permissions(JTRSY_SHARE_TOKEN, getJTRSYVaultAddress());
        _setV3Hook(JTRSY_SHARE_TOKEN);

        // Final cleanup - deny spell's root permissions
        _cleanupRootPermissions();
    }

    function _cleanupRootPermissions() internal virtual {
        IAuth(address(V2_ROOT)).deny(address(this));
        IAuth(address(V3_ROOT)).deny(address(this));
    }

    function _disableV2Permissions(IShareToken shareToken, address vaultAddress) internal {
        VaultLike vault = VaultLike(vaultAddress);

        // Query V2 system addresses from vault
        address v2InvestmentManager = vault.manager();
        address v2PoolManager = InvestmentManagerLike(v2InvestmentManager).poolManager();
        address shareTokenAddress = address(shareToken);

        // Remove V2 permissions from share token
        V2_ROOT.denyContract(shareTokenAddress, v2PoolManager);
        V2_ROOT.denyContract(shareTokenAddress, v2InvestmentManager);
        V2_ROOT.denyContract(shareTokenAddress, address(V2_ROOT));

        // Remove vault permissions from investment manager to disable operations
        V2_ROOT.denyContract(v2InvestmentManager, vaultAddress);
    }

    function _setV3Hook(IShareToken shareToken) internal {
        V3_ROOT.relyContract(address(shareToken), address(this));
        shareToken.file("hook", V3_HOOK_ADDRESS);
        V3_ROOT.denyContract(address(shareToken), address(this));
    }

    // JTRSY vault addresses per network (to be overridden by child contracts)
    function getJTRSYVaultAddress() internal pure virtual returns (address);
}
