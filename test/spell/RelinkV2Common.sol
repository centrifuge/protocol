// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {IRoot} from "src/common/interfaces/IRoot.sol";

import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";

interface VaultLike {
    function root() external view returns (address);
    function manager() external view returns (address);
}

interface ShareTokenLike {
    function updateVault(address asset, address vault_) external;
}

interface InvestmentManagerLike {
    function poolManager() external view returns (address);
}

/// @notice Base contract for relinking V2 vault to JTRSY and JAAA token
abstract contract RelinkV2Common {
    bool public done;
    string public constant description = "Relinking V2 vault to JTRSY and JAAA token";

    // Roots (same across all networks)
    IRoot public constant V2_ROOT = IRoot(0x0C1fDfd6a1331a875EA013F3897fc8a76ada5DfC);

    // JTRSY configuration (exists on all networks except Celo with same addresses)
    IShareToken public constant JTRSY_SHARE_TOKEN = IShareToken(0x8c213ee79581Ff4984583C6a801e5263418C4b86);

    function cast() external {
        require(!done, "spell-already-cast");
        done = true;
        execute();
    }

    function execute() internal virtual {}

    function _relink(address asset, IShareToken shareToken, address vaultAddress) internal {
        VaultLike vault = VaultLike(vaultAddress);

        // Query V2 system addresses from vault
        address shareTokenAddress = address(shareToken);

        // Rely spell on share token
        V2_ROOT.relyContract(shareTokenAddress, address(this));

        // Link vault to spell
        shareToken.updateVault(asset, vaultAddress);

        // Deny spell on share token
        V2_ROOT.denyContract(shareTokenAddress, address(this));
    }

    function _cleanupRootPermissions() internal virtual {
        IAuth(address(V2_ROOT)).deny(address(this));
    }
}
