// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ChainResolver} from "./ChainResolver.sol";
import {ValidationOrchestrator} from "./validation/ValidationOrchestrator.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";

import {ISafe} from "../../../src/admin/interfaces/ISafe.sol";

import {MigrationQueries} from "../../../script/spell/MigrationQueries.sol";
import {MigrationV3_1Executor} from "../../../script/spell/MigrationV3_1.s.sol";
import {
    FullActionBatcher,
    FullDeployer,
    FullInput,
    FullReport,
    noAdaptersInput,
    defaultTxLimits,
    CoreInput
} from "../../../script/FullDeployer.s.sol";

import "forge-std/Test.sol";

import {MigrationSpell} from "../../../src/spell/migration_v3.1/MigrationSpell.sol";
import {ForkTestLiveValidation} from "../../integration/fork/ForkTestLiveValidation.sol";

contract MigrationV3_1Test is Test {
    ISafe immutable ADMIN = ISafe(makeAddr("ADMIN"));
    bytes32 constant NEW_VERSION = "v3.1";
    PoolId[] poolsToMigrate;

    function _testCase(string memory rpcUrl, bool isMainnet) public {
        vm.createSelectFork(rpcUrl);

        ChainResolver.ChainContext memory chain = ChainResolver.resolveChainContext(isMainnet);
        MigrationQueries queryService = new MigrationQueries(isMainnet);
        queryService.configureGraphQl(chain.graphQLApi, chain.localCentrifugeId);

        if (isMainnet) {
            poolsToMigrate = [
                PoolId.wrap(281474976710657),
                PoolId.wrap(281474976710658),
                PoolId.wrap(281474976710659),
                PoolId.wrap(281474976710660),
                PoolId.wrap(281474976710661),
                PoolId.wrap(281474976710662),
                PoolId.wrap(281474976710663),
                PoolId.wrap(281474976710664),
                PoolId.wrap(281474976710665),
                PoolId.wrap(1125899906842625)
            ];
        } else {
            poolsToMigrate = [PoolId.wrap(281474976710662), PoolId.wrap(281474976710668)];
        }

        // ----- DEPLOYMENT (v3.1) -----

        FullDeployer deployer = new FullDeployer();
        FullActionBatcher batcher = new FullActionBatcher(address(deployer));

        deployer.labelAddresses("");
        deployer.deployFull(
            FullInput({
                core: CoreInput({
                    centrifugeId: chain.localCentrifugeId,
                    version: NEW_VERSION,
                    root: address(chain.rootV3),
                    txLimits: defaultTxLimits()
                }),
                adminSafe: ADMIN,
                opsSafe: ADMIN,
                adapters: noAdaptersInput()
            }),
            batcher
        );

        // ----- SPELL DEPLOYMENT -----

        MigrationV3_1Executor migration = new MigrationV3_1Executor(isMainnet);
        MigrationSpell migrationSpell = new MigrationSpell(address(migration));

        // ----- LABELLING -----

        vm.label(chain.rootWard, "v3.messageDispatcher");
        vm.label(address(deployer), "deployer");
        vm.label(address(batcher), "batcher");
        vm.label(address(migration), "migration");

        // ----- BUILD SHARED CONTEXT -----

        ValidationOrchestrator.SharedContext memory shared =
            ValidationOrchestrator.buildSharedContext(queryService, poolsToMigrate, chain, "");

        // ----- PRE-MIGRATION VALIDATION -----

        ValidationOrchestrator.runPreValidation(shared, false); // shouldRevert = false (show warnings)

        // Also run existing deployment validation
        _validateV3_1Deployment(deployer.fullReport(), address(deployer.adminSafe()), true, isMainnet);

        // ----- EXECUTE MIGRATION -----

        vm.prank(chain.rootWard);
        chain.rootV3.rely(address(migrationSpell)); // Ideally through guardian.scheduleRely()

        migration.migrate(address(deployer), migrationSpell, poolsToMigrate);

        // ----- STEP 3: POST-MIGRATION VALIDATION -----

        assertEq(migrationSpell.owner(), address(0));

        ValidationOrchestrator.runPostValidation(shared, deployer.fullReport());

        // Also run existing deployment validation
        _validateV3_1Deployment(deployer.fullReport(), address(deployer.adminSafe()), false, isMainnet);
    }

    /// @notice Validate v3.1 deployment permissions and configuration
    /// @param preMigration If true, skips validations that only apply post-migration
    /// @param isMainnet If true, validates production vaults. Set to false for testnets.
    function _validateV3_1Deployment(FullReport memory latest, address safeAdmin, bool preMigration, bool isMainnet)
        internal
    {
        console.log("[DEBUG] Starting deployment validation: preMigration=%s, isMainnet=%s", preMigration, isMainnet);
        ForkTestLiveValidation validator = new ForkTestLiveValidation();
        validator.loadContractsFromDeployer(latest, safeAdmin);
        validator.validateDeployment(preMigration, isMainnet);
    }

    function testMigrationEthereumMainnet() external {
        _testCase(string.concat("https://eth-mainnet.g.alchemy.com/v2/", vm.envString("ALCHEMY_API_KEY")), true);
    }

    function testMigrationBaseMainnet() external {
        _testCase(string.concat("https://base-mainnet.g.alchemy.com/v2/", vm.envString("ALCHEMY_API_KEY")), true);
    }

    function testMigrationArbitrumMainnet() external {
        _testCase(string.concat("https://arb-mainnet.g.alchemy.com/v2/", vm.envString("ALCHEMY_API_KEY")), true);
    }

    function testMigrationAvalancheMainnet() external {
        _testCase(string.concat("https://avax-mainnet.g.alchemy.com/v2/", vm.envString("ALCHEMY_API_KEY")), true);
    }

    function testMigrationBNBMainnet() external {
        _testCase(string.concat("https://bnb-mainnet.g.alchemy.com/v2/", vm.envString("ALCHEMY_API_KEY")), true);
    }

    function testMigrationPlumeMainnet() external {
        _testCase(string.concat("https://rpc.plume.org/", vm.envString("PLUME_API_KEY")), true);
    }

    function testMigrationEthereumSepolia() external {
        _testCase(string.concat("https://eth-sepolia.g.alchemy.com/v2/", vm.envString("ALCHEMY_API_KEY")), false);
    }

    function testMigrationBaseSepolia() external {
        _testCase(string.concat("https://base-sepolia.g.alchemy.com/v2/", vm.envString("ALCHEMY_API_KEY")), false);
    }

    function testMigrationArbitrumSepolia() external {
        _testCase(string.concat("https://arb-sepolia.g.alchemy.com/v2/", vm.envString("ALCHEMY_API_KEY")), false);
    }
}
