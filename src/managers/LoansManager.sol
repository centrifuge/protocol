// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {IERC6909NFT} from "src/misc/interfaces/IERC6909.sol";
import {ERC6909NFT} from "src/misc/ERC6909NFT.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {ILinearAccrual} from "src/misc/interfaces/ILinearAccrual.sol";

import {MessageLib, UpdateContractType} from "src/common/libraries/MessageLib.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {AssetId, assetIdFromAddr} from "src/common/types/AssetId.sol";
import {AccountId} from "src/common/types/AccountId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {IBalanceSheet} from "src/vaults/interfaces/IBalanceSheet.sol";
import {IPoolManager} from "src/vaults/interfaces/IPoolManager.sol";

struct Loan {
    // System properties
    ShareClassId scId;
    uint16 tokenId;
    address borrower;
    // Loan properties
    address borrowAsset;
    bytes32 rateId;
    D18 maxBorrowAmount;
    // Ongoing properties
    int128 normalizedDebt;
    D18 totalBorrowed;
    D18 totalRepaid;
}

// TODO: maturity date and/or open term

contract LoansManager is Auth, IERC7726 {
    error UnknownUpdateContractType();
    error UnregisteredRateId();
    error TooManyLoans();
    error NotTheOwner();
    error NonZeroOutstanding();
    error ExceedsLTV();

    PoolId public immutable poolId;
    AccountId public immutable equityAccount;
    AccountId public immutable lossAccount;
    AccountId public immutable gainAccount;

    IERC6909NFT public immutable token;
    ILinearAccrual public immutable linearAccrual;

    IPoolManager public poolManager;
    IBalanceSheet public balanceSheet;

    mapping(AssetId assetId => Loan) public loans;

    constructor(
        PoolId poolId_,
        IERC6909NFT token_,
        ILinearAccrual linearAccrual_,
        IPoolManager poolManager_,
        IBalanceSheet balanceSheet_,
        AccountId equityAccount_,
        AccountId lossAccount_,
        AccountId gainAccount_,
        address deployer
    ) Auth(deployer) {
        poolId = poolId_;
        equityAccount = equityAccount_;
        lossAccount = lossAccount_;
        gainAccount = gainAccount_;

        token = token_;
        linearAccrual = linearAccrual_;

        poolManager = poolManager_;
        balanceSheet = balanceSheet_;
    }

    //----------------------------------------------------------------------------------------------
    // Owner actions
    //----------------------------------------------------------------------------------------------

    function update(PoolId /* poolId */, ShareClassId, /* scId */ bytes calldata payload) external auth {
        uint8 kind = uint8(MessageLib.updateContractType(payload));

        if (kind == uint8(UpdateContractType.LoanMaxBorrowAmount)) {
            MessageLib.UpdateContractLoanMaxBorrowAmount memory m = MessageLib.deserializeUpdateContractLoanMaxBorrowAmount(payload);

            Loan storage loan = loans[AssetId.wrap(m.assetId)];
            require(linearAccrual.debt(loan.rateId, loan.normalizedDebt) <= int128(m.maxBorrowAmount), ExceedsLTV());

            loan.maxBorrowAmount = d18(m.maxBorrowAmount);
            // emit UpdateLoanMaxBorrowAmount();
        } else if (kind == uint8(UpdateContractType.LoanRate)) {

            MessageLib.UpdateContractLoanRate memory m = MessageLib.deserializeUpdateContractLoanRate(payload);

            Loan storage loan = loans[AssetId.wrap(m.assetId)];

            loan.normalizedDebt = linearAccrual.getRenormalizedDebt(loan.rateId, m.rateId, loan.normalizedDebt);
            loan.rateId = m.rateId;
            // emit UpdateLoanRate();
        } else {
            revert UnknownUpdateContractType();
        }
    }

    //----------------------------------------------------------------------------------------------
    // Borrower actions
    //----------------------------------------------------------------------------------------------

    function create(
        ShareClassId scId,
        address borrower,
        address borrowAsset,
        bytes32 rateId,
        string memory tokenURI
    ) external {
        require(linearAccrual.rateIdExists(rateId), UnregisteredRateId());

        uint256 tokenId = token.mint(address(this), tokenURI);
        require(tokenId <= type(uint16).max, TooManyLoans());
        AssetId assetId = poolManager.registerAsset(poolId.centrifugeId(), address(this), tokenId);

        loans[assetId] = Loan({
            scId: scId,
            tokenId: uint16(tokenId),
            borrower: borrower,
            borrowAsset: borrowAsset,
            rateId: rateId,
            maxBorrowAmount: d18(0),
            normalizedDebt: 0,
            totalBorrowed: d18(0),
            totalRepaid: d18(0)
        });

        balanceSheet.deposit(poolId, scId, address(this), uint16(tokenId), address(this), 1);

        // emit NewLoan(..);
    }

    function borrow(AssetId assetId, uint128 amount, address receiver) external {
        Loan storage loan = loans[assetId];
        require(loan.borrower == msg.sender, NotTheOwner());
        require(
            linearAccrual.debt(loan.rateId, loan.normalizedDebt) + int128(amount)
                <= int128(loan.maxBorrowAmount.inner()),
            ExceedsLTV()
        );

        loan.normalizedDebt = linearAccrual.getModifiedNormalizedDebt(loan.rateId, loan.normalizedDebt, int128(amount));
        loan.totalBorrowed = loan.totalBorrowed + d18(amount);

        balanceSheet.withdraw(poolId, loan.scId, loan.borrowAsset, loan.tokenId, receiver, amount);
    }

    function repay(AssetId assetId, uint128 amount, address owner) external {
        Loan storage loan = loans[assetId];
        require(loan.borrower == msg.sender, NotTheOwner());

        loan.normalizedDebt = linearAccrual.getModifiedNormalizedDebt(loan.rateId, loan.normalizedDebt, -int128(amount));
        loan.totalRepaid = loan.totalRepaid + d18(amount);

        balanceSheet.deposit(poolId, loan.scId, loan.borrowAsset, loan.tokenId, owner, amount);
    }

    function close(AssetId assetId) external {
        Loan storage loan = loans[assetId];
        require(loan.borrower == msg.sender, NotTheOwner());
        require(loan.normalizedDebt == 0, NonZeroOutstanding());

        balanceSheet.withdraw(poolId, loan.scId, address(this), loan.tokenId, address(this), 1);
        token.burn(loan.tokenId);
    }

    //----------------------------------------------------------------------------------------------
    // Valuation
    //----------------------------------------------------------------------------------------------

    function getQuote(uint256, address base, address /* quote */ ) external view returns (uint256 quoteAmount) {
        // TODO: how to know conversion to quote asset?

        Loan storage loan = loans[assetIdFromAddr(base)];
        int128 debt = linearAccrual.debt(loan.rateId, loan.normalizedDebt);
        quoteAmount = debt > 0 ? uint256(uint128(debt)) : 0;
    }
}
