// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {V2CleaningsCast} from "./v2-cleanings/V2CleaningsCast.sol";

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";

import {Root} from "../../../src/admin/Root.sol";

import {Env, EnvConfig} from "../../../script/utils/EnvConfig.s.sol";

import {Test} from "forge-std/Test.sol";

import {
    V2CleaningsSpell,
    ROOT_V2,
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
    ESCROW_V2
} from "../../../src/spell/V2CleaningsSpell.sol";

/// @title  V2CleaningsSpellTest
/// @notice Focused, forked correctness proof for the V2Cleanings spell: deploy +
///         cast on a live fork, then assert the exact absolute post-state the
///         spell guarantees (ward flips on the roots, CFG/WCFG/tranche tokens,
///         denied V2 vaults, and hook wards).
///
/// @dev    The before/after DELTA assertions (USDC sweep, CFG mint) inherently
///         need a pre-cast snapshot, so they live in the cached validators
///         (`v2-cleanings/validators/Validate_V2Cleanings.sol`) exercised by
///         `V2CleaningsValidatorTest`, not here. This test is the exhaustive
///         absolute-state proof; the validators are the reusable env check.
///
/// @dev    The spell hardcodes ROOT_V3 = 0x7Ed48C31..., which is the V3 root only
///         on ETH/BASE/ARB (and incidentally Avalanche/BNB/Plume). On
///         Optimism/HyperEVM/Monad the V3 root lives at 0xdc9456e7e..., so the
///         spell's tail-end ROOT_V3.relyContract/deny calls revert there. The
///         spell's own doc scopes it to "ETH, BASE, ARB" — mirrored here. If the
///         spell is ever generalised (e.g. taking `Root` as a cast() argument),
///         restore the other six network methods.
contract V2CleaningsSpellTest is Test {
    V2CleaningsSpell internal _spell;

    function testV2CleaningsEthereumMainnet() external {
        _run("ethereum");
    }

    function testV2CleaningsBaseMainnet() external {
        _run("base");
    }

    function testV2CleaningsArbitrumMainnet() external {
        _run("arbitrum");
    }

    function _run(string memory network) internal {
        EnvConfig memory config = Env.load(network);
        vm.createSelectFork(config.network.rpcUrl());

        _spell = V2CleaningsCast.deployAndCast(config);

        emit log_named_string("V2Cleanings post-assertions", network);
        assertTrue(_spell.done());

        Root rootV3 = Root(config.contracts.root);
        _assertRootAndSpellWards(rootV3);
        _assertTokenWards(rootV3);
        _assertV2VaultsDeniedFromShareTokens();
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

    function _assertHookWards() internal view {
        assertEq(IAuth(FREEZE_ONLY_HOOK).wards(CONTRACT_UPDATER), 1);
        assertEq(IAuth(FULL_RESTRICTIONS_HOOK).wards(CONTRACT_UPDATER), 1);
        assertEq(IAuth(FREELY_TRANSFERABLE_HOOK).wards(CONTRACT_UPDATER), 1);
        assertEq(IAuth(REDEMPTION_RESTRICTIONS_HOOK).wards(CONTRACT_UPDATER), 1);
    }
}
