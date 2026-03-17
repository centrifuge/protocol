// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccountingToken} from "./interfaces/IAccountingToken.sol";

import {IERC20Metadata} from "../../misc/interfaces/IERC20.sol";
import {IERC6909ExclOperator, IERC6909MetadataExt} from "../../misc/interfaces/IERC6909.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {ITrustedContractUpdate} from "../../core/utils/interfaces/IContractUpdate.sol";

/// @title  AccountingToken
/// @notice ERC6909 multi-token representing in-flight async requests and cross-chain liabilities.
///         Token IDs encode a pool ID, asset address, and liability flag, so a single deployment
///         can be shared across all pools.
/// @dev    Not fully ERC-6909 compatible: operator support (isOperator, setOperator) is omitted
///         because these tokens are only held within the protocol (BalanceSheet/Executor).
contract AccountingToken is IAccountingToken {
    uint256 private constant LIABILITY_BIT = 1 << 255;

    address public immutable contractUpdater;

    mapping(PoolId poolId => mapping(address who => bool)) public minters;
    mapping(address owner => mapping(uint256 tokenId => uint256)) public balanceOf;
    mapping(address owner => mapping(address spender => mapping(uint256 tokenId => uint256))) public allowance;

    constructor(address contractUpdater_) {
        contractUpdater = contractUpdater_;
    }

    modifier onlyMinter(uint256 id) {
        require(minters[_poolId(id)][msg.sender], NotMinter());
        _;
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Owner actions
    // ──────────────────────────────────────────────────────────────────────────

    /// @inheritdoc ITrustedContractUpdate
    function trustedCall(PoolId poolId, ShareClassId, bytes calldata payload) external {
        require(msg.sender == contractUpdater, NotMinter());
        (bytes32 who, bool canMint) = abi.decode(payload, (bytes32, bool));
        address minter = address(uint160(uint256(who)));
        minters[poolId][minter] = canMint;
        emit UpdateMinter(poolId, minter, canMint);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Mint / Burn (minter-gated)
    // ──────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IAccountingToken
    function mint(address owner, uint256 tokenId, uint256 amount, ShareClassId scId) external onlyMinter(tokenId) {
        balanceOf[owner][tokenId] += amount;
        emit Transfer(msg.sender, address(0), owner, tokenId, amount);
        emit Mint(_poolId(tokenId), scId, owner, tokenId, amount);
    }

    /// @inheritdoc IAccountingToken
    function burn(address owner, uint256 tokenId, uint256 amount, ShareClassId scId) external onlyMinter(tokenId) {
        require(balanceOf[owner][tokenId] >= amount, InsufficientBalance(owner, tokenId));
        balanceOf[owner][tokenId] -= amount;
        emit Transfer(msg.sender, owner, address(0), tokenId, amount);
        emit Burn(_poolId(tokenId), scId, owner, tokenId, amount);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // ERC-6909
    // ──────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IERC6909ExclOperator
    function transfer(address receiver, uint256 id, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender][id] >= amount, InsufficientBalance(msg.sender, id));
        balanceOf[msg.sender][id] -= amount;
        balanceOf[receiver][id] += amount;
        emit Transfer(msg.sender, msg.sender, receiver, id, amount);
        return true;
    }

    /// @inheritdoc IERC6909ExclOperator
    function transferFrom(address sender, address receiver, uint256 id, uint256 amount) external returns (bool) {
        if (msg.sender != sender) {
            require(allowance[sender][msg.sender][id] >= amount, InsufficientAllowance(sender, id));
            allowance[sender][msg.sender][id] -= amount;
        }
        require(balanceOf[sender][id] >= amount, InsufficientBalance(sender, id));
        balanceOf[sender][id] -= amount;
        balanceOf[receiver][id] += amount;
        emit Transfer(msg.sender, sender, receiver, id, amount);
        return true;
    }

    /// @inheritdoc IERC6909ExclOperator
    function approve(address spender, uint256 id, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender][id] = amount;
        emit Approval(msg.sender, spender, id, amount);
        return true;
    }

    /// @inheritdoc IERC6909MetadataExt
    function name(uint256 id) external view returns (string memory) {
        string memory assetName = IERC20Metadata(_asset(id)).name();
        return id & LIABILITY_BIT != 0
            ? string.concat("Accounting (Liability) -", assetName)
            : string.concat("Accounting -", assetName);
    }

    /// @inheritdoc IERC6909MetadataExt
    function symbol(uint256 id) external view returns (string memory) {
        string memory assetSymbol = IERC20Metadata(_asset(id)).symbol();
        return id & LIABILITY_BIT != 0 ? string.concat("liab-", assetSymbol) : string.concat("acc-", assetSymbol);
    }

    /// @inheritdoc IERC6909MetadataExt
    function decimals(uint256 id) external view returns (uint8) {
        return IERC20Metadata(_asset(id)).decimals();
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Token ID helpers
    // ──────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IAccountingToken
    function toTokenId(PoolId poolId, address asset, bool liability) public pure returns (uint256) {
        uint256 id = (uint256(poolId.raw()) << 160) | uint256(uint160(asset));
        return liability ? id | LIABILITY_BIT : id;
    }

    /// @inheritdoc IAccountingToken
    function isLiability(uint256 tokenId) public pure returns (bool) {
        return tokenId & LIABILITY_BIT != 0;
    }

    function _poolId(uint256 id) internal pure returns (PoolId) {
        return PoolId.wrap(uint64((id & ~LIABILITY_BIT) >> 160));
    }

    function _asset(uint256 id) internal pure returns (address) {
        return address(uint160(id));
    }
}
