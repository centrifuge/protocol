// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Asserts} from "@chimera/Asserts.sol";
import {vm} from "@chimera/Hevm.sol";

import {Setup} from "./Setup.sol";
import {IERC7540Vault} from "src/vaults/interfaces/IERC7540.sol";
import {IERC20Metadata} from "src/misc/interfaces/IERC20.sol";
import "forge-std/console2.sol";

/// @dev ERC-7540 Properties
/// TODO: Make pointers with Reverts
/// TODO: Make pointer to Vault Like Contract for re-usability

/// Casted to ERC7540 -> Do the operation
/// These are the re-usable ones, which do alter the state
/// And we will not call
abstract contract ERC7540Properties is Setup, Asserts {
    // TODO: change to 10 ** max(token.decimals(), trancheToken.decimals())
    uint256 MAX_ROUNDING_ERROR = 10 ** 18;

    /// @dev 7540-3	convertToAssets(totalSupply) == totalAssets unless price is 0.0
    function erc7540_3(address erc7540Target) public virtual {
        // Doesn't hold on zero price
        if (
            IERC7540Vault(erc7540Target).convertToAssets(
                10 ** IERC20Metadata(IERC7540Vault(erc7540Target).share()).decimals()
            ) == 0
        ) return;

        eq(
            IERC7540Vault(erc7540Target).convertToAssets(
                IERC20Metadata(IERC7540Vault(erc7540Target).share()).totalSupply()),
            IERC7540Vault(erc7540Target).totalAssets(),
            "Property: 7540-3"
        );
    }

    /// @dev 7540-4	convertToShares(totalAssets) == totalSupply unless price is 0.0
    function erc7540_4(address erc7540Target) public virtual {
        if (
            IERC7540Vault(erc7540Target).convertToAssets(
                10 ** IERC20Metadata(IERC7540Vault(erc7540Target).share()).decimals()
            ) == 0
        ) return;

        // convertToShares(totalAssets) == totalSupply
        lte(
            _diff(
                IERC7540Vault(erc7540Target).convertToShares(IERC7540Vault(erc7540Target).totalAssets()),
                IERC20Metadata(IERC7540Vault(erc7540Target).share()).totalSupply()
            ),
            MAX_ROUNDING_ERROR,
            "Property: 7540-4"
        );
    }

    /// @dev 7540-5	max* never reverts
    function erc7540_5(address erc7540Target) public virtual {
        // max* never reverts
        // NOTE: Need to prank as actor each time
        vm.prank(_getActor());
        try IERC7540Vault(erc7540Target).maxDeposit(_getActor()) {}
        catch {
            t(false, "Property: 7540-5 maxDeposit reverts");
        }
        vm.prank(_getActor());      
        try IERC7540Vault(erc7540Target).maxMint(_getActor()) {}
        catch {
            t(false, "Property: 7540-5 maxMint reverts");
        }
        vm.prank(_getActor());
        try IERC7540Vault(erc7540Target).maxRedeem(_getActor()) {}
        catch {
            t(false, "Property: 7540-5 maxRedeem reverts");
        }
        vm.prank(_getActor());
        try IERC7540Vault(erc7540Target).maxWithdraw(_getActor()) {}
        catch {
            t(false, "Property: 7540-5 maxWithdraw reverts");
        }
    }

    /// == erc7540_6 == //
    /// @dev 7540-6	claiming more than max always reverts
    function erc7540_6_deposit(address erc7540Target, uint256 amt) public virtual {
        // Skip 0
        if (amt == 0) {
            return; // Skip
        }

        uint256 maxDep = IERC7540Vault(erc7540Target).maxDeposit(_getActor());

        /// @audit No Revert is proven by erc7540_5

        uint256 sum = maxDep + amt;
        if (sum == 0) {
            return; // Needs to be greater than 0, skip
        }

        // Note: Need to prank as actor because of external call above
        vm.prank(_getActor());
        try IERC7540Vault(erc7540Target).deposit(maxDep + amt, _getActor()) {
            t(false, "Property: 7540-6 depositing more than max does not revert");
        } catch {
            // We want this to be hit
            return; // So we explicitly return here, as a means to ensure that this is the code path
        }

        // NOTE: This code path is never hit per the above
        t(false, "Property: 7540-6 depositing more than max does not revert");
    }

    function erc7540_6_mint(address erc7540Target, uint256 amt) public virtual {
        // Skip 0
        if (amt == 0) {
            return;
        }

        uint256 maxDep = IERC7540Vault(erc7540Target).maxMint(_getActor());

        uint256 sum = maxDep + amt;
        if (sum == 0) {
            return; // Needs to be greater than 0, skip
        }

        // Note: Need to prank as actor because of external call above
        vm.prank(_getActor());
        try IERC7540Vault(erc7540Target).mint(maxDep + amt, _getActor()) {
            t(false, "Property: 7540-6 minting more than max does not revert");
        } catch {
            // We want this to be hit
            return; // So we explicitly return here, as a means to ensure that this is the code path
        }

        // NOTE: This code path is never hit per the above
        t(false, "Property: 7540-6 minting more than max does not revert");
    }

    function erc7540_6_withdraw(address erc7540Target, uint256 amt) public virtual {
        // Skip 0
        if (amt == 0) {
            return;
        }

        uint256 maxDep = IERC7540Vault(erc7540Target).maxWithdraw(_getActor());

        uint256 sum = maxDep + amt;
        if (sum == 0) {
            return; // Needs to be greater than 0
        }

        // Note: Need to prank as actor because of multiple external call
        vm.prank(_getActor());
        try IERC7540Vault(erc7540Target).withdraw(maxDep + amt, _getActor(), _getActor()) {
            t(false, "Property: 7540-6 withdrawing more than max does not revert");
        } catch {
            // We want this to be hit
            return; // So we explicitly return here, as a means to ensure that this is the code path
        }

        // NOTE: This code path is never hit per the above
        t(false, "Property: 7540-6 withdrawing more than max does not revert");
    }

    function erc7540_6_redeem(address erc7540Target, uint256 amt) public virtual {
        // Skip 0
        if (amt == 0) {
            return;
        }

        uint256 maxDep = IERC7540Vault(erc7540Target).maxRedeem(_getActor());

        uint256 sum = maxDep + amt;
        if (sum == 0) {
            return; // Needs to be greater than 0
        }

        // Note: Need to prank as because of multiple external calls
        vm.prank(_getActor());
        try IERC7540Vault(erc7540Target).redeem(maxDep + amt, _getActor(), _getActor()) {
            t(false, "Property: 7540-6 redeeming more than max does not revert");
        } catch {
            // We want this to be hit
            return; // So we explicitly return here, as a means to ensure that this is the code path
        }

        t(false, "Property: 7540-6 redeeming more than max does not revert");
    }

    /// == END erc7540_6 == //

    /// @dev 7540-7	requestRedeem reverts if the share balance is less than amount
    function erc7540_7(address erc7540Target, uint256 shares) public virtual {
        if (shares == 0) {
            return; // Skip
        }

        uint256 actualBal = trancheToken.balanceOf(_getActor());
        uint256 balWeWillUse = actualBal + shares;

        if (balWeWillUse == 0) {
            return; // Skip
        }

        // NOTE: Avoids more false positives
        // Note: Need to prank as actor because of multiple external calls
        vm.prank(_getActor());
        trancheToken.approve(address(erc7540Target), 0);
        // Note: Need to prank as actor because of multiple external calls
        vm.prank(_getActor());
        trancheToken.approve(address(erc7540Target), type(uint256).max);

        uint256 hasReverted;

        // Note: Need to prank as actor because of multiple external calls
        vm.prank(_getActor());
        try IERC7540Vault(erc7540Target).requestRedeem(balWeWillUse, _getActor(), _getActor()) {
            hasReverted = 2; // Coverage
            t(false, "Property: 7540-7 requestRedeem does not revert for shares > balance");
        } catch {
            hasReverted = 1; // 1 = has reverted
            return;
        }

        t(false, "Property: 7540-7 requestRedeem does not revert for shares > balance");
    }

    /// @dev 7540-8	preview* always reverts
    function erc7540_8(address erc7540Target) public virtual {
        // preview* always reverts
        try IERC7540Vault(erc7540Target).previewDeposit(0) {
            t(false, "Property: 7540-8 previewDeposit does not revert");
        } catch {}
        try IERC7540Vault(erc7540Target).previewMint(0) {
            t(false, "Property: 7540-8 previewMint does not revert");
        } catch {}
        try IERC7540Vault(erc7540Target).previewRedeem(0) {
            t(false, "Property: 7540-8 previewRedeem does not revert");
        } catch {}
        try IERC7540Vault(erc7540Target).previewWithdraw(0) {
            t(false, "Property: 7540-8 previewWithdraw does not revert");
        } catch {}
    }

    /// == erc7540_9 == //
    /// @dev 7540-9 if max[method] > 0, then [method] (max) should not revert
    function erc7540_9_deposit(address erc7540Target) public virtual {
        // Per erc7540_5
        uint256 maxDeposit = IERC7540Vault(erc7540Target).maxDeposit(_getActor());

        if (maxDeposit == 0) {
            return; // Skip
        }

        // Note: Need to prank as actor because of external call above
        vm.prank(_getActor());
        try IERC7540Vault(erc7540Target).deposit(maxDeposit, _getActor()) {
            // Success here
            return;
        } catch {
            t(false, "Property: 7540-9 max deposit reverts");
        }
    }

    function erc7540_9_mint(address erc7540Target) public virtual {
        uint256 maxMint = IERC7540Vault(erc7540Target).maxMint(_getActor());

        if (maxMint == 0) {
            return; // Skip
        }

        // Note: Need to prank as actor because of external call above
        vm.prank(_getActor());
        try IERC7540Vault(erc7540Target).mint(maxMint, _getActor()) {
            // Success here
            return;
        } catch {
            t(false, "Property: 7540-9 max mint reverts");
        }
    }

    function erc7540_9_withdraw(address erc7540Target) public virtual {
        uint256 maxWithdraw = IERC7540Vault(erc7540Target).maxWithdraw(_getActor());

        if (maxWithdraw == 0) {
            return; // Skip
        }

        // Note: Need to prank as actor because of multiple external calls
        vm.prank(_getActor());
        try IERC7540Vault(erc7540Target).withdraw(maxWithdraw, _getActor(), _getActor()) {
            // Success here
            // E-1
            sumOfClaimedRedemptions[address(token)] += maxWithdraw;
            return;
        } catch {
            t(false, "Property: 7540-9 max withdraw reverts");
        }
    }

    function erc7540_9_redeem(address erc7540Target) public virtual {
        // Per erc7540_5
        uint256 maxRedeem = IERC7540Vault(erc7540Target).maxRedeem(_getActor());

        if (maxRedeem == 0) {
            return; // Skip
        }

        // Note: Need to prank as actor because of multiple external calls
        vm.prank(_getActor());
        try IERC7540Vault(erc7540Target).redeem(maxRedeem, _getActor(), _getActor()) returns (uint256 assets) {
            // E-1
            sumOfClaimedRedemptions[address(token)] += assets;
            return;
        } catch {
            t(false, "Property: 7540-9 max redeem reverts");
        }
    }

    /// == END erc7540_9 == //

    /// == UTILITY == //
    function _diff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}
