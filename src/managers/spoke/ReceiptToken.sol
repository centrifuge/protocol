// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IReceiptToken} from "./interfaces/IReceiptToken.sol";
import {IExecutorFactory} from "./interfaces/IExecutorFactory.sol";

import {IERC20Metadata} from "../../misc/interfaces/IERC20.sol";
import {IERC6909, IERC6909ExclOperator, IERC6909Decimals} from "../../misc/interfaces/IERC6909.sol";

import {PoolId} from "../../core/types/PoolId.sol";

import {IERC165} from "forge-std/interfaces/IERC165.sol";

/// @title  ReceiptToken
/// @notice ERC6909 multi-token representing in-flight async requests. Token IDs encode a pool ID
///         and asset address, so a single deployment can be shared across all pools. Only the
///         executor deployed by the factory for a given pool may mint or burn that pool's token IDs.
/// @dev    Not fully ERC-6909 compatible: operator support (isOperator, setOperator) is omitted
///         because these tokens are only held within the protocol (BalanceSheet/Executor).
contract ReceiptToken is IReceiptToken {
    IExecutorFactory public immutable factory;

    mapping(address owner => mapping(uint256 tokenId => uint256)) public balanceOf;
    mapping(address owner => mapping(address spender => mapping(uint256 tokenId => uint256))) public allowance;

    constructor(IExecutorFactory factory_) {
        factory = factory_;
    }

    modifier onlyPoolExecutor(uint256 id) {
        require(msg.sender == factory.executors(_poolId(id)), NotPoolExecutor());
        _;
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Mint / Burn (executor-gated)
    // ──────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IReceiptToken
    function mint(address owner, uint256 id, uint256 amount) external onlyPoolExecutor(id) {
        balanceOf[owner][id] += amount;
        emit Transfer(msg.sender, address(0), owner, id, amount);
    }

    /// @inheritdoc IReceiptToken
    function burn(address owner, uint256 id, uint256 amount) external onlyPoolExecutor(id) {
        require(balanceOf[owner][id] >= amount, InsufficientBalance(owner, id));
        balanceOf[owner][id] -= amount;
        emit Transfer(msg.sender, owner, address(0), id, amount);
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

    /// @inheritdoc IERC6909Decimals
    function decimals(uint256 id) external view returns (uint8) {
        return IERC20Metadata(address(uint160(id))).decimals();
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC6909).interfaceId || interfaceId == type(IERC6909Decimals).interfaceId;
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Token ID helpers
    // ──────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IReceiptToken
    function toTokenId(PoolId poolId, address asset) public pure returns (uint256) {
        return (uint256(poolId.raw()) << 160) | uint256(uint160(asset));
    }

    function _poolId(uint256 id) internal pure returns (PoolId) {
        return PoolId.wrap(uint64(id >> 160));
    }
}
