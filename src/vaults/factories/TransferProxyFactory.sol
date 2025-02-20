// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {IERC20} from "src/vaults/interfaces/IERC20.sol";
import {MathLib} from "src/vaults/libraries/MathLib.sol";
import {IRecoverable} from "src/vaults/interfaces/IRoot.sol";
import {IPoolManager} from "src/vaults/interfaces/IPoolManager.sol";
import {SafeTransferLib} from "src/vaults/libraries/SafeTransferLib.sol";
import {ITransferProxy, ITransferProxyFactory} from "src/vaults/interfaces/factories/ITransferProxy.sol";

contract TransferProxy is Auth, ITransferProxy {
    using MathLib for uint256;

    bytes32 public immutable destination;

    IPoolManager public poolManager;

    constructor(bytes32 destination_) Auth(msg.sender) {
        destination = destination_;
    }

    // --- Administration ---
    /// @inheritdoc ITransferProxy
    function file(bytes32 what, address data) external auth {
        if (what == "poolManager") poolManager = IPoolManager(data);
        else revert("TransferProxy/file-unrecognized-param");
        emit File(what, data);
    }

    /// @inheritdoc IRecoverable
    function recoverTokens(address token, address to, uint256 amount) external auth {
        SafeTransferLib.safeTransfer(token, to, amount);
    }

    // --- Transfers ---
    /// @inheritdoc ITransferProxy
    function transfer(address token) external {
        uint128 amount = IERC20(token).balanceOf(address(this)).toUint128();

        address poolManager_ = address(poolManager);
        if (IERC20(token).allowance(address(this), poolManager_) == 0) {
            SafeTransferLib.safeApprove(token, poolManager_, type(uint256).max);
        }

        IPoolManager(poolManager_).transferAssets(token, destination, amount);
    }
}

/// @title  Restricted Transfer Proxy Factory
/// @dev    Utility for deploying contracts that have a fixed destination for transfers
///         Users can send tokens to the TransferProxy, from a service that only supports
///         ERC20 transfers and not full contract calls.
contract TransferProxyFactory is Auth, ITransferProxyFactory {
    address public immutable root;

    address public poolManager;

    /// @inheritdoc ITransferProxyFactory
    mapping(bytes32 id => address proxy) public proxies;

    constructor(address root_, address deployer) Auth(deployer) {
        root = root_;
    }

    // --- Administration ---
    /// @inheritdoc ITransferProxyFactory
    function file(bytes32 what, address data) external auth {
        if (what == "poolManager") poolManager = data;
        else revert("TransferProxyFactory/file-unrecognized-param");
        emit File(what, data);
    }

    // --- Deployment ---
    /// @inheritdoc ITransferProxyFactory
    function newTransferProxy(bytes32 destination) external returns (address) {
        require(proxies[destination] == address(0), "TransferProxyFactory/already-deployed");

        // Salt is the destination, so every transfer proxy on every chain has the same address
        TransferProxy proxy = new TransferProxy{salt: destination}(destination);
        proxy.file("poolManager", poolManager);

        proxy.rely(root);
        proxy.deny(address(this));

        proxies[destination] = address(proxy);

        emit DeployTransferProxy(destination, address(proxy));
        return address(proxy);
    }

    // --- View methods ---
    /// @inheritdoc ITransferProxyFactory
    function getAddress(bytes32 destination) external view returns (address) {
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                destination,
                keccak256(abi.encodePacked(type(TransferProxy).creationCode, abi.encode(destination)))
            )
        );

        return address(uint160(uint256(hash)));
    }
}
