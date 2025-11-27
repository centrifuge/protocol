// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {MessageDispatcher} from "../../../src/core/messaging/MessageDispatcher.sol";

import {Root} from "../../../src/admin/Root.sol";
import {ISafe} from "../../../src/admin/interfaces/ISafe.sol";

import {MigrationV3_1Executor} from "../../../script/spell/MigrationV3_1.s.sol";
import {
    FullActionBatcher,
    FullDeployer,
    FullInput,
    noAdaptersInput,
    defaultBlockLimits,
    CoreInput
} from "../../../script/FullDeployer.s.sol";

import "forge-std/Test.sol";

import {ForkTestLiveValidation} from "../../integration/fork/ForkTestLiveValidation.sol";
import {
    MigrationSpell,
    PoolMigrationOldContracts,
    GlobalMigrationOldContracts
} from "../../../src/spell/migration_v3.1/MigrationSpell.sol";

interface MessageDispatcherV3Like {
    function root() external view returns (Root root);
}

contract MigrationV3_1Test is Test {
    address constant PRODUCTION_MESSAGE_DISPATCHER_V3 = 0x21AF0C29611CFAaFf9271C8a3F84F2bC31d59132;
    address constant TESTNET_MESSAGE_DISPATCHER_V3 = 0x332bE89CAB9FF501F5EBe3f6DC9487bfF50Bd0BF;

    ISafe immutable ADMIN = ISafe(makeAddr("ADMIN"));
    bytes32 constant NEW_VERSION = "v3.1";
    PoolId[] poolsToMigrate;

    function _testCase(string memory rpcUrl, bool isProduction) public {
        vm.createSelectFork(rpcUrl);

        address rootWard = isProduction ? PRODUCTION_MESSAGE_DISPATCHER_V3 : TESTNET_MESSAGE_DISPATCHER_V3;
        uint16 localCentrifugeId = MessageDispatcher(rootWard).localCentrifugeId();
        Root rootV3 = MessageDispatcherV3Like(rootWard).root();

        if (isProduction) {
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
                    centrifugeId: localCentrifugeId,
                    version: NEW_VERSION,
                    root: address(rootV3),
                    blockLimits: defaultBlockLimits()
                }),
                adminSafe: ADMIN,
                opsSafe: ADMIN,
                adapters: noAdaptersInput()
            }),
            batcher
        );

        // ----- SPELL DEPLOYMENT -----

        MigrationV3_1Executor migration = new MigrationV3_1Executor(isProduction);
        MigrationSpell migrationSpell = new MigrationSpell(address(migration));

        // ----- LABELLING -----

        vm.label(address(rootWard), "v3.messageDispatcher");
        vm.label(address(deployer), "deployer");
        vm.label(address(batcher), "batcher");
        vm.label(address(migration), "migration");

        // ----- PRE_CHECK -----

        _validateV3_1Deployment(deployer, true, isProduction);

        // ----- MIGRATION -----

        vm.prank(rootWard);
        rootV3.rely(address(migrationSpell)); // Ideally through guardian.scheduleRely()

        migration.migrate(address(deployer), migrationSpell, poolsToMigrate);

        // ----- POST_CHECK -----

        assertEq(migrationSpell.owner(), address(0));

        _validateV3_1Deployment(deployer, false, isProduction);

        // TODO: Complete post checks
    }

    /// @notice Validate v3.1 deployment permissions and configuration
    /// @param preMigration If true, skips validations that only apply post-migration
    /// @param isProduction If true, validates production vaults. Set to false for testnets.
    function _validateV3_1Deployment(FullDeployer deployer, bool preMigration, bool isProduction) internal {
        console.log(
            "[DEBUG] Starting deployment validation: preMigration=%s, isProduction=%s", preMigration, isProduction
        );
        ForkTestLiveValidation validator = new ForkTestLiveValidation();
        validator._loadContractsFromDeployer(deployer);
        validator.validateDeployment(preMigration, isProduction);
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
