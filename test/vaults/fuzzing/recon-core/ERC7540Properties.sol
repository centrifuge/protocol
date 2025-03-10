// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Asserts} from "@chimera/Asserts.sol";
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
    function erc7540_3(address erc7540Target) public virtual returns (bool) {
        // Doesn't hold on zero price
        if (
            IERC7540Vault(erc7540Target).convertToAssets(
                10 ** IERC20Metadata(IERC7540Vault(erc7540Target).share()).decimals()
            ) == 0
        ) return true;

        return IERC7540Vault(erc7540Target).convertToAssets(
            IERC20Metadata(IERC7540Vault(erc7540Target).share()).totalSupply()
        ) == IERC7540Vault(erc7540Target).totalAssets();
    }

    /// @dev 7540-4	convertToShares(totalAssets) == totalSupply unless price is 0.0
    function erc7540_4(address erc7540Target) public virtual returns (bool) {
        if (
            IERC7540Vault(erc7540Target).convertToAssets(
                10 ** IERC20Metadata(IERC7540Vault(erc7540Target).share()).decimals()
            ) == 0
        ) return true;

        // convertToShares(totalAssets) == totalSupply
        return _diff(
            IERC7540Vault(erc7540Target).convertToShares(IERC7540Vault(erc7540Target).totalAssets()),
            IERC20Metadata(IERC7540Vault(erc7540Target).share()).totalSupply()
        ) <= MAX_ROUNDING_ERROR;
    }

    function _diff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    /// @dev 7540-5	max* never reverts
    function erc7540_5(address erc7540Target) public virtual returns (bool) {
        // max* never reverts
        try IERC7540Vault(erc7540Target).maxDeposit(actor) {}
        catch {
            return false;
        }
        try IERC7540Vault(erc7540Target).maxMint(actor) {}
        catch {
            return false;
        }
        try IERC7540Vault(erc7540Target).maxRedeem(actor) {}
        catch {
            return false;
        }
        try IERC7540Vault(erc7540Target).maxWithdraw(actor) {}
        catch {
            return false;
        }

        return true;
    }

    /// == erc7540_6 == //
    /// @dev 7540-6	claiming more than max always reverts
    function erc7540_6_deposit(address erc7540Target, uint256 amt) public virtual returns (bool) {
        // Skip 0
        if (amt == 0) {
            return true; // Skip
        }

        uint256 maxDep = IERC7540Vault(erc7540Target).maxDeposit(actor);

        /// @audit No Revert is proven by erc7540_5

        uint256 sum = maxDep + amt;
        if (sum == 0) {
            return true; // Needs to be greater than 0, skip
        }

        try IERC7540Vault(erc7540Target).deposit(maxDep + amt, actor) {
            return false;
        } catch {
            // We want this to be hit
            return true; // So we explicitly return here, as a means to ensure that this is the code path
        }
    }

    function erc7540_6_mint(address erc7540Target, uint256 amt) public virtual returns (bool) {
        // Skip 0
        if (amt == 0) {
            return true;
        }

        uint256 maxDep = IERC7540Vault(erc7540Target).maxMint(actor);

        uint256 sum = maxDep + amt;
        if (sum == 0) {
            return true; // Needs to be greater than 0, skip
        }

        try IERC7540Vault(erc7540Target).mint(maxDep + amt, actor) {
            return false;
        } catch {
            // We want this to be hit
            return true; // So we explicitly return here, as a means to ensure that this is the code path
        }
    }

    function erc7540_6_withdraw(address erc7540Target, uint256 amt) public virtual returns (bool) {
        // Skip 0
        if (amt == 0) {
            return true;
        }

        uint256 maxDep = IERC7540Vault(erc7540Target).maxWithdraw(actor);

        uint256 sum = maxDep + amt;
        if (sum == 0) {
            return true; // Needs to be greater than 0
        }

        try IERC7540Vault(erc7540Target).withdraw(maxDep + amt, actor, actor) {
            return false;
        } catch {
            // We want this to be hit
            return true; // So we explicitly return here, as a means to ensure that this is the code path
        }
    }

    function erc7540_6_redeem(address erc7540Target, uint256 amt) public virtual returns (bool) {
        // Skip 0
        if (amt == 0) {
            return true;
        }

        uint256 maxDep = IERC7540Vault(erc7540Target).maxRedeem(actor);

        uint256 sum = maxDep + amt;
        if (sum == 0) {
            return true; // Needs to be greater than 0
        }

        try IERC7540Vault(erc7540Target).redeem(maxDep + amt, actor, actor) {
            return false;
        } catch {
            // We want this to be hit
            return true; // So we explicitly return here, as a means to ensure that this is the code path
        }
    }

    /// == END erc7540_6 == //

    /// @dev 7540-7	requestRedeem reverts if the share balance is less than amount
    function erc7540_7(address erc7540Target, uint256 shares) public virtual returns (bool) {
        if (shares == 0) {
            return true; // Skip
        }

        uint256 actualBal = trancheToken.balanceOf(actor);
        uint256 balWeWillUse = actualBal + shares;

        if (balWeWillUse == 0) {
            return true; // Skip
        }

        // NOTE: Avoids more false positives
        trancheToken.approve(address(erc7540Target), 0);
        trancheToken.approve(address(erc7540Target), type(uint256).max);

        uint256 hasReverted;
        try IERC7540Vault(erc7540Target).requestRedeem(balWeWillUse, actor, actor) {
            hasReverted = 2; // Coverage
            return false;
        } catch {
            hasReverted = 1; // 1 = has reverted
            return true;
        }
    }

    /// @dev 7540-8	preview* always reverts
    function erc7540_8(address erc7540Target) public virtual returns (bool) {
        // preview* always reverts
        try IERC7540Vault(erc7540Target).previewDeposit(0) {
            return false;
        } catch {}
        try IERC7540Vault(erc7540Target).previewMint(0) {
            return false;
        } catch {}
        try IERC7540Vault(erc7540Target).previewRedeem(0) {
            return false;
        } catch {}
        try IERC7540Vault(erc7540Target).previewWithdraw(0) {
            return false;
        } catch {}

        return true;
    }

    /// == erc7540_9 == //
    /// @dev 7540-9 if max[method] > 0, then [method] (max) should not revert
    function erc7540_9_deposit(address erc7540Target) public virtual returns (bool) {
        // Per erc7540_5
        uint256 maxDeposit = IERC7540Vault(erc7540Target).maxDeposit(actor);

        if (maxDeposit == 0) {
            return true; // Skip
        }

        try IERC7540Vault(erc7540Target).deposit(maxDeposit, actor) {
            // Success here
            return true;
        } catch {
            return false;
        }
    }

    function erc7540_9_mint(address erc7540Target) public virtual returns (bool) {
        uint256 maxMint = IERC7540Vault(erc7540Target).maxMint(actor);

        if (maxMint == 0) {
            return true; // Skip
        }

        try IERC7540Vault(erc7540Target).mint(maxMint, actor) {
            // Success here
            return true;
        } catch {
            return false;
        }
    }

    function erc7540_9_withdraw(address erc7540Target) public virtual returns (bool) {
        uint256 maxWithdraw = IERC7540Vault(erc7540Target).maxWithdraw(actor);

        if (maxWithdraw == 0) {
            return true; // Skip
        }

        try IERC7540Vault(erc7540Target).withdraw(maxWithdraw, actor, actor) {
            // Success here
            // E-1
            sumOfClaimedRedemptions[address(token)] += maxWithdraw;
            return true;
        } catch {
            return false;
        }
    }

    function erc7540_9_redeem(address erc7540Target) public virtual returns (bool) {
        // Per erc7540_5
        uint256 maxRedeem = IERC7540Vault(erc7540Target).maxRedeem(actor);

        if (maxRedeem == 0) {
            return true; // Skip
        }

        try IERC7540Vault(erc7540Target).redeem(maxRedeem, actor, actor) returns (uint256 assets) {
            // E-1
            sumOfClaimedRedemptions[address(token)] += assets;
            return true;
        } catch {
            return false;
        }
    }

    /// == END erc7540_9 == //
}
