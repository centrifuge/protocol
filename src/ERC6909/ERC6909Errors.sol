// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

error ERC6909_Transfer_InsufficientBalance(address owner, uint256 tokenId);
error ERC6909_TransferFrom_InsufficientAllowance(address sender, uint256 tokenId);

error ERC6909Collateral_Mint_UnknownTokenId(address owner, uint256 tokenId);
error ERC6909Collateral_Mint_EmptyOwner();
error ERC6909Collateral_Mint_EmptyAmount();
error ERC6909Collateral_Mint_EmptyURI();
error ERC6909Collateral_Burn_InsufficientBalance(address owner, uint256 id);
error ERC6909Collateral_SetDecimal_LessThanMinimalDecimal(uint8 minimal, uint8 actual);
