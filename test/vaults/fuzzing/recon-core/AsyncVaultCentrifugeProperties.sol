// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Asserts} from "@chimera/Asserts.sol";
import {Setup} from "./Setup.sol";
import {CallTestAndUndo} from "./helpers/CallTestAndUndo.sol";
import {AsyncVaultProperties} from "./AsyncVaultProperties.sol";

/// @dev ERC-7540 Properties used by Centrifuge
/// See `AsyncVaultProperties` for more properties that can be re-used in your project
abstract contract AsyncVaultCentrifugeProperties is Setup, Asserts, CallTestAndUndo, AsyncVaultProperties {
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
        if (address(token) == address(0)) {
            return false;
        }
        if (address(restrictedTransfers) == address(0)) {
            return false;
        }
        if (address(assetErc20) == address(0)) {
            return false;
        }

        return true;
    }

    /// === CALL TARGET === ///
    /// @dev These are the functions that are actually called
    /// Written in this way to ensure they are non state altering
    /// This helps in as it ensures these properties were "spot broken" by the sequence
    /// And they did not contribute to the sequence (as some of these properties perform more than one action)
    function asyncVault_3_call_target() public returns (bool) {
        bytes memory encoded = abi.encodeCall(this.asyncVault_3, (address(vault)));
        bool asBool = _doTestAndReturnResult(encoded);

        /// @audit We need to assert else it won't be picked up by Medusa
        t(asBool, "asyncVault_3");

        return asBool;
    }

    function asyncVault_4_call_target() public returns (bool) {
        bytes memory encoded = abi.encodeCall(this.asyncVault_4, (address(vault)));
        bool asBool = _doTestAndReturnResult(encoded);

        /// @audit We need to assert else it won't be picked up by Medusa
        t(asBool, "asyncVault_4");

        return asBool;
    }

    function asyncVault_5_call_target() public returns (bool) {
        bytes memory encoded = abi.encodeCall(this.asyncVault_5, (address(vault)));
        bool asBool = _doTestAndReturnResult(encoded);

        /// @audit We need to assert else it won't be picked up by Medusa
        t(asBool, "asyncVault_5");

        return asBool;
    }

    function asyncVault_6_deposit_call_target(uint256 amt) public returns (bool) {
        bytes memory encoded = abi.encodeCall(this.asyncVault_6_deposit, (address(vault), amt));
        bool asBool = _doTestAndReturnResult(encoded);

        /// @audit We need to assert else it won't be picked up by Medusa
        t(asBool, "asyncVault_6_deposit");

        return asBool;
    }

    function asyncVault_6_mint_call_target(uint256 amt) public returns (bool) {
        bytes memory encoded = abi.encodeCall(this.asyncVault_6_mint, (address(vault), amt));
        bool asBool = _doTestAndReturnResult(encoded);

        /// @audit We need to assert else it won't be picked up by Medusa
        t(asBool, "asyncVault_6_mint");

        return asBool;
    }

    function asyncVault_6_withdraw_call_target(uint256 amt) public returns (bool) {
        bytes memory encoded = abi.encodeCall(this.asyncVault_6_withdraw, (address(vault), amt));
        bool asBool = _doTestAndReturnResult(encoded);

        /// @audit We need to assert else it won't be picked up by Medusa
        t(asBool, "asyncVault_6_withdraw");

        return asBool;
    }

    function asyncVault_6_redeem_call_target(uint256 amt) public returns (bool) {
        bytes memory encoded = abi.encodeCall(this.asyncVault_6_redeem, (address(vault), amt));
        bool asBool = _doTestAndReturnResult(encoded);

        /// @audit We need to assert else it won't be picked up by Medusa
        t(asBool, "asyncVault_6_redeem");

        return asBool;
    }

    function asyncVault_7_call_target(uint256 shares) public returns (bool) {
        bytes memory encoded = abi.encodeCall(this.asyncVault_7, (address(vault), shares));
        bool asBool = _doTestAndReturnResult(encoded);

        /// @audit We need to assert else it won't be picked up by Medusa
        t(asBool, "asyncVault_7");

        return asBool;
    }

    function asyncVault_8_call_target() public returns (bool) {
        bytes memory encoded = abi.encodeCall(this.asyncVault_8, (address(vault)));
        bool asBool = _doTestAndReturnResult(encoded);

        /// @audit We need to assert else it won't be picked up by Medusa
        t(asBool, "asyncVault_8");

        return asBool;
    }

    function asyncVault_9_deposit_call_target() public returns (bool) {
        bytes memory encoded = abi.encodeCall(this.asyncVault_9_deposit, (address(vault)));
        bool asBool = _doTestAndReturnResult(encoded);

        /// @audit We need to assert else it won't be picked up by Medusa
        t(asBool, "asyncVault_9_deposit");

        return asBool;
    }

    function asyncVault_9_mint_call_target() public returns (bool) {
        bytes memory encoded = abi.encodeCall(this.asyncVault_9_mint, (address(vault)));
        bool asBool = _doTestAndReturnResult(encoded);

        /// @audit We need to assert else it won't be picked up by Medusa
        t(asBool, "asyncVault_9_mint");

        return asBool;
    }

    function asyncVault_9_withdraw_call_target() public returns (bool) {
        bytes memory encoded = abi.encodeCall(this.asyncVault_9_withdraw, (address(vault)));
        bool asBool = _doTestAndReturnResult(encoded);

        /// @audit We need to assert else it won't be picked up by Medusa
        t(asBool, "asyncVault_9_withdraw");

        return asBool;
    }

    function asyncVault_9_redeem_call_target() public returns (bool) {
        bytes memory encoded = abi.encodeCall(this.asyncVault_9_redeem, (address(vault)));
        bool asBool = _doTestAndReturnResult(encoded);

        /// @audit We need to assert else it won't be picked up by Medusa
        t(asBool, "asyncVault_9_redeem");

        return asBool;
    }

    function _centrifugeSpecificPreChecks() internal view {
        require(msg.sender == address(this)); // Enforces external call to ensure it's not state altering
        require(_canCheckProperties()); // Early revert to prevent false positives
    }

    /// === IMPLEMENTATIONS === ///
    /// All functions are implemented to prevent executing the AsyncVaultProperties
    /// We simply added a check to ensure that `deployNewTokenPoolAndShare` was called

    /// === Overridden Implementations === ///
    function asyncVault_3(address asyncVaultTarget) public override returns (bool) {
        _centrifugeSpecificPreChecks();

        return AsyncVaultProperties.asyncVault_3(asyncVaultTarget);
    }

    function asyncVault_4(address asyncVaultTarget) public override returns (bool) {
        _centrifugeSpecificPreChecks();

        return AsyncVaultProperties.asyncVault_4(asyncVaultTarget);
    }

    function asyncVault_5(address asyncVaultTarget) public override returns (bool) {
        _centrifugeSpecificPreChecks();

        return AsyncVaultProperties.asyncVault_5(asyncVaultTarget);
    }

    function asyncVault_6_deposit(address asyncVaultTarget, uint256 amt) public override returns (bool) {
        _centrifugeSpecificPreChecks();

        return AsyncVaultProperties.asyncVault_6_deposit(asyncVaultTarget, amt);
    }

    function asyncVault_6_mint(address asyncVaultTarget, uint256 amt) public override returns (bool) {
        _centrifugeSpecificPreChecks();

        return AsyncVaultProperties.asyncVault_6_mint(asyncVaultTarget, amt);
    }

    function asyncVault_6_withdraw(address asyncVaultTarget, uint256 amt) public override returns (bool) {
        _centrifugeSpecificPreChecks();

        return AsyncVaultProperties.asyncVault_6_withdraw(asyncVaultTarget, amt);
    }

    function asyncVault_6_redeem(address asyncVaultTarget, uint256 amt) public override returns (bool) {
        _centrifugeSpecificPreChecks();

        return AsyncVaultProperties.asyncVault_6_redeem(asyncVaultTarget, amt);
    }

    function asyncVault_7(address asyncVaultTarget, uint256 shares) public override returns (bool) {
        _centrifugeSpecificPreChecks();

        return AsyncVaultProperties.asyncVault_7(asyncVaultTarget, shares);
    }

    function asyncVault_8(address asyncVaultTarget) public override returns (bool) {
        _centrifugeSpecificPreChecks();

        return AsyncVaultProperties.asyncVault_8(asyncVaultTarget);
    }

    function asyncVault_9_deposit(address asyncVaultTarget) public override returns (bool) {
        _centrifugeSpecificPreChecks();

        return AsyncVaultProperties.asyncVault_9_deposit(asyncVaultTarget);
    }

    function asyncVault_9_mint(address asyncVaultTarget) public override returns (bool) {
        _centrifugeSpecificPreChecks();

        return AsyncVaultProperties.asyncVault_9_mint(asyncVaultTarget);
    }

    function asyncVault_9_withdraw(address asyncVaultTarget) public override returns (bool) {
        _centrifugeSpecificPreChecks();

        return AsyncVaultProperties.asyncVault_9_withdraw(asyncVaultTarget);
    }

    function asyncVault_9_redeem(address asyncVaultTarget) public override returns (bool) {
        _centrifugeSpecificPreChecks();

        return AsyncVaultProperties.asyncVault_9_redeem(asyncVaultTarget);
    }
}
