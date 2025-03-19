// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {ISafe} from "src/common/Guardian.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import {Gateway} from "src/common/Gateway.sol";
import {CommonDeployer} from "script/CommonDeployer.s.sol";

import {InvestmentManager} from "src/vaults/InvestmentManager.sol";
import {TrancheFactory} from "src/vaults/factories/TrancheFactory.sol";
import {ERC7540VaultFactory} from "src/vaults/factories/ERC7540VaultFactory.sol";
import {RestrictionManager} from "src/vaults/token/RestrictionManager.sol";
import {RestrictedRedemptions} from "src/vaults/token/RestrictedRedemptions.sol";
import {PoolManager} from "src/vaults/PoolManager.sol";
import {Escrow} from "src/vaults/Escrow.sol";
import {VaultRouter} from "src/vaults/VaultRouter.sol";
import {MessageProcessor} from "src/vaults/MessageProcessor.sol";
import "forge-std/Script.sol";

contract VaultsDeployer is CommonDeployer {
    IAdapter[] adapters;

    InvestmentManager public investmentManager;
    PoolManager public poolManager;
    Escrow public escrow;
    Escrow public routerEscrow;
    Gateway public vaultGateway;
    MessageProcessor public vaultMessageProcessor;
    VaultRouter public router;
    address public vaultFactory;
    address public restrictionManager;
    address public restrictedRedemptions;
    address public trancheFactory;

    function deployVaults(ISafe adminSafe_, address deployer) public {
        super.deployCommon(adminSafe_, deployer);

        escrow = new Escrow{salt: SALT}(deployer);
        routerEscrow = new Escrow{salt: keccak256(abi.encodePacked(SALT, "escrow2"))}(deployer);
        restrictionManager = address(new RestrictionManager{salt: SALT}(address(root), deployer));
        restrictedRedemptions = address(new RestrictedRedemptions{salt: SALT}(address(root), address(escrow), deployer));
        trancheFactory = address(new TrancheFactory{salt: SALT}(address(root), deployer));
        investmentManager = new InvestmentManager(address(root), address(escrow));
        vaultFactory = address(new ERC7540VaultFactory(address(root), address(investmentManager)));

        address[] memory vaultFactories = new address[](1);
        vaultFactories[0] = vaultFactory;

        poolManager = new PoolManager(address(escrow), trancheFactory, vaultFactories);
        vaultGateway = new Gateway(root, gasService);
        vaultMessageProcessor =
            new MessageProcessor(vaultGateway, poolManager, investmentManager, root, gasService, deployer);
        router = new VaultRouter(address(routerEscrow), address(vaultGateway), address(poolManager));

        _vaultsEndorse();
        _vaultsRely();
        _vaultsFile();
    }

    function _vaultsEndorse() private {
        root.endorse(address(router));
        root.endorse(address(escrow));
    }

    function _vaultsRely() private {
        // Rely on PoolManager
        escrow.rely(address(poolManager));
        IAuth(vaultFactory).rely(address(poolManager));
        IAuth(trancheFactory).rely(address(poolManager));
        IAuth(investmentManager).rely(address(poolManager));
        IAuth(restrictionManager).rely(address(poolManager));
        IAuth(restrictedRedemptions).rely(address(poolManager));
        vaultMessageProcessor.rely(address(poolManager));

        // Rely on InvestmentManager
        vaultMessageProcessor.rely(address(investmentManager));

        // Rely on Root
        router.rely(address(root));
        poolManager.rely(address(root));
        investmentManager.rely(address(root));
        vaultGateway.rely(address(root));
        escrow.rely(address(root));
        routerEscrow.rely(address(root));
        IAuth(vaultFactory).rely(address(root));
        IAuth(trancheFactory).rely(address(root));
        IAuth(restrictionManager).rely(address(root));
        IAuth(restrictedRedemptions).rely(address(root));

        // Rely on guardian
        vaultGateway.rely(address(guardian));

        // Rely on vaultGateway
        vaultMessageProcessor.rely(address(vaultGateway));
        investmentManager.rely(address(vaultGateway));
        poolManager.rely(address(vaultGateway));
        gasService.rely(address(vaultGateway));

        // Rely on others
        routerEscrow.rely(address(router));

        // Rely on vaultMessageProcessor
        vaultGateway.rely(address(vaultMessageProcessor));
        poolManager.rely(address(vaultMessageProcessor));
        investmentManager.rely(address(vaultMessageProcessor));
        root.rely(address(vaultMessageProcessor));
        gasService.rely(address(vaultMessageProcessor));

        // Rely on VaultRouter
        vaultGateway.rely(address(router));
    }

    function _vaultsFile() public {
        poolManager.file("gateway", address(vaultGateway));
        poolManager.file("sender", address(vaultMessageProcessor));

        investmentManager.file("poolManager", address(poolManager));
        investmentManager.file("gateway", address(vaultGateway));
        investmentManager.file("sender", address(vaultMessageProcessor));

        vaultGateway.file("handler", address(vaultMessageProcessor));
    }

    function wire(IAdapter adapter) public {
        adapters.push(adapter);
        vaultGateway.file("adapters", adapters);
        IAuth(address(adapter)).rely(address(root));
    }

    function removeVaultsDeployerAccess(address deployer) public {
        super.removeCommonDeployerAccess(deployer);

        IAuth(vaultFactory).deny(deployer);
        IAuth(trancheFactory).deny(deployer);
        IAuth(restrictionManager).deny(deployer);
        IAuth(restrictedRedemptions).deny(deployer);
        investmentManager.deny(deployer);
        poolManager.deny(deployer);
        escrow.deny(deployer);
        routerEscrow.deny(deployer);
        vaultGateway.deny(deployer);
        router.deny(deployer);
    }
}
