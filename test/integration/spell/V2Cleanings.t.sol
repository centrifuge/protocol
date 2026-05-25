// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {IERC20} from "../../../src/misc/interfaces/IERC20.sol";

import {EnvConfig, Env} from "../../../script/utils/EnvConfig.s.sol";

import "forge-std/Test.sol";

import {
    V2CleaningsSpell,
    ROOT_V2,
    ROOT_V3,
    CONTRACT_UPDATER,
    FREEZE_ONLY_HOOK,
    FULL_RESTRICTIONS_HOOK,
    FREELY_TRANSFERABLE_HOOK,
    REDEMPTION_RESTRICTIONS_HOOK,
    CFG,
    WCFG,
    WCFG_MULTISIG,
    CHAINBRIDGE_ERC20_HANDLER,
    CREATE3_PROXY,
    IOU_CFG,
    ETHEREUM_CHAIN_ID,
    BASE_CHAIN_ID,
    ARBITRUM_CHAIN_ID,
    TRANCHE_JAAA,
    TRANCHE_JTRSY,
    TREASURY,
    ESCROW_V2,
    USDC_ETHEREUM,
    USDC_BASE,
    USDC_ARBITRUM,
    CNF_TREASURY_WALLET,
    CENTRIFUGE_CHAIN_CFG_AMOUNT,
    ETH_V2_JTRSY_VAULT,
    ETH_V2_JAAA_VAULT,
    BASE_V2_JTRSY_VAULT,
    BASE_V2_JAAA_VAULT,
    ARB_V2_JTRSY_VAULT
} from "../../../src/spell/V2CleaningsSpell.sol";

contract V2CleaningsSpellTest is Test {
    address constant PROTOCOL_GUARDIAN_V3_1 = 0xCEb7eD5d5B3bAD3088f6A1697738B60d829635c6;
    address constant GUARDIAN_V2_ETHEREUM_OR_ARBITRUM = 0x09ab10a9c3E6Eac1d18270a2322B6113F4C7f5E8;
    address constant GUARDIAN_V2_BASE = 0x427A1ce127b1775e4Cbd4F58ad468B9F832eA7e9;

    uint256 constant MAX_POST_MINT_CFG_SUPPLY = 692_049_712_426_095_885_688_933_007;

    function _testCase(string memory network, string memory rpcUrl) public {
        vm.createSelectFork(rpcUrl);

        EnvConfig memory config = Env.load(network);

        // Sanity-check the spell's hardcoded ROOT_V3 matches the env file for this chain.
        assertEq(
            config.contracts.root, address(ROOT_V3), "Env ROOT_V3 differs from spell-hardcoded ROOT_V3 for this chain"
        );

        // ----- SPELL DEPLOYMENT -----

        V2CleaningsSpell spell = new V2CleaningsSpell();

        // ----- PRE SPELL -----

        uint256 preCfgTotalSupply = IERC20(CFG).totalSupply();
        uint256 preCfgMintTreasuryBalance = IERC20(CFG).balanceOf(CNF_TREASURY_WALLET);
        uint256 preWcfgTotalSupply = block.chainid == ETHEREUM_CHAIN_ID ? IERC20(WCFG).totalSupply() : 0;
        uint256 preWcfgBalanceOfIouCfg = block.chainid == ETHEREUM_CHAIN_ID ? IERC20(WCFG).balanceOf(IOU_CFG) : 0;

        IERC20 usdc = _usdc();
        uint256 preTreasuryValue = usdc.balanceOf(TREASURY);
        uint256 preEscrowValue = usdc.balanceOf(ESCROW_V2);

        // Verify vault ward pre-conditions so wrong constants don't silently pass post-assertions
        if (block.chainid == ETHEREUM_CHAIN_ID) {
            assertEq(IAuth(TRANCHE_JTRSY).wards(ETH_V2_JTRSY_VAULT), 1, "JTRSY vault not pre-relied");
            assertEq(IAuth(TRANCHE_JAAA).wards(ETH_V2_JAAA_VAULT), 1, "JAAA vault not pre-relied");
        } else if (block.chainid == BASE_CHAIN_ID) {
            assertEq(IAuth(TRANCHE_JTRSY).wards(BASE_V2_JTRSY_VAULT), 1, "JTRSY vault not pre-relied");
            assertEq(IAuth(TRANCHE_JAAA).wards(BASE_V2_JAAA_VAULT), 1, "JAAA vault not pre-relied");
        } else if (block.chainid == ARBITRUM_CHAIN_ID) {
            assertEq(IAuth(TRANCHE_JTRSY).wards(ARB_V2_JTRSY_VAULT), 1, "JTRSY vault not pre-relied");
        }

        // Verify ROOT_V2 ward pre-conditions so the _denyV2FromShareToken guard can't silently short-circuit
        assertEq(IAuth(TRANCHE_JTRSY).wards(address(ROOT_V2)), 1, "ROOT_V2 not pre-relied on JTRSY");
        if (block.chainid == ETHEREUM_CHAIN_ID || block.chainid == BASE_CHAIN_ID) {
            assertEq(IAuth(TRANCHE_JAAA).wards(address(ROOT_V2)), 1, "ROOT_V2 not pre-relied on JAAA");
        }

        // ----- REQUIRED RELIES -----

        vm.prank(PROTOCOL_GUARDIAN_V3_1);
        ROOT_V3.rely(address(spell)); // Ideally through guardian.scheduleRely()

        vm.prank(block.chainid == BASE_CHAIN_ID ? GUARDIAN_V2_BASE : GUARDIAN_V2_ETHEREUM_OR_ARBITRUM);
        ROOT_V2.rely(address(spell)); // Ideally through guardian.scheduleRely()

        // ----- SPELL EXECUTION -----

        spell.cast();

        // ----- POST SPELL -----

        assertEq(ROOT_V2.wards(address(spell)), 0);
        assertEq(ROOT_V3.wards(address(spell)), 0);

        assertEq(IAuth(CFG).wards(address(ROOT_V3)), 1);
        assertEq(IAuth(CFG).wards(CREATE3_PROXY), 0);

        if (block.chainid == ETHEREUM_CHAIN_ID) {
            assertEq(IAuth(WCFG).wards(address(ROOT_V3)), 1);
            assertEq(IAuth(WCFG).wards(WCFG_MULTISIG), 0);
            assertEq(IAuth(WCFG).wards(CHAINBRIDGE_ERC20_HANDLER), 0);
            assertEq(IAuth(WCFG).wards(address(ROOT_V2)), 0);

            assertEq(IAuth(CFG).wards(address(ROOT_V2)), 0);
            assertEq(IAuth(CFG).wards(IOU_CFG), 0);

            // CFG minting assertions
            uint256 expectedMintAmount = preWcfgTotalSupply - preWcfgBalanceOfIouCfg + CENTRIFUGE_CHAIN_CFG_AMOUNT;
            assertEq(IERC20(CFG).totalSupply(), preCfgTotalSupply + expectedMintAmount);
            assertEq(IERC20(CFG).totalSupply(), MAX_POST_MINT_CFG_SUPPLY, "Total CFG supply exceeds max post-mint cap");
            assertEq(IERC20(CFG).balanceOf(CNF_TREASURY_WALLET), preCfgMintTreasuryBalance + expectedMintAmount);
            assertEq(IAuth(CFG).wards(address(spell)), 0);
        }

        assertEq(IAuth(TRANCHE_JTRSY).wards(address(ROOT_V3)), 1);
        assertEq(IAuth(TRANCHE_JTRSY).wards(address(ROOT_V2)), 0);
        assertEq(IAuth(TRANCHE_JTRSY).wards(address(spell)), 0);

        if (block.chainid == ETHEREUM_CHAIN_ID) {
            assertEq(IAuth(TRANCHE_JTRSY).wards(ETH_V2_JTRSY_VAULT), 0);
        } else if (block.chainid == BASE_CHAIN_ID) {
            assertEq(IAuth(TRANCHE_JTRSY).wards(BASE_V2_JTRSY_VAULT), 0);
        } else if (block.chainid == ARBITRUM_CHAIN_ID) {
            assertEq(IAuth(TRANCHE_JTRSY).wards(ARB_V2_JTRSY_VAULT), 0);
        }

        if (block.chainid == ETHEREUM_CHAIN_ID || block.chainid == BASE_CHAIN_ID) {
            assertEq(IAuth(TRANCHE_JAAA).wards(address(ROOT_V3)), 1);
            assertEq(IAuth(TRANCHE_JAAA).wards(address(ROOT_V2)), 0);
            assertEq(IAuth(TRANCHE_JAAA).wards(address(spell)), 0);
        }

        if (block.chainid == ETHEREUM_CHAIN_ID) {
            assertEq(IAuth(TRANCHE_JAAA).wards(ETH_V2_JAAA_VAULT), 0);
        } else if (block.chainid == BASE_CHAIN_ID) {
            assertEq(IAuth(TRANCHE_JAAA).wards(BASE_V2_JAAA_VAULT), 0);
        }

        assertEq(usdc.balanceOf(TREASURY) - preTreasuryValue, preEscrowValue);
        assertEq(usdc.balanceOf(ESCROW_V2), 0);
        assertEq(IAuth(ESCROW_V2).wards(address(spell)), 0);

        assertEq(IAuth(FREEZE_ONLY_HOOK).wards(CONTRACT_UPDATER), 1);
        assertEq(IAuth(FULL_RESTRICTIONS_HOOK).wards(CONTRACT_UPDATER), 1);
        assertEq(IAuth(FREELY_TRANSFERABLE_HOOK).wards(CONTRACT_UPDATER), 1);
        assertEq(IAuth(REDEMPTION_RESTRICTIONS_HOOK).wards(CONTRACT_UPDATER), 1);

        assertTrue(spell.done());
    }

    function _usdc() internal view returns (IERC20) {
        if (block.chainid == ETHEREUM_CHAIN_ID) return USDC_ETHEREUM;
        if (block.chainid == BASE_CHAIN_ID) return USDC_BASE;
        return USDC_ARBITRUM;
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
}
