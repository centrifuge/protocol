// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {IERC20} from "../../../src/misc/interfaces/IERC20.sol";

import {Root} from "../../../src/admin/Root.sol";

import {EnvConfig, Env} from "../../../script/utils/EnvConfig.s.sol";

import "forge-std/Test.sol";

import { V2CleaningsSpell, ROOT_V2, CONTRACT_UPDATER, FREEZE_ONLY_HOOK, FULL_RESTRICTIONS_HOOK, FREELY_TRANSFERABLE_HOOK, REDEMPTION_RESTRICTIONS_HOOK, CFG, WCFG, WCFG_MULTISIG, CHAINBRIDGE_ERC20_HANDLER, CREATE3_PROXY, IOU_CFG, ETHEREUM_CHAIN_ID, BASE_CHAIN_ID, ARBITRUM_CHAIN_ID, TRANCHE_JAAA, TRANCHE_JTRSY, TREASURY, ESCROW_V2, USDC_ETHEREUM, USDC_BASE, USDC_ARBITRUM } from "../../../src/spell/V2CleaningsSpell.sol";

contract V2CleaningsSpellTest is Test {
    address constant PROTOCOL_GUARDIAN_V3_1 = 0xCEb7eD5d5B3bAD3088f6A1697738B60d829635c6;
    address constant GUARDIAN_V2_ETHEREUM_OR_ARBITRUM = 0x09ab10a9c3E6Eac1d18270a2322B6113F4C7f5E8;
    address constant GUARDIAN_V2_BASE = 0x427A1ce127b1775e4Cbd4F58ad468B9F832eA7e9;
    address constant ROOT_V3_ETH = 0x7Ed48C31f2fdC40d37407cBaBf0870B2b688368f;

    function _testCase(string memory network, string memory rpcUrl) public {
        vm.createSelectFork(rpcUrl);

        EnvConfig memory config = Env.load(network);
        Root rootV3 = Root(config.contracts.root);

        if (block.chainid == ETHEREUM_CHAIN_ID) {
            assertEq(ROOT_V3_ETH, address(rootV3));
        }

        // ----- SPELL DEPLOYMENT -----

        V2CleaningsSpell spell = new V2CleaningsSpell();

        // ----- PRE SPELL -----

        IERC20 usdc = _usdc();
        uint256 preTreasuryValue;
        uint256 preEscrowValue;
        if (address(usdc) != address(0)) {
            preTreasuryValue = usdc.balanceOf(TREASURY);
            preEscrowValue = usdc.balanceOf(ESCROW_V2);
        }

        // ----- REQUIRED RELIES -----

        vm.prank(PROTOCOL_GUARDIAN_V3_1);
        rootV3.rely(address(spell)); // Ideally through guardian.scheduleRely()

        if (address(ROOT_V2).code.length > 0) {
            vm.prank(block.chainid == BASE_CHAIN_ID ? GUARDIAN_V2_BASE : GUARDIAN_V2_ETHEREUM_OR_ARBITRUM);
            ROOT_V2.rely(address(spell)); // Ideally through guardian.scheduleRely()
        }

        // ----- SPELL EXECUTION -----

        spell.cast(rootV3);

        // ----- POST SPELL -----

        if (address(ROOT_V2).code.length > 0) {
            assertEq(ROOT_V2.wards(address(spell)), 0);
        }
        assertEq(rootV3.wards(address(spell)), 0);

        if (CFG.code.length > 0) {
            assertEq(IAuth(CFG).wards(address(rootV3)), 1);
            assertEq(IAuth(CFG).wards(CREATE3_PROXY), 0);
        }

        if (block.chainid == ETHEREUM_CHAIN_ID) {
            assertEq(IAuth(WCFG).wards(address(rootV3)), 1);
            assertEq(IAuth(WCFG).wards(WCFG_MULTISIG), 0);
            assertEq(IAuth(WCFG).wards(CHAINBRIDGE_ERC20_HANDLER), 0);
            assertEq(IAuth(WCFG).wards(address(ROOT_V2)), 0);

            assertEq(IAuth(CFG).wards(address(ROOT_V2)), 0);
            assertEq(IAuth(CFG).wards(IOU_CFG), 0);
        }

        if (TRANCHE_JTRSY.code.length > 0) {
            assertEq(IAuth(TRANCHE_JTRSY).wards(address(rootV3)), 1);
            assertEq(IAuth(TRANCHE_JTRSY).wards(address(ROOT_V2)), 0);
            assertEq(IAuth(TRANCHE_JTRSY).wards(address(spell)), 0);
        }

        if (block.chainid == ETHEREUM_CHAIN_ID || block.chainid == BASE_CHAIN_ID) {
            assertEq(IAuth(TRANCHE_JAAA).wards(address(rootV3)), 1);
            assertEq(IAuth(TRANCHE_JAAA).wards(address(ROOT_V2)), 0);
            assertEq(IAuth(TRANCHE_JAAA).wards(address(spell)), 0);
        }

        if (address(usdc) != address(0)) {
            assertEq(usdc.balanceOf(TREASURY) - preTreasuryValue, preEscrowValue);
            assertEq(usdc.balanceOf(ESCROW_V2), 0);
        }

        if (ESCROW_V2.code.length > 0) {
            assertEq(IAuth(ESCROW_V2).wards(address(spell)), 0);
        }

        assertEq(IAuth(FREEZE_ONLY_HOOK).wards(CONTRACT_UPDATER), 1);
        assertEq(IAuth(FULL_RESTRICTIONS_HOOK).wards(CONTRACT_UPDATER), 1);
        assertEq(IAuth(FREELY_TRANSFERABLE_HOOK).wards(CONTRACT_UPDATER), 1);
        assertEq(IAuth(REDEMPTION_RESTRICTIONS_HOOK).wards(CONTRACT_UPDATER), 1);

        assertTrue(spell.done());
    }

    function _usdc() internal view returns (IERC20 usdc) {
        if (block.chainid == ETHEREUM_CHAIN_ID) {
            usdc = USDC_ETHEREUM;
        } else if (block.chainid == BASE_CHAIN_ID) {
            usdc = USDC_BASE;
        } else if (block.chainid == ARBITRUM_CHAIN_ID) {
            usdc = USDC_ARBITRUM;
        }
    }

    function testV2CleaningsEthereumMainnet() external {
        _testCase("ethereum", string.concat("https://eth-mainnet.g.alchemy.com/v2/", vm.envString("ALCHEMY_API_KEY")));
    }

    function testV2CleaningsBaseMainnet() external {
        _testCase("base", string.concat("https://base-mainnet.g.alchemy.com/v2/", vm.envString("ALCHEMY_API_KEY")));
    }

    function testV2CleaningsArbitrumMainnet() external {
        _testCase("arbitrum", string.concat("https://arb-mainnet.g.alchemy.com/v2/", vm.envString("ALCHEMY_API_KEY")));
    }

    function testV2CleaningsAvalancheMainnet() external {
        _testCase("avalanche", string.concat("https://avax-mainnet.g.alchemy.com/v2/", vm.envString("ALCHEMY_API_KEY")));
    }

    function testV2CleaningsBnbMainnet() external {
        _testCase(
            "bnb-smart-chain", string.concat("https://bnb-mainnet.g.alchemy.com/v2/", vm.envString("ALCHEMY_API_KEY"))
        );
    }

    function testV2CleaningsOptimismMainnet() external {
        _testCase("optimism", string.concat("https://opt-mainnet.g.alchemy.com/v2/", vm.envString("ALCHEMY_API_KEY")));
    }

    function testV2CleaningsHyperEvmMainnet() external {
        _testCase(
            "hyper-evm", string.concat("https://hyperliquid-mainnet.g.alchemy.com/v2/", vm.envString("ALCHEMY_API_KEY"))
        );
    }

    function testV2CleaningsMonadMainnet() external {
        _testCase("monad", string.concat("https://monad-mainnet.g.alchemy.com/v2/", vm.envString("ALCHEMY_API_KEY")));
    }

    function testV2CleaningsPlumeMainnet() external {
        _testCase("plume", string.concat("https://rpc.plume.org/", vm.envString("PLUME_API_KEY")));
    }
}
