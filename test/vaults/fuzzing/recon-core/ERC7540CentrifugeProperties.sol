// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Asserts} from "@chimera/Asserts.sol";

import {Setup} from "./Setup.sol";
import {ERC7540Properties} from "./ERC7540Properties.sol";

/// @dev ERC-7540 Properties used by Centrifuge
/// See `ERC7540Properties` for more properties that can be re-used in your project
abstract contract ERC7540CentrifugeProperties is Setup, Asserts, ERC7540Properties {
    /// @dev Since we deploy and set addresses via handlers
    // We can have zero values initially
    // We have these checks to prevent false positives
    // This is tightly coupled to our system
    // A simpler system with no actors would not need these checks
    // Although they don't hurt
    // NOTE: We could also change the entire propertie to handlers and we would be ok as well
    function _canCheckProperties() internal view returns (bool) {
        if (TODO_RECON_SKIP_ERC7540) {
            return false;
        }
        if (address(vault) == address(0)) {
            return false;
        }
        if (address(trancheToken) == address(0)) {
            return false;
        }
        if (address(restrictionManager) == address(0)) {
            return false;
        }
        if (address(token) == address(0)) {
            return false;
        }

        return true;
    }

    function _centrifugeSpecificPreChecks() internal {
        require(msg.sender == address(this)); // Enforces external call to ensure it's not state altering
        require(_canCheckProperties()); // Early revert to prevent false positives
    }

    /// === IMPLEMENTATIONS === ///
    /// The statelessTest modifier ensures they are non state altering
    /// This ensures these properties were "spot broken" by the sequence
    /// And they did not contribute to the sequence (as some of these properties perform more than one action)
    /// All functions are implemented to prevent executing the ERC7540Properties
    /// We simply added a check to ensure that `deployNewTokenPoolAndTranche` was called

    /// === Overridden Implementations === ///
    // NOTE: These pass an input parameter to allow the ERC7540Properties to be overridden, even though the paramters are sometimes not used
    function erc7540_3(address erc7540Target) statelessTest public override{
        _centrifugeSpecificPreChecks();

        ERC7540Properties.erc7540_3(address(vault));
    }

    function erc7540_4(address erc7540Target) statelessTest public override {
        _centrifugeSpecificPreChecks();

        ERC7540Properties.erc7540_4(address(vault));
    }

    function erc7540_5(address erc7540Target) statelessTest public override {
        _centrifugeSpecificPreChecks();

        ERC7540Properties.erc7540_5(address(vault));
    }

    function erc7540_6_deposit(address erc7540Target, uint256 amt) statelessTest public override {
        _centrifugeSpecificPreChecks();

        ERC7540Properties.erc7540_6_deposit(address(vault), amt);
    }

    function erc7540_6_mint(address erc7540Target, uint256 amt) statelessTest public override {
        _centrifugeSpecificPreChecks();

        ERC7540Properties.erc7540_6_mint(address(vault), amt);
    }

    function erc7540_6_withdraw(address erc7540Target, uint256 amt) statelessTest public override {
        _centrifugeSpecificPreChecks();

        ERC7540Properties.erc7540_6_withdraw(address(vault), amt);
    }

    function erc7540_6_redeem(address erc7540Target, uint256 amt) statelessTest public override {
        _centrifugeSpecificPreChecks();

        ERC7540Properties.erc7540_6_redeem(address(vault), amt);
    }

    function erc7540_7(address erc7540Target, uint256 shares) statelessTest public override {
        _centrifugeSpecificPreChecks();

        ERC7540Properties.erc7540_7(address(vault), shares);
    }

    function erc7540_8(address erc7540Target) statelessTest public override {
        _centrifugeSpecificPreChecks();

        ERC7540Properties.erc7540_8(address(vault));
    }

    function erc7540_9_deposit(address erc7540Target) statelessTest public override {
        _centrifugeSpecificPreChecks();

        ERC7540Properties.erc7540_9_deposit(address(vault));
    }

    function erc7540_9_mint(address erc7540Target) statelessTest public override {
        _centrifugeSpecificPreChecks();

        ERC7540Properties.erc7540_9_mint(address(vault));

    }

    function erc7540_9_withdraw(address erc7540Target) statelessTest public override {
        _centrifugeSpecificPreChecks();

        ERC7540Properties.erc7540_9_withdraw(address(vault));
    }

    function erc7540_9_redeem(address erc7540Target) statelessTest public override {
        _centrifugeSpecificPreChecks();

        ERC7540Properties.erc7540_9_redeem(address(vault));
    }
}
