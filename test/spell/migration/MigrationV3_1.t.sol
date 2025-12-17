// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ChainResolver} from "./ChainResolver.sol";
import {ValidationOrchestrator} from "./validation/ValidationOrchestrator.sol";

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";

import {Root} from "../../../src/admin/Root.sol";
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

import {ForkTestLiveValidation} from "../../integration/fork/ForkTestLiveValidation.sol";
import {
    MigrationSpell,
    CFG,
    WCFG,
    WCFG_MULTISIG,
    CHAINBRIDGE_ERC20_HANDLER,
    CREATE3_PROXY,
    WORMHOLE_NTT,
    ROOT_V2
} from "../../../src/spell/migration_v3.1/MigrationSpell.sol";

contract MigrationV3_1Test is Test {
    address constant PRODUCTION_MESSAGE_DISPATCHER_V3 = 0x21AF0C29611CFAaFf9271C8a3F84F2bC31d59132;
    address constant TESTNET_MESSAGE_DISPATCHER_V3 = 0x332bE89CAB9FF501F5EBe3f6DC9487bfF50Bd0BF;
    address constant GUARDIAN_V2 = 0x09ab10a9c3E6Eac1d18270a2322B6113F4C7f5E8;

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
            ValidationOrchestrator.buildSharedContext(queryService, poolsToMigrate, chain, "", true);

        // ----- PRE-MIGRATION VALIDATION -----

        ValidationOrchestrator.runPreValidation(shared, false); // shouldRevert = false (show warnings)

        // Also run existing deployment validation
        _validateV3_1Deployment(deployer.fullReport(), address(deployer.adminSafe()), true, isMainnet);

        // ----- EXECUTE MIGRATION -----

        vm.prank(chain.rootWard);
        chain.rootV3.rely(address(migrationSpell)); // Ideally through guardian.scheduleRely()

        // Mainnet CFG and WCFG have only the v2 root relied, need to rely the v3 root as well
        // Which is done inside the spell, so the spell also needs to be relied on the v2 root
        if (isMainnet && chain.localCentrifugeId == 1) {
            vm.prank(GUARDIAN_V2);
            Root(ROOT_V2).rely(address(migrationSpell)); // Ideally through guardian.scheduleRely()
        }

        migration.migrate(address(deployer), migrationSpell, poolsToMigrate);

        // ----- STEP 3: POST-MIGRATION VALIDATION -----

        _validateSupplementalChanges(migrationSpell, chain.rootV3, isMainnet, chain.localCentrifugeId);

        ValidationOrchestrator.runPostValidation(shared, deployer.fullReport());

        // Also run existing deployment validation
        _validateV3_1Deployment(deployer.fullReport(), address(deployer.adminSafe()), false, isMainnet);
    }

    /// @notice Validate changes made by the castSupplemental in MigrationSpell
    function _validateSupplementalChanges(
        MigrationSpell migrationSpell,
        Root rootV3,
        bool isMainnet,
        uint64 centrifugeId
    ) internal view {
        if (ROOT_V2.code.length > 0) {
            assertEq(Root(ROOT_V2).wards(address(migrationSpell)), 0);
        }

        if (isMainnet) {
            assertEq(IAuth(CFG).wards(address(rootV3)), 1);

            if (centrifugeId != 1) {
                assertEq(IAuth(CFG).wards(CREATE3_PROXY), 0);
            }

            if (centrifugeId == 2) {
                assertEq(IAuth(CFG).wards(WORMHOLE_NTT), 1);
            }
        }

        if (isMainnet && centrifugeId == 1) {
            assertEq(IAuth(WCFG).wards(address(rootV3)), 1);
            assertEq(IAuth(WCFG).wards(WCFG_MULTISIG), 0);
            assertEq(IAuth(WCFG).wards(CHAINBRIDGE_ERC20_HANDLER), 0);
        }
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
}
