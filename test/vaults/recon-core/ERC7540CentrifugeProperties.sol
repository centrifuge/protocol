// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Asserts} from "@chimera/Asserts.sol";
import {Setup} from "./Setup.sol";
import {CallTestAndUndo} from "./helpers/CallTestAndUndo.sol";
import {ERC7540Properties} from "./ERC7540Properties.sol";

/// @dev ERC-7540 Properties used by Centrifuge
/// See `ERC7540Properties` for more properties that can be re-used in your project
abstract contract ERC7540CentrifugeProperties is Setup, Asserts, CallTestAndUndo, ERC7540Properties {
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

    /// === CALL TARGET === ///
    /// @dev These are the functions that are actually called
    /// Written in this way to ensure they are non state altering
    /// This helps in as it ensures these properties were "spot broken" by the sequence
    /// And they did not contribute to the sequence (as some of these properties perform more than one action)
    function erc7540_3_call_target() public returns (bool) {
        bytes memory encoded = abi.encodeCall(this.erc7540_3, (address(vault)));
        bool asBool = _doTestAndReturnResult(encoded);

        /// @audit We need to assert else it won't be picked up by Medusa
        t(asBool, "erc7540_3");

        return asBool;
    }

    function erc7540_4_call_target() public returns (bool) {
        bytes memory encoded = abi.encodeCall(this.erc7540_4, (address(vault)));
        bool asBool = _doTestAndReturnResult(encoded);

        /// @audit We need to assert else it won't be picked up by Medusa
        t(asBool, "erc7540_4");

        return asBool;
    }

    function erc7540_5_call_target() public returns (bool) {
        bytes memory encoded = abi.encodeCall(this.erc7540_5, (address(vault)));
        bool asBool = _doTestAndReturnResult(encoded);

        /// @audit We need to assert else it won't be picked up by Medusa
        t(asBool, "erc7540_5");

        return asBool;
    }

    function erc7540_6_deposit_call_target(uint256 amt) public returns (bool) {
        bytes memory encoded = abi.encodeCall(this.erc7540_6_deposit, (address(vault), amt));
        bool asBool = _doTestAndReturnResult(encoded);

        /// @audit We need to assert else it won't be picked up by Medusa
        t(asBool, "erc7540_6_deposit");

        return asBool;
    }

    function erc7540_6_mint_call_target(uint256 amt) public returns (bool) {
        bytes memory encoded = abi.encodeCall(this.erc7540_6_mint, (address(vault), amt));
        bool asBool = _doTestAndReturnResult(encoded);

        /// @audit We need to assert else it won't be picked up by Medusa
        t(asBool, "erc7540_6_mint");

        return asBool;
    }

    function erc7540_6_withdraw_call_target(uint256 amt) public returns (bool) {
        bytes memory encoded = abi.encodeCall(this.erc7540_6_withdraw, (address(vault), amt));
        bool asBool = _doTestAndReturnResult(encoded);

        /// @audit We need to assert else it won't be picked up by Medusa
        t(asBool, "erc7540_6_withdraw");

        return asBool;
    }

    function erc7540_6_redeem_call_target(uint256 amt) public returns (bool) {
        bytes memory encoded = abi.encodeCall(this.erc7540_6_redeem, (address(vault), amt));
        bool asBool = _doTestAndReturnResult(encoded);

        /// @audit We need to assert else it won't be picked up by Medusa
        t(asBool, "erc7540_6_redeem");

        return asBool;
    }

    function erc7540_7_call_target(uint256 shares) public returns (bool) {
        bytes memory encoded = abi.encodeCall(this.erc7540_7, (address(vault), shares));
        bool asBool = _doTestAndReturnResult(encoded);

        /// @audit We need to assert else it won't be picked up by Medusa
        t(asBool, "erc7540_7");

        return asBool;
    }

    function erc7540_8_call_target() public returns (bool) {
        bytes memory encoded = abi.encodeCall(this.erc7540_8, (address(vault)));
        bool asBool = _doTestAndReturnResult(encoded);

        /// @audit We need to assert else it won't be picked up by Medusa
        t(asBool, "erc7540_8");

        return asBool;
    }

    function erc7540_9_deposit_call_target() public returns (bool) {
        bytes memory encoded = abi.encodeCall(this.erc7540_9_deposit, (address(vault)));
        bool asBool = _doTestAndReturnResult(encoded);

        /// @audit We need to assert else it won't be picked up by Medusa
        t(asBool, "erc7540_9_deposit");

        return asBool;
    }

    function erc7540_9_mint_call_target() public returns (bool) {
        bytes memory encoded = abi.encodeCall(this.erc7540_9_mint, (address(vault)));
        bool asBool = _doTestAndReturnResult(encoded);

        /// @audit We need to assert else it won't be picked up by Medusa
        t(asBool, "erc7540_9_mint");

        return asBool;
    }

    function erc7540_9_withdraw_call_target() public returns (bool) {
        bytes memory encoded = abi.encodeCall(this.erc7540_9_withdraw, (address(vault)));
        bool asBool = _doTestAndReturnResult(encoded);

        /// @audit We need to assert else it won't be picked up by Medusa
        t(asBool, "erc7540_9_withdraw");

        return asBool;
    }

    function erc7540_9_redeem_call_target() public returns (bool) {
        bytes memory encoded = abi.encodeCall(this.erc7540_9_redeem, (address(vault)));
        bool asBool = _doTestAndReturnResult(encoded);

        /// @audit We need to assert else it won't be picked up by Medusa
        t(asBool, "erc7540_9_redeem");

        return asBool;
    }

    function _centrifugeSpecificPreChecks() internal {
        require(msg.sender == address(this)); // Enforces external call to ensure it's not state altering
        require(_canCheckProperties()); // Early revert to prevent false positives
    }

    /// === IMPLEMENTATIONS === ///
    /// All functions are implemented to prevent executing the ERC7540Properties
    /// We simply added a check to ensure that `deployNewTokenPoolAndTranche` was called

    /// === Overridden Implementations === ///
    function erc7540_3(address erc7540Target) public override returns (bool) {
        _centrifugeSpecificPreChecks();

        return ERC7540Properties.erc7540_3(erc7540Target);
    }

    function erc7540_4(address erc7540Target) public override returns (bool) {
        _centrifugeSpecificPreChecks();

        return ERC7540Properties.erc7540_4(erc7540Target);
    }

    function erc7540_5(address erc7540Target) public override returns (bool) {
        _centrifugeSpecificPreChecks();

        return ERC7540Properties.erc7540_5(erc7540Target);
    }

    function erc7540_6_deposit(address erc7540Target, uint256 amt) public override returns (bool) {
        _centrifugeSpecificPreChecks();

        return ERC7540Properties.erc7540_6_deposit(erc7540Target, amt);
    }

    function erc7540_6_mint(address erc7540Target, uint256 amt) public override returns (bool) {
        _centrifugeSpecificPreChecks();

        return ERC7540Properties.erc7540_6_mint(erc7540Target, amt);
    }

    function erc7540_6_withdraw(address erc7540Target, uint256 amt) public override returns (bool) {
        _centrifugeSpecificPreChecks();

        return ERC7540Properties.erc7540_6_withdraw(erc7540Target, amt);
    }

    function erc7540_6_redeem(address erc7540Target, uint256 amt) public override returns (bool) {
        _centrifugeSpecificPreChecks();

        return ERC7540Properties.erc7540_6_redeem(erc7540Target, amt);
    }

    function erc7540_7(address erc7540Target, uint256 shares) public override returns (bool) {
        _centrifugeSpecificPreChecks();

        return ERC7540Properties.erc7540_7(erc7540Target, shares);
    }

    function erc7540_8(address erc7540Target) public override returns (bool) {
        _centrifugeSpecificPreChecks();

        return ERC7540Properties.erc7540_8(erc7540Target);
    }

    function erc7540_9_deposit(address erc7540Target) public override returns (bool) {
        _centrifugeSpecificPreChecks();

        return ERC7540Properties.erc7540_9_deposit(erc7540Target);
    }

    function erc7540_9_mint(address erc7540Target) public override returns (bool) {
        _centrifugeSpecificPreChecks();

        return ERC7540Properties.erc7540_9_mint(erc7540Target);
    }

    function erc7540_9_withdraw(address erc7540Target) public override returns (bool) {
        _centrifugeSpecificPreChecks();

        return ERC7540Properties.erc7540_9_withdraw(erc7540Target);
    }

    function erc7540_9_redeem(address erc7540Target) public override returns (bool) {
        _centrifugeSpecificPreChecks();

        return ERC7540Properties.erc7540_9_redeem(erc7540Target);
    }
}
