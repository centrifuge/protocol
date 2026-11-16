// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @notice ERC-8161 transferable deposit requests: a pending ERC-7540 deposit request moves to a new controller.
interface IERC8161DepositTransferable {
    event TransferDepositRequest(uint256 indexed requestId, address indexed from, address indexed to, address sender);

    /**
     * @dev Transfers a pending deposit request to a new controller.
     *
     * @param requestId The ID of the deposit request to transfer
     * @param oldController The current controller of the request
     * @param newController The address of the new controller
     */
    function transferDepositRequest(uint256 requestId, address oldController, address newController) external;
}

/// @notice ERC-8161 transferable redeem requests: a pending ERC-7540 redeem request moves to a new controller.
interface IERC8161RedeemTransferable {
    event TransferRedeemRequest(uint256 indexed requestId, address indexed from, address indexed to, address sender);

    /**
     * @dev Transfers a pending redeem request to a new controller.
     *
     * @param requestId The ID of the redeem request to transfer
     * @param oldController The current controller of the request
     * @param newController The address of the new controller
     */
    function transferRedeemRequest(uint256 requestId, address oldController, address newController) external;
}
