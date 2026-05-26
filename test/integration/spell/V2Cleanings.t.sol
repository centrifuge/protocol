// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {SpellForkTest} from "./utils/SpellForkTest.sol";

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {IERC20} from "../../../src/misc/interfaces/IERC20.sol";

import {Root} from "../../../src/admin/Root.sol";

import {EnvConfig} from "../../../script/utils/EnvConfig.s.sol";

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
    CFG_MINTER,
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
    ETH_V2_JTRSY_VAULT,
    ETH_V2_JAAA_VAULT,
    BASE_V2_JTRSY_VAULT,
    BASE_V2_JAAA_VAULT,
    ARB_V2_JTRSY_VAULT,
    TREASURY,
    CNF_TREASURY_WALLET,
    CENTRIFUGE_CHAIN_CFG_AMOUNT,
    ESCROW_V2,
    USDC_ETHEREUM,
    USDC_BASE,
    USDC_ARBITRUM
} from "../../../src/spell/V2CleaningsSpell.sol";

contract V2CleaningsSpellTest is SpellForkTest {
    address constant PROTOCOL_GUARDIAN_V3_1 = 0xCEb7eD5d5B3bAD3088f6A1697738B60d829635c6;
    address constant GUARDIAN_V2_ETHEREUM_OR_ARBITRUM = 0x09ab10a9c3E6Eac1d18270a2322B6113F4C7f5E8;
    address constant GUARDIAN_V2_BASE = 0x427A1ce127b1775e4Cbd4F58ad468B9F832eA7e9;

    V2CleaningsSpell internal _spell;
    uint256 internal _preTreasuryUsdc;
    uint256 internal _preEscrowUsdc;
    uint256 internal _preCnfTreasuryCfg;
    uint256 internal _preCfgTotalSupply;

    function _castSpell(
        string memory,
        /* network */
        EnvConfig memory config
    )
        internal
        override
    {
        Root rootV3 = Root(config.contracts.root);

        // ROOT_V3 in the spell is hardcoded to the ETH/BASE/ARB V3 root. On those three
        // chains the env's contracts.root must match, otherwise the spell would brick.
        if (block.chainid == ETHEREUM_CHAIN_ID || block.chainid == BASE_CHAIN_ID || block.chainid == ARBITRUM_CHAIN_ID)
        {
            assertEq(address(ROOT_V3), address(rootV3));
        }

        _spell = new V2CleaningsSpell();

        IERC20 usdc = _usdc();
        if (address(usdc) != address(0)) {
            _preTreasuryUsdc = usdc.balanceOf(TREASURY);
            _preEscrowUsdc = usdc.balanceOf(ESCROW_V2);
        }
        if (block.chainid == ETHEREUM_CHAIN_ID && CFG.code.length > 0) {
            _preCnfTreasuryCfg = IERC20(CFG).balanceOf(CNF_TREASURY_WALLET);
            _preCfgTotalSupply = IERC20(CFG).totalSupply();
        }

        vm.prank(PROTOCOL_GUARDIAN_V3_1);
        rootV3.rely(address(_spell)); // Ideally through guardian.scheduleRely()

        if (address(ROOT_V2).code.length > 0) {
            vm.prank(block.chainid == BASE_CHAIN_ID ? GUARDIAN_V2_BASE : GUARDIAN_V2_ETHEREUM_OR_ARBITRUM);
            ROOT_V2.rely(address(_spell)); // Ideally through guardian.scheduleRely()
        }

        _spell.cast();
    }

    function _customPostAssertions(string memory network, EnvConfig memory config) internal override {
        emit log_named_string("V2Cleanings post-assertions", network);
        assertTrue(_spell.done());

        Root rootV3 = Root(config.contracts.root);
        _assertRootAndSpellWards(rootV3);
        _assertTokenWards(rootV3);
        _assertV2VaultsDeniedFromShareTokens();
        _assertSweep();
        _assertCfgMintedToTreasury();
        _assertHookWards();
    }

    function _assertRootAndSpellWards(Root rootV3) internal view {
        if (address(ROOT_V2).code.length > 0) {
            assertEq(ROOT_V2.wards(address(_spell)), 0);
        }
        assertEq(rootV3.wards(address(_spell)), 0);

        if (ESCROW_V2.code.length > 0) {
            assertEq(IAuth(ESCROW_V2).wards(address(_spell)), 0);
        }
    }

    function _assertTokenWards(Root rootV3) internal view {
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
            assertEq(IAuth(CFG).wards(CFG_MINTER), 1);
        }

        if (TRANCHE_JTRSY.code.length > 0) {
            assertEq(IAuth(TRANCHE_JTRSY).wards(address(rootV3)), 1);
            assertEq(IAuth(TRANCHE_JTRSY).wards(address(ROOT_V2)), 0);
            assertEq(IAuth(TRANCHE_JTRSY).wards(address(_spell)), 0);
        }

        if (block.chainid == ETHEREUM_CHAIN_ID || block.chainid == BASE_CHAIN_ID) {
            assertEq(IAuth(TRANCHE_JAAA).wards(address(rootV3)), 1);
            assertEq(IAuth(TRANCHE_JAAA).wards(address(ROOT_V2)), 0);
            assertEq(IAuth(TRANCHE_JAAA).wards(address(_spell)), 0);
        }
    }

    function _assertV2VaultsDeniedFromShareTokens() internal view {
        if (block.chainid == ETHEREUM_CHAIN_ID) {
            assertEq(IAuth(TRANCHE_JTRSY).wards(ETH_V2_JTRSY_VAULT), 0);
            assertEq(IAuth(TRANCHE_JAAA).wards(ETH_V2_JAAA_VAULT), 0);
        } else if (block.chainid == BASE_CHAIN_ID) {
            assertEq(IAuth(TRANCHE_JTRSY).wards(BASE_V2_JTRSY_VAULT), 0);
            assertEq(IAuth(TRANCHE_JAAA).wards(BASE_V2_JAAA_VAULT), 0);
        } else if (block.chainid == ARBITRUM_CHAIN_ID) {
            assertEq(IAuth(TRANCHE_JTRSY).wards(ARB_V2_JTRSY_VAULT), 0);
        }
    }

    function _assertCfgMintedToTreasury() internal view {
        if (block.chainid != ETHEREUM_CHAIN_ID || CFG.code.length == 0) return;
        // Expected mint: wCFG total supply minus IOU_CFG's wCFG balance (already redeemed
        // 1:1 for CFG without wCFG total-supply reduction) plus Centrifuge Chain CFG.
        uint256 expectedMint =
            IERC20(WCFG).totalSupply() - IERC20(WCFG).balanceOf(IOU_CFG) + CENTRIFUGE_CHAIN_CFG_AMOUNT;
        assertEq(IERC20(CFG).balanceOf(CNF_TREASURY_WALLET) - _preCnfTreasuryCfg, expectedMint);
        assertEq(IERC20(CFG).totalSupply() - _preCfgTotalSupply, expectedMint);
    }

    function _assertSweep() internal view {
        IERC20 usdc = _usdc();
        if (address(usdc) != address(0)) {
            assertEq(usdc.balanceOf(TREASURY) - _preTreasuryUsdc, _preEscrowUsdc);
            assertEq(usdc.balanceOf(ESCROW_V2), 0);
        }
    }

    function _assertHookWards() internal view {
        assertEq(IAuth(FREEZE_ONLY_HOOK).wards(CONTRACT_UPDATER), 1);
        assertEq(IAuth(FULL_RESTRICTIONS_HOOK).wards(CONTRACT_UPDATER), 1);
        assertEq(IAuth(FREELY_TRANSFERABLE_HOOK).wards(CONTRACT_UPDATER), 1);
        assertEq(IAuth(REDEMPTION_RESTRICTIONS_HOOK).wards(CONTRACT_UPDATER), 1);
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

    // V2CleaningsSpell hardcodes ROOT_V3 to 0x7Ed48C31..., which is the V3 root only on
    // ETH/BASE/ARB (and incidentally Avalanche/BNB/Plume). On Optimism/HyperEVM/Monad the
    // V3 root lives at a different address (0xdc9456e7e...), so the spell's tail-end
    // ROOT_V3.relyContract / ROOT_V3.deny calls revert. The spell's own doc comment scopes
    // it to "ETH, BASE, ARB" — we mirror that scope here. If the spell is ever generalised
    // to all networks (e.g. by accepting `Root` as a constructor or cast() argument again),
    // restore the other six test methods.
    function testV2CleaningsEthereumMainnet() external {
        _testCase("ethereum");
    }

    function testV2CleaningsBaseMainnet() external {
        _testCase("base");
    }

    function testV2CleaningsArbitrumMainnet() external {
        _testCase("arbitrum");
    }
}
