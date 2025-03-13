// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;


contract BalanceSheetManager is Auth {
    using BytesLib for bytes;
    using MathLib for uint256;
    using CastLib for *;

    IPerPoolEscrow public immutable escrow;

    IGateway public gateway;
    IGasService public gasService;

    constructor(address escrow_) Auth(msg.sender) {
        escrow = IEscrow(escrow_);
    }

    // --- Administration ---
    /// @inheritdoc IPoolManager
    function file(bytes32 what, address data) external auth {
        if (what == "gateway") gateway = IGateway(data);
        else if (what == "gasService") gasService = IGasService(data);
        else revert("PoolManager/file-unrecognized-param");
        emit File(what, data);
    }

    /// @inheritdoc IRecoverable
    function recoverTokens(address token, address to, uint256 amount) external auth {
        SafeTransferLib.safeTransfer(token, to, amount);
    }

    function increase(
        uint64 poolId,
        bytes16 shareClassId,
        address holding,
        address provider,
        uint256 base,
        uint256 add,
        uint256 pricePerUnit,
        uint64 timestamp
    ) external {
        require(this.hasRights(poolId, shareClassId, msg.sender, Rights.deposit), "PoolManager/missing-deposit-rights");

        // TODO: Use PM to convert holding to assetId

        IPerPoolEscrow(escrow).pendingDepositIncrease(holding, assetId, poolId, shareClassId, add);

        // TODO: Transfer from provider to escrow

        IPerPoolEscrow(escrow).deposit(holding, assetId, poolId, shareClassId, add);

        // TODO: Send message to CP IncreaseHoldings()
    }

    function decrease(
        uint64 poolId,
        bytes16 shareClassId,
        address holding,
        address receiver,
        uint256 base,
        uint256 add,
        uint256 pricePerUnit,
        uint64 timestamp
    ) external {
        require(this.hasRights(poolId, shareClassId, msg.sender, Rights.withdraw), "PoolManager/missing-deposit-rights");

        // TODO: Use PM to convert holding to assetId

        // TODO: Transfer to provider from escrow
         IPerPoolEscrow(escrow).withdraw(assetId, poolId, shareClassId, add);

        // TODO: Send message to CP DecreaseHoldings()
    }

    function issue(
        uint64 poolId,
        bytes16 shareClassId,
        address to,
        uint256 shares, // delta change, positive - debit, negative - credit
        uint256 pricePerShare,
        uint64 timestamp
    ) external {
        require(this.hasRights(poolId, shareClassId, msg.sender, Rights.issue), "PoolManager/missing-deposit-rights");
        
        // TODO: Mint shares to to
        
        // TODO: Send message to CP IssuedShares()
    }

    function revoke(
        uint64 poolId,
        bytes16 shareClassId,
        address from,
        uint256 shares,
        uint256 pricePerShare,
        uint64 timestamp
    ) external {
        require(this.hasRights(poolId, shareClassId, msg.sender, Rights.revoke), "PoolManager/missing-deposit-rights");

        // TODO: burn shares from from
     
        // TODO: Send message to CP RevokedShares()

    }