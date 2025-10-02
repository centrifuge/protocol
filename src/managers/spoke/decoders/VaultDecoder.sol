// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {BaseDecoder} from "./BaseDecoder.sol";

contract VaultDecoder is BaseDecoder {
    /// @notice Deposit into the ERC4626 vault
    /// @param  receiver the address of the receiver of the vault tokens
    function deposit(uint256, address receiver) external view virtual returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(receiver);
    }

    /// @notice Mint tokens from the ERC4626 vault
    /// @param  receiver the address of the receiver of the vault tokens
    function mint(uint256, address receiver) external pure virtual returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(receiver);
    }

    /// @notice Withdraw tokens from the ERC4626 vault
    /// @param  receiver the address of the receiver of the vault tokens
    /// @param  owner the address of the owner of the vault tokens
    function withdraw(uint256, address receiver, address owner)
        external
        view
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(receiver, owner);
    }

    /// @notice Redeem tokens from the ERC4626 vault
    /// @param  receiver the address of the receiver of the vault tokens
    /// @param  owner the address of the owner of the vault tokens
    function redeem(uint256, address receiver, address owner)
        external
        view
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(receiver, owner);
    }

    /// @notice Submit deposit request into the ERC7540 vault
    /// @param  controller the address of the controller of the request
    /// @param  owner the address of the owner of the assets
    function requestDeposit(uint256, address controller, address owner)
        external
        view
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(controller, owner);
    }

    /// @notice Submit redeem request into the ERC7540 vault
    /// @param  controller the address of the controller of the request
    /// @param  owner the address of the owner of the shares
    function requestRedeem(uint256, address controller, address owner)
        external
        view
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(controller, owner);
    }

    /// @notice Cancel deposit request into the ERC7887 vault
    /// @param  controller the address of the controller of the request
    function cancelDepositRequest(uint256, address controller)
        external
        view
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(controller);
    }

    /// @notice Cancel redeem request into the ERC7887 vault
    /// @param  controller the address of the controller of the request
    function cancelRedeemRequest(uint256, address controller)
        external
        view
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(controller);
    }

    /// @notice Claim cancel deposit request into the ERC7887 vault
    /// @param  receiver the address of the receiver of the assets
    /// @param  controller the address of the controller of the request
    function claimCancelDepositRequest(uint256, address receiver, address controller)
        external
        view
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(receiver, controller);
    }

    /// @notice Claim cancel redeem request into the ERC7887 vault
    /// @param  receiver the address of the receiver of the assets
    /// @param  controller the address of the controller of the request
    function claimCancelRedeemRequest(uint256, address receiver, address controller)
        external
        view
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(receiver, controller);
    }
}
