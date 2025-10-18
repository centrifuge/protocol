// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseTestData} from "./BaseTestData.s.sol";

import {ERC20} from "../../src/misc/ERC20.sol";
import {d18} from "../../src/misc/types/D18.sol";
import {CastLib} from "../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {AccountId} from "../../src/core/types/AccountId.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../src/core/types/AssetId.sol";

import {UpdateRestrictionMessageLib} from "../../src/hooks/libraries/UpdateRestrictionMessageLib.sol";

import "forge-std/Script.sol";

// Script to deploy Hub and Vaults with a Localhost Adapter.
contract TestData is BaseTestData {
    using CastLib for *;
    using UpdateRestrictionMessageLib for *;

    address public admin;

    function run() public override {
        string memory network = vm.envString("NETWORK");
        string memory configFile = string.concat("env/", network, ".json");
        string memory config = vm.readFile(configFile);

        uint16 centrifugeId = uint16(vm.parseJsonUint(config, "$.network.centrifugeId"));

        admin = vm.envAddress("PROTOCOL_ADMIN");
        loadContractsFromConfig(config);

        vm.startBroadcast();

        // Deploy and register test USDC
        ERC20 token = new ERC20(6);
        token.file("name", "USD Coin");
        token.file("symbol", "USDC");
        token.mint(msg.sender, 10_000_000e6);
        spoke.registerAsset(centrifugeId, address(token), 0, msg.sender);
        AssetId assetId = newAssetId(centrifugeId, 1);

        // Deploy async vault and perform full test flow
        (PoolId asyncPoolId, ShareClassId asyncScId) = deployAsyncVault(
            AsyncVaultParams({
                targetCentrifugeId: centrifugeId,
                poolIndex: 1,
                token: token,
                assetId: assetId,
                admin: admin,
                poolMetadata: "Testing pool",
                shareClassName: "Tokenized MMF",
                shareClassSymbol: "MMF",
                shareClassMeta: bytes32(bytes("1"))
            })
        );

        testAsyncVaultFlow(asyncPoolId, asyncScId, assetId, token, centrifugeId);

        // Additional wBTC testing
        ERC20 wBtc = new ERC20(18);
        wBtc.file("name", "Wrapped Bitcoin");
        wBtc.file("symbol", "wBTC");
        wBtc.mint(msg.sender, 10_000_000e18);
        spoke.registerAsset(centrifugeId, address(wBtc), 0, msg.sender);
        AssetId wBtcId = newAssetId(centrifugeId, 2);

        wBtc.approve(address(balanceSheet), 10e18);

        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeWithSelector(
            balanceSheet.overridePricePoolPerAsset.selector, asyncPoolId, asyncScId, wBtcId, d18(100_000, 1)
        );
        calls[1] =
            abi.encodeWithSelector(balanceSheet.deposit.selector, asyncPoolId, asyncScId, address(wBtc), 0, 10e18);
        calls[2] = abi.encodeWithSelector(
            balanceSheet.submitQueuedAssets.selector, asyncPoolId, asyncScId, wBtcId, DEFAULT_EXTRA_GAS, msg.sender
        );
        balanceSheet.multicall(calls);

        hub.createAccount(asyncPoolId, AccountId.wrap(0x05), true);
        hub.initializeHolding(
            asyncPoolId,
            asyncScId,
            wBtcId,
            identityValuation,
            AccountId.wrap(0x05),
            AccountId.wrap(0x02),
            AccountId.wrap(0x03),
            AccountId.wrap(0x04)
        );
        hub.updateHoldingValue(asyncPoolId, asyncScId, wBtcId);

        // Deploy sync vault and perform test
        (PoolId syncPoolId, ShareClassId syncScId) = deploySyncDepositVault(
            SyncVaultParams({
                targetCentrifugeId: centrifugeId,
                poolIndex: 2,
                token: token,
                assetId: assetId,
                admin: admin,
                poolMetadata: "Testing pool",
                shareClassName: "RWA Portfolio",
                shareClassSymbol: "RWA",
                shareClassMeta: bytes32(bytes("2"))
            })
        );

        testSyncVaultFlow(syncPoolId, syncScId, token, 1_000_000e6);

        vm.stopBroadcast();
    }
}
