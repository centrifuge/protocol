// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Asserts} from "@chimera/Asserts.sol";
import {Setup} from "./Setup.sol";
import {IAsyncVault} from "src/vaults/interfaces/IERC7540.sol";
import {IERC20Metadata} from "src/misc/interfaces/IERC20.sol";
import "forge-std/console2.sol";

/// @dev ERC-7540 Properties
/// TODO: Make pointers with Reverts
/// TODO: Make pointer to Vault Like Contract for re-usability

/// Casted to ERC7540 -> Do the operation
/// These are the re-usable ones, which do alter the state
/// And we will not call
abstract contract AsyncVaultProperties is Setup, Asserts {
    // TODO: change to 10 ** max(token.decimals(), trancheToken.decimals())
    uint256 MAX_ROUNDING_ERROR = 10 ** 18;

    /// @dev 7540-3	convertToAssets(totalSupply) == totalAssets unless price is 0.0
    function asyncVault_3(address asyncVaultTarget) public virtual returns (bool) {
        // Doesn't hold on zero price
        if (
            IAsyncVault(asyncVaultTarget).convertToAssets(
                10 ** IERC20Metadata(IAsyncVault(asyncVaultTarget).share()).decimals()
            ) == 0
        ) return true;

        return IAsyncVault(asyncVaultTarget).convertToAssets(
            IERC20Metadata(IAsyncVault(asyncVaultTarget).share()).totalSupply()
        ) == IAsyncVault(asyncVaultTarget).totalAssets();
    }

    /// @dev 7540-4	convertToShares(totalAssets) == totalSupply unless price is 0.0
    function asyncVault_4(address asyncVaultTarget) public virtual returns (bool) {
        if (
            IAsyncVault(asyncVaultTarget).convertToAssets(
                10 ** IERC20Metadata(IAsyncVault(asyncVaultTarget).share()).decimals()
            ) == 0
        ) return true;

        // convertToShares(totalAssets) == totalSupply
        return _diff(
            IAsyncVault(asyncVaultTarget).convertToShares(IAsyncVault(asyncVaultTarget).totalAssets()),
            IERC20Metadata(IAsyncVault(asyncVaultTarget).share()).totalSupply()
        ) <= MAX_ROUNDING_ERROR;
    }

    function _diff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    /// @dev 7540-5	max* never reverts
    function asyncVault_5(address asyncVaultTarget) public virtual returns (bool) {
        // max* never reverts
        try IAsyncVault(asyncVaultTarget).maxDeposit(actor) {}
        catch {
            return false;
        }
        try IAsyncVault(asyncVaultTarget).maxMint(actor) {}
        catch {
            return false;
        }
        try IAsyncVault(asyncVaultTarget).maxRedeem(actor) {}
        catch {
            return false;
        }
        try IAsyncVault(asyncVaultTarget).maxWithdraw(actor) {}
        catch {
            return false;
        }

        return true;
    }

    /// == asyncVault_6 == //
    /// @dev 7540-6	claiming more than max always reverts
    function asyncVault_6_deposit(address asyncVaultTarget, uint256 amt) public virtual returns (bool) {
        // Skip 0
        if (amt == 0) {
            return true; // Skip
        }

        uint256 maxDep = IAsyncVault(asyncVaultTarget).maxDeposit(actor);

        /// @audit No Revert is proven by asyncVault_5

        uint256 sum = maxDep + amt;
        if (sum == 0) {
            return true; // Needs to be greater than 0, skip
        }

        try IAsyncVault(asyncVaultTarget).deposit(maxDep + amt, actor) {
            return false;
        } catch {
            // We want this to be hit
            return true; // So we explicitly return here, as a means to ensure that this is the code path
        }
    }

    function asyncVault_6_mint(address asyncVaultTarget, uint256 amt) public virtual returns (bool) {
        // Skip 0
        if (amt == 0) {
            return true;
        }

        uint256 maxDep = IAsyncVault(asyncVaultTarget).maxMint(actor);

        uint256 sum = maxDep + amt;
        if (sum == 0) {
            return true; // Needs to be greater than 0, skip
        }

        try IAsyncVault(asyncVaultTarget).mint(maxDep + amt, actor) {
            return false;
        } catch {
            // We want this to be hit
            return true; // So we explicitly return here, as a means to ensure that this is the code path
        }
    }

    function asyncVault_6_withdraw(address asyncVaultTarget, uint256 amt) public virtual returns (bool) {
        // Skip 0
        if (amt == 0) {
            return true;
        }

        uint256 maxDep = IAsyncVault(asyncVaultTarget).maxWithdraw(actor);

        uint256 sum = maxDep + amt;
        if (sum == 0) {
            return true; // Needs to be greater than 0
        }

        try IAsyncVault(asyncVaultTarget).withdraw(maxDep + amt, actor, actor) {
            return false;
        } catch {
            // We want this to be hit
            return true; // So we explicitly return here, as a means to ensure that this is the code path
        }
    }

    function asyncVault_6_redeem(address asyncVaultTarget, uint256 amt) public virtual returns (bool) {
        // Skip 0
        if (amt == 0) {
            return true;
        }

        uint256 maxDep = IAsyncVault(asyncVaultTarget).maxRedeem(actor);

        uint256 sum = maxDep + amt;
        if (sum == 0) {
            return true; // Needs to be greater than 0
        }

        try IAsyncVault(asyncVaultTarget).redeem(maxDep + amt, actor, actor) {
            return false;
        } catch {
            // We want this to be hit
            return true; // So we explicitly return here, as a means to ensure that this is the code path
        }
    }

    /// == END asyncVault_6 == //

    /// @dev 7540-7	requestRedeem reverts if the share balance is less than amount
    function asyncVault_7(address asyncVaultTarget, uint256 shares) public virtual returns (bool) {
        if (shares == 0) {
            return true; // Skip
        }

        uint256 actualBal = trancheToken.balanceOf(actor);
        uint256 balWeWillUse = actualBal + shares;

        if (balWeWillUse == 0) {
            return true; // Skip
        }

        // NOTE: Avoids more false positives
        trancheToken.approve(address(asyncVaultTarget), 0);
        trancheToken.approve(address(asyncVaultTarget), type(uint256).max);

        uint256 hasReverted;
        try IAsyncVault(asyncVaultTarget).requestRedeem(balWeWillUse, actor, actor) {
            hasReverted = 2; // Coverage
            return false;
        } catch {
            hasReverted = 1; // 1 = has reverted
            return true;
        }
    }

    /// @dev 7540-8	preview* always reverts
    function asyncVault_8(address asyncVaultTarget) public virtual returns (bool) {
        // preview* always reverts
        try IAsyncVault(asyncVaultTarget).previewDeposit(0) {
            return false;
        } catch {}
        try IAsyncVault(asyncVaultTarget).previewMint(0) {
            return false;
        } catch {}
        try IAsyncVault(asyncVaultTarget).previewRedeem(0) {
            return false;
        } catch {}
        try IAsyncVault(asyncVaultTarget).previewWithdraw(0) {
            return false;
        } catch {}

        return true;
    }

    /// == asyncVault_9 == //
    /// @dev 7540-9 if max[method] > 0, then [method] (max) should not revert
    function asyncVault_9_deposit(address asyncVaultTarget) public virtual returns (bool) {
        // Per asyncVault_5
        uint256 maxDeposit = IAsyncVault(asyncVaultTarget).maxDeposit(actor);

        if (maxDeposit == 0) {
            return true; // Skip
        }

        try IAsyncVault(asyncVaultTarget).deposit(maxDeposit, actor) {
            // Success here
            return true;
        } catch {
            return false;
        }
    }

    function asyncVault_9_mint(address asyncVaultTarget) public virtual returns (bool) {
        uint256 maxMint = IAsyncVault(asyncVaultTarget).maxMint(actor);

        if (maxMint == 0) {
            return true; // Skip
        }

        try IAsyncVault(asyncVaultTarget).mint(maxMint, actor) {
            // Success here
            return true;
        } catch {
            return false;
        }
    }

    function asyncVault_9_withdraw(address asyncVaultTarget) public virtual returns (bool) {
        uint256 maxWithdraw = IAsyncVault(asyncVaultTarget).maxWithdraw(actor);

        if (maxWithdraw == 0) {
            return true; // Skip
        }

        try IAsyncVault(asyncVaultTarget).withdraw(maxWithdraw, actor, actor) {
            // Success here
            // E-1
            sumOfClaimedRedemptions[address(token)] += maxWithdraw;
            return true;
        } catch {
            return false;
        }
    }

    function asyncVault_9_redeem(address asyncVaultTarget) public virtual returns (bool) {
        // Per asyncVault_5
        uint256 maxRedeem = IAsyncVault(asyncVaultTarget).maxRedeem(actor);

        if (maxRedeem == 0) {
            return true; // Skip
        }

        try IAsyncVault(asyncVaultTarget).redeem(maxRedeem, actor, actor) returns (uint256 assets) {
            // E-1
            sumOfClaimedRedemptions[address(token)] += assets;
            return true;
        } catch {
            return false;
        }
    }

    /// == END asyncVault_9 == //
}
