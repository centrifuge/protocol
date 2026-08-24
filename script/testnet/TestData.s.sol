// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseTestData} from "./BaseTestData.s.sol";

import {ERC20} from "../../src/misc/ERC20.sol";
import {CastLib} from "../../src/misc/libraries/CastLib.sol";

import {AccountId} from "../../src/core/types/AccountId.sol";
import {PoolId, newPoolId} from "../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../src/core/types/AssetId.sol";

import {UpdateRestrictionMessageLib} from "../../src/token/hooks/libraries/UpdateRestrictionMessageLib.sol";

import "forge-std/Script.sol";

import {Env, EnvConfig} from "../utils/EnvConfig.s.sol";

// Script to deploy Hub and Vaults with a Localhost Adapter.
contract TestData is BaseTestData {
    using CastLib for *;
    using UpdateRestrictionMessageLib for *;

    function run() public override {
        EnvConfig memory config = Env.load();
        uint16 centrifugeId = config.chain.network.centrifugeId;
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
                admin: config.chain.network.protocolAdmin,
                poolMetadata: "Testing pool",
                shareClassName: "Tokenized MMF",
                shareClassSymbol: "MMF",
                shareClassMeta: bytes32(bytes8(newPoolId(centrifugeId, 1).raw()))
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

        wBtc.approve(address(spoke), 10e18);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(spoke.deposit.selector, asyncPoolId, asyncScId, address(wBtc), 0, 10e18);
        calls[1] = abi.encodeWithSelector(
            spoke.submitQueuedAssets.selector, asyncPoolId, asyncScId, wBtcId, DEFAULT_EXTRA_GAS, msg.sender
        );
        spoke.multicall(calls);

        hub.createAccount(asyncPoolId, AccountId.wrap(0x05), true);
        hub.initializeHolding(
            asyncPoolId,
            asyncScId,
            wBtcId,
            identityValuation,
            _holdingAccounts(AccountId.wrap(0x05), AccountId.wrap(0x02), AccountId.wrap(0x03), AccountId.wrap(0x04))
        );
        hub.updateHoldingValue(asyncPoolId, asyncScId, wBtcId);

        // Deploy sync vault and perform test
        (PoolId syncPoolId, ShareClassId syncScId) = deploySyncDepositVault(
            SyncVaultParams({
                targetCentrifugeId: centrifugeId,
                poolIndex: 2,
                token: token,
                assetId: assetId,
                admin: config.chain.network.protocolAdmin,
                poolMetadata: "Testing pool",
                shareClassName: "RWA Portfolio",
                shareClassSymbol: "RWA",
                shareClassMeta: bytes32(bytes8(newPoolId(centrifugeId, 2).raw()))
            })
        );

        testSyncVaultFlow(syncPoolId, syncScId, token, 1_000_000e6);

        vm.stopBroadcast();
    }
}
