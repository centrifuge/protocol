// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MessageDispatcher} from "../../../src/core/messaging/MessageDispatcher.sol";

import {ISafe} from "../../../src/admin/interfaces/ISafe.sol";

import {
    FullActionBatcher,
    FullDeployer,
    FullInput,
    noAdaptersInput,
    CoreInput
} from "../../../script/FullDeployer.s.sol";
import {
    MigrationV3_1,
    ROOT_V3,
    MESSAGE_DISPATCHER_V3 as ROOT_WARD,
    MESSAGE_DISPATCHER_V3,
    GATEWAY_V3,
    HUB_REGISTRY_V3,
    SHARE_CLASS_MANAGER_V3,
    BALANCE_SHEET_V3,
    SPOKE_V3,
    ASYNC_VAULT_FACTORY_V3,
    SYNC_DEPOSIT_VAULT_FACTORY_V3,
    SYNC_MANAGER_V3,
    FREEZE_ONLY_HOOK_V3,
    FULL_RESTRICTIONS_HOOK_V3,
    FREELY_TRANSFERABLE_HOOK_V3,
    REDEMPTION_RESTRICTIONS_HOOK_V3
} from "../../../script/spell/MigrationV3_1.s.sol";

import "forge-std/Test.sol";

import {PoolMigrationSpell} from "../../../src/spell/migration_v3.1/PoolMigrationSpell.sol";
import {GeneralMigrationSpell} from "../../../src/spell/migration_v3.1/GeneralMigrationSpell.sol";

contract MigrationV3_1Test is Test {
    ISafe immutable ADMIN = ISafe(makeAddr("ADMIN"));
    bytes32 constant VERSION = "3.1";

    function setUp() external {
        vm.label(address(GATEWAY_V3), "v3.gateway");
        vm.label(address(HUB_REGISTRY_V3), "v3.hubRegistry");
        vm.label(address(SHARE_CLASS_MANAGER_V3), "v3.shareClassManager");
        vm.label(address(BALANCE_SHEET_V3), "v3.balanceSheet");
        vm.label(address(SPOKE_V3), "v3.spoke");
        vm.label(address(ASYNC_VAULT_FACTORY_V3), "v3.asyncVaultFactory");
        vm.label(address(SYNC_DEPOSIT_VAULT_FACTORY_V3), "v3.syncDepositVaultFactory");
        vm.label(address(SYNC_MANAGER_V3), "v3.syncManager");
        vm.label(address(FREEZE_ONLY_HOOK_V3), "v3.freezeOnly");
        vm.label(address(FULL_RESTRICTIONS_HOOK_V3), "v3.fullRestrictions");
        vm.label(address(FREELY_TRANSFERABLE_HOOK_V3), "v3.freelyTransferable");
        vm.label(address(REDEMPTION_RESTRICTIONS_HOOK_V3), "v3.redemptionRestrictions");
        vm.label(address(MESSAGE_DISPATCHER_V3), "v3.messageDispatcher");
    }

    function _deployV3_1() public returns (address) {
        uint16 localCentrifugeId = MessageDispatcher(MESSAGE_DISPATCHER_V3).localCentrifugeId();

        FullDeployer deployer = new FullDeployer();
        FullActionBatcher batcher = new FullActionBatcher(address(deployer));

        deployer.labelAddresses("");

        vm.prank(ROOT_WARD);
        ROOT_V3.rely(address(batcher)); // Ideally through guardian.scheduleRely()

        deployer.deployFull(
            FullInput({
                core: CoreInput({centrifugeId: localCentrifugeId, version: VERSION, root: address(ROOT_V3)}),
                adminSafe: ADMIN,
                opsSafe: ADMIN,
                adapters: noAdaptersInput()
            }),
            batcher
        );

        vm.label(address(deployer), "deployer");
        vm.label(address(batcher), "batcher");

        return address(deployer);
    }

    function _testCase(string memory rpcUrl) public {
        vm.createSelectFork(rpcUrl);

        address deployer = _deployV3_1();

        MigrationV3_1 migration = new MigrationV3_1(deployer);
        GeneralMigrationSpell generalMigrationSpell = new GeneralMigrationSpell(address(migration));
        PoolMigrationSpell poolMigrationSpell = new PoolMigrationSpell(address(migration));

        vm.prank(ROOT_WARD);
        ROOT_V3.rely(address(generalMigrationSpell)); // Ideally through guardian.scheduleRely()
        vm.prank(ROOT_WARD);
        ROOT_V3.rely(address(poolMigrationSpell)); // Ideally through guardian.scheduleRely()

        vm.label(address(migration), "migration");
        vm.label(address(generalMigrationSpell), "generalMigrationSpell");
        vm.label(address(poolMigrationSpell), "poolMigrationSpell");

        migration.migrate(generalMigrationSpell, poolMigrationSpell);

        assertEq(generalMigrationSpell.owner(), address(0));
        assertEq(poolMigrationSpell.owner(), address(0));

        // TODO: Do some post-check
    }

    function testMigrationEthereum() external {
        _testCase(string.concat("https://eth-mainnet.g.alchemy.com/v2/", vm.envString("ALCHEMY_API_KEY")));
    }

    function testMigrationBase() external {
        _testCase(string.concat("https://base-mainnet.g.alchemy.com/v2/", vm.envString("ALCHEMY_API_KEY")));
    }

    function testMigrationArbitrum() external {
        _testCase(string.concat("https://arb-mainnet.g.alchemy.com/v2/", vm.envString("ALCHEMY_API_KEY")));
    }

    function testMigrationAvalanche() external {
        _testCase(string.concat("https://avax-mainnet.g.alchemy.com/v2/", vm.envString("ALCHEMY_API_KEY")));
    }

    function testMigrationBNB() external {
        _testCase(string.concat("https://bnb-mainnet.g.alchemy.com/v2/", vm.envString("ALCHEMY_API_KEY")));
    }

    function testMigrationPlume() external {
        _testCase(string.concat("https://rpc.plume.org/", vm.envString("PLUME_API_KEY")));
    }
}
