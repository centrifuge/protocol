// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IERC20} from "../../../../../src/misc/interfaces/IERC20.sol";

import {BaseValidator, ValidationContext} from "../../utils/validation/BaseValidator.sol";
import {
    ROOT_V2,
    CFG,
    WCFG,
    IOU_CFG,
    ESCROW_V2,
    TREASURY,
    CNF_TREASURY_WALLET,
    CENTRIFUGE_CHAIN_CFG_AMOUNT,
    TRANCHE_JAAA,
    TRANCHE_JTRSY,
    USDC_ETHEREUM,
    USDC_BASE,
    USDC_ARBITRUM,
    ETHEREUM_CHAIN_ID,
    BASE_CHAIN_ID,
    ARBITRUM_CHAIN_ID
} from "../../../../../src/spell/V2CleaningsSpell.sol";

function _usdc() view returns (IERC20) {
    if (block.chainid == ETHEREUM_CHAIN_ID) return USDC_ETHEREUM;
    if (block.chainid == BASE_CHAIN_ID) return USDC_BASE;
    if (block.chainid == ARBITRUM_CHAIN_ID) return USDC_ARBITRUM;
    return IERC20(address(0));
}

// Cache keys shared between the CACHE and POST validators (file-backed, survive the cast).
string constant K_ESCROW_USDC = "escrowUsdc";
string constant K_TREASURY_USDC = "treasuryUsdc";
string constant K_CFG_TOTAL_SUPPLY = "cfgTotalSupply";
string constant K_CNF_TREASURY_CFG = "cnfTreasuryCfg";

/// @title  Validate_PreV2Cleanings
/// @notice Soft pre-cast check: asserts there IS work for the spell to do. Emits
///         warnings (never hard-fails) so an unexpected pre-state surfaces in
///         the report without blocking the regression run.
contract Validate_PreV2Cleanings is BaseValidator("PreV2Cleanings") {
    function validate(ValidationContext memory) public override {
        // The spell denies ROOT_V2 from the CFG/WCFG/tranche tokens — so it
        // should still be a ward pre-cast. _checkWard warns if it is not.
        _checkWard(CFG, address(ROOT_V2), "ROOT_V2 ward on CFG (pre)");

        if (block.chainid == ETHEREUM_CHAIN_ID) {
            _checkWard(WCFG, address(ROOT_V2), "ROOT_V2 ward on WCFG (pre)");
            _checkWard(TRANCHE_JTRSY, address(ROOT_V2), "ROOT_V2 ward on JTRSY (pre)");
            _checkWard(TRANCHE_JAAA, address(ROOT_V2), "ROOT_V2 ward on JAAA (pre)");
        }

        // The spell sweeps ESCROW_V2's USDC to the treasury — so it should hold some.
        IERC20 usdc = _usdc();
        if (address(usdc) != address(0) && ESCROW_V2.code.length > 0) {
            if (usdc.balanceOf(ESCROW_V2) == 0) {
                _errors.push(
                    _buildError(
                        "balance", "ESCROW_V2 USDC", "> 0", "0", "ESCROW_V2 holds no USDC pre-cast; sweep is a no-op"
                    )
                );
            }
        }
    }
}

/// @title  Validate_CacheV2Cleanings
/// @notice Caches the pre-cast values the POST validator needs for delta checks.
///         Values are stored as plain decimal strings (read back with vm.parseUint).
contract Validate_CacheV2Cleanings is BaseValidator("CacheV2Cleanings") {
    function validate(ValidationContext memory ctx) public override {
        IERC20 usdc = _usdc();
        uint256 escrowUsdc = address(usdc) != address(0) ? usdc.balanceOf(ESCROW_V2) : 0;
        uint256 treasuryUsdc = address(usdc) != address(0) ? usdc.balanceOf(TREASURY) : 0;

        ctx.cache.set(K_ESCROW_USDC, vm.toString(escrowUsdc));
        ctx.cache.set(K_TREASURY_USDC, vm.toString(treasuryUsdc));

        uint256 cfgTotalSupply = CFG.code.length > 0 ? IERC20(CFG).totalSupply() : 0;
        uint256 cnfTreasuryCfg = CFG.code.length > 0 ? IERC20(CFG).balanceOf(CNF_TREASURY_WALLET) : 0;

        ctx.cache.set(K_CFG_TOTAL_SUPPLY, vm.toString(cfgTotalSupply));
        ctx.cache.set(K_CNF_TREASURY_CFG, vm.toString(cnfTreasuryCfg));
    }
}

/// @title  Validate_PostV2Cleanings
/// @notice Hard post-cast check (reverts on failure). Asserts the spell's
///         before/after deltas (USDC sweep, CFG mint) against the cached
///         pre-cast values, plus the security-critical absolute invariant that
///         the stale V2 root is no longer a ward anywhere it was denied.
contract Validate_PostV2Cleanings is BaseValidator("PostV2Cleanings") {
    function validate(ValidationContext memory ctx) public override {
        _assertSweep(ctx);
        _assertCfgMint(ctx);
        _assertV2RootDenied();
    }

    /// @dev TREASURY USDC delta == cached ESCROW_V2 balance, and ESCROW_V2 fully swept to 0.
    function _assertSweep(ValidationContext memory ctx) internal {
        IERC20 usdc = _usdc();
        if (address(usdc) == address(0)) return;

        uint256 preEscrow = vm.parseUint(ctx.cache.get(K_ESCROW_USDC));
        uint256 preTreasury = vm.parseUint(ctx.cache.get(K_TREASURY_USDC));

        uint256 treasuryDelta = usdc.balanceOf(TREASURY) - preTreasury;
        if (treasuryDelta != preEscrow) {
            _errors.push(
                _buildError(
                    "usdcSweep",
                    "TREASURY",
                    vm.toString(preEscrow),
                    vm.toString(treasuryDelta),
                    "Treasury USDC delta does not match swept ESCROW_V2 balance"
                )
            );
        }

        uint256 escrowAfter = usdc.balanceOf(ESCROW_V2);
        if (escrowAfter != 0) {
            _errors.push(
                _buildError("usdcSweep", "ESCROW_V2", "0", vm.toString(escrowAfter), "ESCROW_V2 USDC not fully swept")
            );
        }
    }

    /// @dev On ETH only: CFG totalSupply delta and CNF treasury CFG delta both
    ///      equal the expected mint (wCFG supply minus IOU_CFG's wCFG balance,
    ///      plus the Centrifuge Chain CFG amount).
    function _assertCfgMint(ValidationContext memory ctx) internal {
        if (block.chainid != ETHEREUM_CHAIN_ID || CFG.code.length == 0) return;

        uint256 expectedMint =
            IERC20(WCFG).totalSupply() - IERC20(WCFG).balanceOf(IOU_CFG) + CENTRIFUGE_CHAIN_CFG_AMOUNT;

        uint256 supplyDelta = IERC20(CFG).totalSupply() - vm.parseUint(ctx.cache.get(K_CFG_TOTAL_SUPPLY));
        if (supplyDelta != expectedMint) {
            _errors.push(
                _buildError(
                    "cfgMint",
                    "CFG.totalSupply",
                    vm.toString(expectedMint),
                    vm.toString(supplyDelta),
                    "CFG total supply delta does not match expected mint"
                )
            );
        }

        uint256 treasuryDelta =
            IERC20(CFG).balanceOf(CNF_TREASURY_WALLET) - vm.parseUint(ctx.cache.get(K_CNF_TREASURY_CFG));
        if (treasuryDelta != expectedMint) {
            _errors.push(
                _buildError(
                    "cfgMint",
                    "CNF_TREASURY CFG",
                    vm.toString(expectedMint),
                    vm.toString(treasuryDelta),
                    "CNF treasury CFG delta does not match expected mint"
                )
            );
        }
    }

    /// @dev Security-critical reusable env invariant: the stale V2 root must no
    ///      longer be a ward on the tokens the spell denied it from.
    function _assertV2RootDenied() internal {
        _checkNoWard(CFG, address(ROOT_V2), "ROOT_V2 denied from CFG");

        if (block.chainid == ETHEREUM_CHAIN_ID) {
            _checkNoWard(WCFG, address(ROOT_V2), "ROOT_V2 denied from WCFG");
            _checkNoWard(TRANCHE_JTRSY, address(ROOT_V2), "ROOT_V2 denied from JTRSY");
            _checkNoWard(TRANCHE_JAAA, address(ROOT_V2), "ROOT_V2 denied from JAAA");
        }
    }
}
