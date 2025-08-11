// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Network: BNB Smart Chain (Chain ID: 56)
// Deployed Address: 0x37271F54911A22156B39ab08E9f9738Cc9bf55e4
// Source Branch: spell/004-create2-factories
// CREATE3 Deterministic Deployment

import {IAuth} from "../../src/misc/interfaces/IAuth.sol";

import {IRoot} from "../../src/common/interfaces/IRoot.sol";

import {ISpoke} from "../../src/spoke/interfaces/ISpoke.sol";

import {IAsyncRequestManager} from "../../src/vaults/interfaces/IVaultManagers.sol";

/**
 * @title Create2VaultFactorySpellCommon
 * @notice Base governance spell to update vault factories to CREATE2 (optimized for chains without migrations)
 * @dev This contract only handles factory permission setup. For chains that need vault migrations,
 *      use Create2VaultFactorySpellWithMigration as the parent class instead.
 */
contract Create2VaultFactorySpellCommon {
    bool public done;
    string public constant description = "Update vault factories to CREATE2";

    // System contracts
    IRoot public constant ROOT = IRoot(0x7Ed48C31f2fdC40d37407cBaBf0870B2b688368f);
    ISpoke public constant SPOKE = ISpoke(0xd30Da1d7F964E5f6C2D9fE2AAA97517F6B23FA2B);
    IAsyncRequestManager public constant ASYNC_REQUEST_MANAGER =
        IAsyncRequestManager(0xf06f89A1b6C601235729A689595571B7455Dd433);
    address public constant SYNC_MANAGER = 0x0D82d9fa76CFCd6F4cc59F053b2458665C6CE773;

    address public constant OLD_ASYNC_VAULT_FACTORY = 0xed9D489BB79c7CB58c522f36Fc6944eAA95Ce385;
    address public constant OLD_SYNC_DEPOSIT_VAULT_FACTORY = 0x21BF2544b5A0B03c8566a16592ba1b3B192B50Bc;

    address public immutable newAsyncVaultFactory;
    address public immutable newSyncDepositVaultFactory;

    constructor(address asyncVaultFactory, address syncDepositVaultFactory) {
        newAsyncVaultFactory = asyncVaultFactory;
        newSyncDepositVaultFactory = syncDepositVaultFactory;
    }

    function cast() external {
        require(!done, "spell-already-cast");
        done = true;
        execute();
    }

    function execute() internal virtual {
        _setupFactoryPermissions();
        _finalCleanup();
    }

    function _setupFactoryPermissions() internal {
        ROOT.relyContract(address(ASYNC_REQUEST_MANAGER), address(this));
        IAuth(address(ASYNC_REQUEST_MANAGER)).deny(OLD_ASYNC_VAULT_FACTORY);
        IAuth(address(ASYNC_REQUEST_MANAGER)).deny(OLD_SYNC_DEPOSIT_VAULT_FACTORY);

        IAuth(address(ASYNC_REQUEST_MANAGER)).rely(newAsyncVaultFactory);
        IAuth(address(ASYNC_REQUEST_MANAGER)).rely(newSyncDepositVaultFactory);
        ROOT.denyContract(address(ASYNC_REQUEST_MANAGER), address(this));

        // Revoke old factory permissions on Spoke
        ROOT.relyContract(OLD_ASYNC_VAULT_FACTORY, address(this));
        IAuth(OLD_ASYNC_VAULT_FACTORY).deny(address(SPOKE));
        ROOT.denyContract(OLD_ASYNC_VAULT_FACTORY, address(this));

        ROOT.relyContract(OLD_SYNC_DEPOSIT_VAULT_FACTORY, address(this));
        IAuth(OLD_SYNC_DEPOSIT_VAULT_FACTORY).deny(address(SPOKE));
        ROOT.denyContract(OLD_SYNC_DEPOSIT_VAULT_FACTORY, address(this));

        ROOT.relyContract(newAsyncVaultFactory, address(this));
        IAuth(newAsyncVaultFactory).rely(address(ROOT));
        IAuth(newAsyncVaultFactory).rely(address(SPOKE));
        ROOT.denyContract(newAsyncVaultFactory, address(this));

        ROOT.relyContract(newSyncDepositVaultFactory, address(this));
        IAuth(newSyncDepositVaultFactory).rely(address(ROOT));
        IAuth(newSyncDepositVaultFactory).rely(address(SPOKE));
        ROOT.denyContract(newSyncDepositVaultFactory, address(this));
    }

    function _finalCleanup() internal virtual {
        IAuth(address(ROOT)).deny(address(this));
    }
}
