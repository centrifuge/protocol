// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseSetup} from "@chimera/BaseSetup.sol";
import {Escrow} from "src/vaults/Escrow.sol";
import {InvestmentManager} from "src/vaults/InvestmentManager.sol";
import {PoolManager} from "src/vaults/PoolManager.sol";
import {ERC7540Vault} from "src/vaults/ERC7540Vault.sol";
import {Root} from "src/common/Root.sol";
import {Tranche} from "src/vaults/token/Tranche.sol";

import {ERC7540VaultFactory} from "src/vaults/factories/ERC7540VaultFactory.sol";
import {TrancheFactory} from "src/vaults/factories/TrancheFactory.sol";

import {RestrictionManager} from "src/vaults/token/RestrictionManager.sol";
import {ERC20} from "src/misc/ERC20.sol";

// Mocks
import {IRoot} from "src/common/interfaces/IRoot.sol";

// Storage
import {SharedStorage} from "./SharedStorage.sol";

abstract contract Setup is BaseSetup, SharedStorage {
    // Dependencies
    ERC7540VaultFactory vaultFactory;
    TrancheFactory trancheFactory;

    // Handled //
    Escrow public escrow; // NOTE: Restriction Manager will query it
    InvestmentManager investmentManager;
    PoolManager poolManager;

    // TODO: CYCLE / Make it work for variable values
    ERC7540Vault vault;
    ERC20 token;
    Tranche trancheToken;
    address actor = address(this); // TODO: Generalize
    RestrictionManager restrictionManager;

    bytes16 trancheId;
    uint64 poolId;
    uint64 currencyId;

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
        trancheFactory = new TrancheFactory(address(this), address(this));
        escrow = new Escrow(address(address(this)));
        root = new Root(48 hours, address(this));
        restrictionManager = new RestrictionManager(address(root), address(this));

        root.endorse(address(escrow));

        investmentManager = new InvestmentManager(address(root), address(escrow));
        vaultFactory = new ERC7540VaultFactory(address(this), address(investmentManager));

        address[] memory vaultFactories = new address[](1);
        vaultFactories[0] = address(vaultFactory);

        poolManager = new PoolManager(address(escrow), address(trancheFactory), vaultFactories, uint32(block.chainid));
        poolManager.file("gateway", address(this));

        investmentManager.file("gateway", address(this));
        investmentManager.file("poolManager", address(poolManager));
        investmentManager.rely(address(poolManager));
        investmentManager.rely(address(vaultFactory));

        restrictionManager.rely(address(poolManager));

        // Setup Escrow Permissions
        escrow.rely(address(investmentManager));
        escrow.rely(address(poolManager));

        // Permissions on factories
        vaultFactory.rely(address(poolManager));
        trancheFactory.rely(address(poolManager));

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
        ) = investmentManager.investments(address(vault), address(actor));

        return (depositPrice, redeemPrice);
    }
}
