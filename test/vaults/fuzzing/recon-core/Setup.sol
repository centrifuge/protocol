// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseSetup} from "@chimera/BaseSetup.sol";
import {Escrow} from "src/vaults/Escrow.sol";
import {AsyncRequests} from "src/vaults/AsyncRequests.sol";
import {PoolManager} from "src/vaults/PoolManager.sol";
import {AsyncVault} from "src/vaults/AsyncVault.sol";
import {Root} from "src/common/Root.sol";
import {ShareToken} from "src/vaults/token/ShareToken.sol";

import {AsyncVaultFactory} from "src/vaults/factories/AsyncVaultFactory.sol";
import {TokenFactory} from "src/vaults/factories/TokenFactory.sol";

import {RestrictedTransfers} from "src/hooks/RestrictedTransfers.sol";
import {ERC20} from "src/misc/ERC20.sol";
import {PoolEscrowFactory} from "src/vaults/factories/PoolEscrowFactory.sol";

// Mocks
import {IRoot} from "src/common/interfaces/IRoot.sol";

// Storage
import {SharedStorage} from "./SharedStorage.sol";

abstract contract Setup is BaseSetup, SharedStorage {
    // Dependencies
    AsyncVaultFactory vaultFactory;
    TokenFactory tokenFactory;

    // Handled
    AsyncRequests asyncRequests;
    PoolManager poolManager;
    PoolEscrowFactory poolEscrowFactory;

    // TODO: CYCLE / Make it work for variable values
    AsyncVault vault;
    ERC20 assetErc20;
    ShareToken token;
    address actor = address(this); // TODO: Generalize
    RestrictedTransfers restrictedTransfers;

    bytes16 scId;
    uint64 poolId;
    uint128 assetId;

    // MOCKS
    address centrifugeChain;
    IRoot root;

    // LP request ID is always 0
    uint256 REQUEST_ID = 0;

    // MOCK++
    fallback() external payable {
        // Basically we will receive `root.rely, etc..`
    }

    receive() external payable {}

    function setup() internal virtual override {
        // Put self so we can perform settings
        centrifugeChain = address(this);

        // Dependencies
        tokenFactory = new TokenFactory(address(this), address(this));
        root = new Root(48 hours, address(this));
        restrictedTransfers = new RestrictedTransfers(address(root), address(this));
        poolEscrowFactory = new PoolEscrowFactory(address(root), address(this));

        asyncRequests = new AsyncRequests(address(root), address(this));
        vaultFactory = new AsyncVaultFactory(address(this), address(asyncRequests), poolEscrowFactory, address(this));

        address[] memory vaultFactories = new address[](1);
        vaultFactories[0] = address(vaultFactory);

        poolManager = new PoolManager(address(tokenFactory), vaultFactories, address(this));

        asyncRequests.file("poolManager", address(poolManager));
        asyncRequests.file("poolEscrowProvider", address(poolEscrowFactory));
        asyncRequests.rely(address(poolManager));
        asyncRequests.rely(address(vaultFactory));

        restrictedTransfers.rely(address(poolManager));

        // Permissions on factories
        vaultFactory.rely(address(poolManager));
        tokenFactory.rely(address(poolManager));
        poolEscrowFactory.rely(address(poolManager));

        poolEscrowFactory.file("poolManager", address(poolManager));
        poolEscrowFactory.file("asyncRequests", address(asyncRequests));

        // TODO: Cycling of:
        // Actors and ERC7540 Vaults
    }

    /**
     * GLOBAL GHOST
     */
    mapping(address => Vars) internal _investorsGlobals;

    struct Vars {
        // See IM_1
        uint256 maxDepositPrice;
        uint256 minDepositPrice;
        // See IM_2
        uint256 maxRedeemPrice;
        uint256 minRedeemPrice;
    }

    function __globals() internal {
        (uint256 depositPrice, uint256 redeemPrice) = _getDepositAndRedeemPrice();

        // Conditionally Update max | Always works on zero
        _investorsGlobals[actor].maxDepositPrice = depositPrice > _investorsGlobals[actor].maxDepositPrice
            ? depositPrice
            : _investorsGlobals[actor].maxDepositPrice;
        _investorsGlobals[actor].maxRedeemPrice = redeemPrice > _investorsGlobals[actor].maxRedeemPrice
            ? redeemPrice
            : _investorsGlobals[actor].maxRedeemPrice;

        // Conditionally Update min
        // On zero we have to update anyway
        if (_investorsGlobals[actor].minDepositPrice == 0) {
            _investorsGlobals[actor].minDepositPrice = depositPrice;
        }
        if (_investorsGlobals[actor].minRedeemPrice == 0) {
            _investorsGlobals[actor].minRedeemPrice = redeemPrice;
        }

        // Conditional update after zero
        _investorsGlobals[actor].minDepositPrice = depositPrice < _investorsGlobals[actor].minDepositPrice
            ? depositPrice
            : _investorsGlobals[actor].minDepositPrice;
        _investorsGlobals[actor].minRedeemPrice = redeemPrice < _investorsGlobals[actor].minRedeemPrice
            ? redeemPrice
            : _investorsGlobals[actor].minRedeemPrice;
    }

    function _getDepositAndRedeemPrice() internal view returns (uint256, uint256) {
        (
            /*uint128 maxMint*/
            ,
            /*uint128 maxWithdraw*/
            ,
            uint256 depositPrice,
            uint256 redeemPrice,
            /*uint128 pendingDepositRequest*/
            ,
            /*uint128 pendingRedeemRequest*/
            ,
            /*uint128 claimableCancelDepositRequest*/
            ,
            /*uint128 claimableCancelRedeemRequest*/
            ,
            /*bool pendingCancelDepositRequest*/
            ,
            /*bool pendingCancelRedeemRequest*/
        ) = asyncRequests.investments(address(vault), address(actor));

        return (depositPrice, redeemPrice);
    }
}
