// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Currency} from "src/types/Currency.sol";

error MissingDecimals();
error MissingName();

interface IERC20Metadata {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

library AddressLib {
    function isContract(address target) internal returns (bool) {
        uint256 size;

        assembly {
            size := extcodesize(target)
        }

        return size > 0;
    }

    function isNull(address target) internal returns (bool) {
        return target == address(0);
    }

    // Probably not the best place to be.
    function asCurrency(address target) internal returns (Currency memory currency) {
        currency.addr = target;

        uint256 size;

        assembly {
            size := extcodesize(target)
        }

        require(size > 0, "Not a contract");

        try IERC20Metadata(target).decimals() returns (uint8 decimals) {
            currency.decimals = decimals;
        } catch {
            revert MissingDecimals();
        }

        try IERC20Metadata(target).name() returns (string memory name) {
            currency.name = name;
        } catch {
            revert MissingName();
        }

        try IERC20Metadata(target).symbol() returns (string memory symbol) {
            currency.symbol = symbol;
        } catch {
            revert MissingName();
        }
    }
}
