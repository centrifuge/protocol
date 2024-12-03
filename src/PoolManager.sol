// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ChainId, PoolId, ShareClassId, AssetId, Ratio} from "src/types/Domain.sol";
import {
    IPoolRegistry,
    IAssetManager,
    IAccounting,
    IHoldings,
    IGateway,
    IShareClassManager,
    IERC7726
} from "src/interfaces/ICommon.sol";
import {IPoolManager} from "src/interfaces/IPoolManager.sol";
import {IMulticall} from "src/interfaces/IMulticall.sol";
import {PoolLocker} from "src/PoolLocker.sol";
import {Auth} from "src/Auth.sol";

contract PoolManager is Auth, PoolLocker, IPoolManager {
    IPoolRegistry immutable poolRegistry;
    IAssetManager immutable assetManager;
    IAccounting immutable accounting;

    IHoldings holdings;
    IGateway gateway;

    /// @dev A requirement for methods that needs to be called by the gateway
    modifier onlyGateway() {
        require(msg.sender == address(gateway), NotAllowed());
        _;
    }

    constructor(
        address owner,
        IMulticall multicall,
        IPoolRegistry poolRegistry_,
        IAssetManager assetManager_,
        IAccounting accounting_,
        IHoldings holdings_,
        IGateway gateway_
    ) Auth(owner) PoolLocker(multicall) {
        poolRegistry = poolRegistry_;
        assetManager = assetManager_;
        accounting = accounting_;
        holdings = holdings_;
        gateway = gateway_;
    }

    function createPool() external returns (PoolId poolId) {
        // TODO: add fees
        return poolRegistry.registerPool(msg.sender);
    }

    function allowPool(ChainId chainId) external poolUnlocked {
        // TODO: store somewhere the allowed info?
        gateway.sendAllowPool(chainId, unlockedPoolId());
    }

    function allowShareClass(ChainId chainId, ShareClassId scId) external poolUnlocked {
        // TODO: store somewhere the allowed info?
        gateway.sendAllowShareClass(chainId, unlockedPoolId(), scId);
    }

    function requestDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, address investor, uint128 amount)
        external
        onlyGateway
    {
        address pendingPoolEscrow = holdings.pendingPoolEscrow(poolId, scId);
        assetManager.mint(pendingPoolEscrow, assetId, amount);

        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        scm.requestDeposit(poolId, scId, assetId, investor, amount);
    }

    function approveDepositRequests(PoolId poolId, ShareClassId scId, AssetId assetId, Ratio approvalRatio)
        external
        poolUnlocked
    {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        IERC7726 valuation = holdings.valuation(poolId, scId, assetId);

        uint128 totalApproved = scm.approveDepositRequests(poolId, scId, assetId, approvalRatio, valuation);

        address pendingPoolEscrow = holdings.pendingPoolEscrow(poolId, scId);
        address poolEscrow = holdings.poolEscrow(poolId, scId);
        uint256 erc6909Id = uint256(uint160(AssetId.unwrap(assetId)));
        assetManager.transferFrom(pendingPoolEscrow, poolEscrow, erc6909Id, totalApproved);
    }

    function updateHoldings(PoolId poolId, ShareClassId scId, AssetId assetId, uint128 amount) external poolUnlocked {
        // TODO
    }

    function issueShares() external poolUnlocked {
        // TODO
    }

    function claimShares() external {
        // TODO
    }

    function _unlock(PoolId poolId) internal override {
        require(poolRegistry.isUnlocker(msg.sender, poolId));
        accounting.unlock(poolId);
    }

    function _lock() internal override {
        accounting.lock(unlockedPoolId());
    }
}
