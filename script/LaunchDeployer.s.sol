// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CoreInput} from "./CoreDeployer.s.sol";
import {
    FullInput,
    FullActionBatcher,
    FullDeployer,
    AdaptersInput,
    WormholeInput,
    AxelarInput,
    LayerZeroInput
} from "./FullDeployer.s.sol";

import {CastLib} from "../src/misc/libraries/CastLib.sol";

import {ISafe} from "../src/admin/interfaces/ISafe.sol";

import "forge-std/Script.sol";

contract LaunchDeployer is FullDeployer {
    using CastLib for *;

    function run() public virtual {
        vm.startBroadcast();

        string memory network;
        string memory config;
        try vm.envString("NETWORK") returns (string memory _network) {
            network = _network;
            string memory configFile = string.concat("env/", network, ".json");
            config = vm.readFile(configFile);
        } catch {
            console.log("NETWORK environment variable is not set, this must be a mocked test");
            revert("NETWORK environment variable is required");
        }

        uint16 centrifugeId = uint16(vm.parseJsonUint(config, "$.network.centrifugeId"));
        string memory environment = vm.parseJsonString(config, "$.network.environment");

        console.log("Network:", network);
        console.log("Environment:", environment);

        bytes32 version = vm.envOr("VERSION", string("")).toBytes32();
        console.log("Version:", version.toString());
        console.log("\n\n---------\n\nStarting deployment for chain ID: %s\n\n", vm.toString(block.chainid));

        startDeploymentOutput();

        FullInput memory input = FullInput({
            adminSafe: ISafe(vm.envAddress("PROTOCOL_ADMIN")),
            opsSafe: ISafe(vm.envAddress("OPS_ADMIN")),
            core: CoreInput({centrifugeId: centrifugeId, version: version, root: address(0)}),
            adapters: AdaptersInput({
                wormhole: WormholeInput({
                    shouldDeploy: _parseJsonBoolOrDefault(config, "$.adapters.wormhole.deploy"),
                    relayer: _parseJsonAddressOrDefault(config, "$.adapters.wormhole.relayer")
                }),
                axelar: AxelarInput({
                    shouldDeploy: _parseJsonBoolOrDefault(config, "$.adapters.axelar.deploy"),
                    gateway: _parseJsonAddressOrDefault(config, "$.adapters.axelar.gateway"),
                    gasService: _parseJsonAddressOrDefault(config, "$.adapters.axelar.gasService")
                }),
                layerZero: LayerZeroInput({
                    shouldDeploy: _parseJsonBoolOrDefault(config, "$.adapters.layerZero.deploy"),
                    endpoint: _parseJsonAddressOrDefault(config, "$.adapters.layerZero.endpoint"),
                    delegate: vm.envAddress("PROTOCOL_ADMIN")
                })
            })
        });

        FullActionBatcher batcher = new FullActionBatcher();

        // Cache version hash to avoid redundant hash recalculation
        if (input.core.version == "3.1") _verifyAdmin(input.adminSafe);

        address protocolAdminEnv = vm.envAddress("PROTOCOL_ADMIN");
        require(protocolAdminEnv != address(0), "PROTOCOL_ADMIN not set");

        deployFull(input, batcher);

        removeFullDeployerAccess(batcher);

        batcher.lock();

        if (input.core.version == "3.1") _verifyMainnetAddresses();

        saveDeploymentOutput();

        vm.stopBroadcast();
    }

    function _parseJsonBoolOrDefault(string memory config, string memory path) private pure returns (bool) {
        try vm.parseJsonBool(config, path) returns (bool value) {
            return value;
        } catch {
            return false;
        }
    }

    function _parseJsonAddressOrDefault(string memory config, string memory path) private pure returns (address) {
        try vm.parseJsonAddress(config, path) returns (address value) {
            return value;
        } catch {
            return address(0);
        }
    }

    function _isSafeOwner(ISafe safe, address addr) internal view returns (bool) {
        try safe.isOwner(addr) returns (bool isOwner) {
            return isOwner;
        } catch {
            return false;
        }
    }

    function _verifyAdmin(ISafe adminSafe) internal view {
        require(
            _isSafeOwner(adminSafe, 0x4d47a7a89478745200Bd51c26bA87664538Df541), "Admin 0x4d47...f541 not a safe owner"
        );
        require(
            _isSafeOwner(adminSafe, 0xc599bb54E3BFb6393c7feAf0EC97a947753aC0c8), "Admin 0xc599...c0c8 not a safe owner"
        );
        require(
            _isSafeOwner(adminSafe, 0xE9441B34f71659cCA2bfE90d98ee0e57D9CAD28F), "Admin 0xE944...d28F not a safe owner"
        );
        require(
            _isSafeOwner(adminSafe, 0x5e7A86178252Aeae9cBDa30f9C342c71799A3EE1), "Admin 0x5e7A...3EE1 not a safe owner"
        );
        require(
            _isSafeOwner(adminSafe, 0x9eDec77dd2651Ce062ab17e941347018AD4eAEA9), "Admin 0x9eDe...eAA9 not a safe owner"
        );
        require(
            _isSafeOwner(adminSafe, 0xd55114BfE98a2ca16202Aa741BeE571765292616), "Admin 0xd551...2616 not a safe owner"
        );
        require(
            _isSafeOwner(adminSafe, 0x790c2c860DDC993f3da92B19cB440cF8338C59a6), "Admin 0x790c...59a6 not a safe owner"
        );
        require(
            _isSafeOwner(adminSafe, 0xc4576CE4603552c5BeAa056c449b0795D48fcf92), "Admin 0xc457...cf92 not a safe owner"
        );
    }

    /**
     * @dev Verifies that deployed contract addresses match the documented mainnet addresses
     * These addresses must align with official documentation and deployment records
     */
    function _verifyMainnetAddresses() internal view {
        require(address(root) == 0x7Ed48C31f2fdC40d37407cBaBf0870B2b688368f, "Root address mismatch with mainnet");
        require(
            address(protocolGuardian) == 0xFEE13c017693a4706391D516ACAbF6789D5c3157,
            "ProtocolGuardian address mismatch with mainnet"
        );
        require(
            address(opsGuardian) == 0xFEE13c017693a4706391D516ACAbF6789D5c3157,
            "OpsGuardian address mismatch with mainnet"
        );
        require(
            address(gasService) == 0x295262f96186505Ce67c67B9d29e36ad1f9EAe88,
            "GasService address mismatch with mainnet"
        );
        require(address(gateway) == 0x51eA340B3fe9059B48f935D5A80e127d587B6f89, "Gateway address mismatch with mainnet");
        require(
            address(multiAdapter) == 0x457C91384C984b1659157160e8543adb12BC5317,
            "MultiAdapter address mismatch with mainnet"
        );
        require(
            address(messageProcessor) == 0xE994149c6D00Fe8708f843dc73973D1E7205530d,
            "MessageProcessor address mismatch with mainnet"
        );
        require(
            address(messageDispatcher) == 0x21AF0C29611CFAaFf9271C8a3F84F2bC31d59132,
            "MessageDispatcher address mismatch with mainnet"
        );
        require(
            address(poolEscrowFactory) == 0xD166B3210edBeEdEa73c7b2e8aB64BDd30c980E9,
            "PoolEscrowFactory address mismatch with mainnet"
        );
        require(
            address(tokenRecoverer) == 0x94269dBaBA605b63321221679df1356be0c00E63,
            "TokenRecoverer address mismatch with mainnet"
        );
        require(
            address(hubRegistry) == 0x12044ef361Cc3446Cb7d36541C8411EE4e6f52cb,
            "HubRegistry address mismatch with mainnet"
        );
        require(
            address(accounting) == 0xE999a426D92c30fEE4f074B3a53071A6e935419F,
            "Accounting address mismatch with mainnet"
        );
        require(
            address(holdings) == 0x0261FA29b3F2784AF17874428b58d971b6652C47, "Holdings address mismatch with mainnet"
        );
        require(
            address(shareClassManager) == 0xe88e712d60bfd23048Dbc677FEb44E2145F2cDf4,
            "ShareClassManager address mismatch with mainnet"
        );
        require(
            address(hubHandler) == 0xA30D9E76a80675A719d835a74d09683AD2CB71EE,
            "HubHandler address mismatch with mainnet"
        );
        require(address(hub) == 0x9c8454A506263549f07c80698E276e3622077098, "Hub address mismatch with mainnet");
        require(
            address(tokenFactory) == 0xC8eDca090b772C48BcE5Ae14Eb7dd517cd70A32C,
            "TokenFactory address mismatch with mainnet"
        );
        require(address(spoke) == 0xd30Da1d7F964E5f6C2D9fE2AAA97517F6B23FA2B, "Spoke address mismatch with mainnet");
        require(
            address(balanceSheet) == 0xBcC8D02d409e439D98453C0b1ffa398dFFb31fda,
            "BalanceSheet address mismatch with mainnet"
        );
        require(
            address(contractUpdater) == 0x8dD5a3d4e9ec54388dAd23B8a1f3B2159B2f2D85,
            "ContractUpdater address mismatch with mainnet"
        );
        require(
            address(routerEscrow) == 0xB86B6AE94E6d05AAc086665534A73fee557EE9F6,
            "RouterEscrow address mismatch with mainnet"
        );
        require(
            address(globalEscrow) == 0x43d51be0B6dE2199A2396bA604114d24383F91E9,
            "GlobalEscrow address mismatch with mainnet"
        );
        require(
            address(asyncRequestManager) == 0xf06f89A1b6C601235729A689595571B7455Dd433,
            "AsyncRequestManager address mismatch with mainnet"
        );
        require(
            address(syncManager) == 0x0D82d9fa76CFCd6F4cc59F053b2458665C6CE773,
            "SyncManager address mismatch with mainnet"
        );
        require(
            address(asyncVaultFactory) == 0xb47E57b4D477FF80c42dB8B02CB5cb1a74b5D20a,
            "AsyncVaultFactory address mismatch with mainnet"
        );
        require(
            address(syncDepositVaultFactory) == 0x00E3c7EE9Bbc98B9Cb4Cc2c06fb211c1Bb199Ee5,
            "SyncDepositVaultFactory address mismatch with mainnet"
        );
        require(
            address(vaultRouter) == 0xdbCcee499563D4AC2D3788DeD3acb14FB92B175D,
            "VaultRouter address mismatch with mainnet"
        );
        require(
            address(freezeOnlyHook) == 0xBb7ABFB0E62dfb36e02CeeCDA59ADFD71f50c88e,
            "FreezeOnlyHook address mismatch with mainnet"
        );
        require(
            address(fullRestrictionsHook) == 0xa2C98F0F76Da0C97039688CA6280d082942d0b48,
            "FullRestrictionsHook address mismatch with mainnet"
        );
        require(
            address(freelyTransferableHook) == 0xbce8C1f411484C28a64f7A6e3fA63C56b6f3dDDE,
            "FreelyTransferableHook address mismatch with mainnet"
        );
        require(
            address(redemptionRestrictionsHook) == 0xf0C36EFD5F6465D18B9679ee1407a3FC9A2955dD,
            "RedemptionRestrictionsHook address mismatch with mainnet"
        );
        require(
            address(onOfframpManagerFactory) == 0xcb084F79e8AE54e1373130F4F7119214FCe972a9,
            "OnOfframpManagerFactory address mismatch with mainnet"
        );
        require(
            address(merkleProofManagerFactory) == 0xaBd3cDc17C15a9E7771876cE24aB10A8E722781d,
            "MerkleProofManagerFactory address mismatch with mainnet"
        );
        require(
            address(vaultDecoder) == 0x72B188c37bD8Eb002d0D9c63CCd77F2Ff71d272e,
            "VaultDecoder address mismatch with mainnet"
        );
        require(
            address(circleDecoder) == 0x6fce63E718fED6E20bAa8179e313C24cbF2EDa24,
            "CircleDecoder address mismatch with mainnet"
        );
        require(
            address(identityValuation) == 0x3b8FaE903a6511f9707A2f45747a0de3B747711f,
            "IdentityValuation address mismatch with mainnet"
        );
    }
}
