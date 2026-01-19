// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../src/misc/interfaces/IAuth.sol";
import {IERC20} from "../../src/misc/interfaces/IERC20.sol";

import "forge-std/Test.sol";

import {V2CleaningsSpell} from "../../src/spell/V2CleaningsSpell.sol";
import {
    V2CleaningsSpell,
    ROOT_V2,
    ROOT_V3,
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
    USDC_ARBITRUM
} from "../../src/spell/V2CleaningsSpell.sol";

contract V2CleaningsSpellTest is Test {
    address constant GUARDIAN_V3 = 0xFEE13c017693a4706391D516ACAbF6789D5c3157;
    address constant GUARDIAN_V2_ETHEREUM_OR_ARBITRUM = 0x09ab10a9c3E6Eac1d18270a2322B6113F4C7f5E8;
    address constant GUARDIAN_V2_BASE = 0x427A1ce127b1775e4Cbd4F58ad468B9F832eA7e9;

    function _testCase(string memory rpcUrl) public {
        vm.createSelectFork(rpcUrl);

        // ----- SPELL DEPLOYMENT -----

        V2CleaningsSpell spell = new V2CleaningsSpell();

        // ----- PRE SPELL -----

        uint256 preTreasuryValue = _usdc().balanceOf(TREASURY);
        uint256 preEscrowValue = _usdc().balanceOf(ESCROW_V2);

        // ----- REQUIRED RELIES -----

        vm.prank(GUARDIAN_V3);
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
        }

        assertEq(IAuth(TRANCHE_JTRSY).wards(address(ROOT_V3)), 1);
        assertEq(IAuth(TRANCHE_JTRSY).wards(address(ROOT_V2)), 0);
        assertEq(IAuth(TRANCHE_JTRSY).wards(address(spell)), 0);

        if (block.chainid == ETHEREUM_CHAIN_ID || block.chainid == BASE_CHAIN_ID) {
            assertEq(IAuth(TRANCHE_JAAA).wards(address(ROOT_V3)), 1);
            assertEq(IAuth(TRANCHE_JAAA).wards(address(ROOT_V2)), 0);
            assertEq(IAuth(TRANCHE_JAAA).wards(address(spell)), 0);
        }

        assertEq(_usdc().balanceOf(TREASURY) - preTreasuryValue, preEscrowValue);
        assertEq(_usdc().balanceOf(ESCROW_V2), 0);

        assertEq(IAuth(ESCROW_V2).wards(address(spell)), 0);

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
        _testCase(string.concat("https://eth-mainnet.g.alchemy.com/v2/", vm.envString("ALCHEMY_API_KEY")));
    }

    function testV2CleaningsBaseMainnet() external {
        _testCase(string.concat("https://base-mainnet.g.alchemy.com/v2/", vm.envString("ALCHEMY_API_KEY")));
    }

    function testV2CleaningsArbitrumMainnet() external {
        _testCase(string.concat("https://arb-mainnet.g.alchemy.com/v2/", vm.envString("ALCHEMY_API_KEY")));
    }
}
