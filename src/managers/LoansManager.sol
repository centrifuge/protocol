// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {IERC6909NFT} from "src/misc/interfaces/IERC6909.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {ILinearAccrual} from "src/misc/interfaces/ILinearAccrual.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";

import {IValuation} from "src/common/interfaces/IValuation.sol";
import {UpdateContractMessageLib, UpdateContractType} from "src/spoke/libraries/UpdateContractMessageLib.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {AccountId} from "src/common/types/AccountId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {ISpoke} from "src/spoke/interfaces/ISpoke.sol";
import {IBalanceSheet} from "src/spoke/interfaces/IBalanceSheet.sol";

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

contract LoansManager is Auth, IValuation {
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

    ISpoke public spoke;
    IBalanceSheet public balanceSheet;

    mapping(AssetId assetId => Loan) public loans;

    constructor(
        PoolId poolId_,
        IERC6909NFT token_,
        ILinearAccrual linearAccrual_,
        ISpoke spoke_,
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

        spoke = spoke_;
        balanceSheet = balanceSheet_;
    }

    //----------------------------------------------------------------------------------------------
    // Owner actions
    //----------------------------------------------------------------------------------------------

    function update(PoolId, /* poolId */ ShareClassId, /* scId */ bytes calldata payload) external auth {
        uint8 kind = uint8(UpdateContractMessageLib.updateContractType(payload));

        if (kind == uint8(UpdateContractType.LoanMaxBorrowAmount)) {
            UpdateContractMessageLib.UpdateContractLoanMaxBorrowAmount memory m =
                UpdateContractMessageLib.deserializeUpdateContractLoanMaxBorrowAmount(payload);

            Loan storage loan = loans[AssetId.wrap(m.assetId)];
            require(linearAccrual.debt(loan.rateId, loan.normalizedDebt) <= int128(m.maxBorrowAmount), ExceedsLTV());

            loan.maxBorrowAmount = d18(m.maxBorrowAmount);
            // emit UpdateLoanMaxBorrowAmount();
        } else if (kind == uint8(UpdateContractType.LoanRate)) {
            UpdateContractMessageLib.UpdateContractLoanRate memory m =
                UpdateContractMessageLib.deserializeUpdateContractLoanRate(payload);

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

    function create(ShareClassId scId, address borrower, address borrowAsset, bytes32 rateId, string memory tokenURI)
        external
    {
        require(linearAccrual.rateIdExists(rateId), UnregisteredRateId());

        uint256 tokenId = token.mint(address(this), tokenURI);
        require(tokenId <= type(uint16).max, TooManyLoans());
        AssetId assetId = spoke.registerAsset(poolId.centrifugeId(), address(this), tokenId);

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

        balanceSheet.deposit(poolId, scId, address(this), uint16(tokenId), 1);

        // emit NewLoan(..);
    }

    function borrow(AssetId assetId, uint128 amount, address receiver) external {
        Loan storage loan = loans[assetId];
        require(loan.borrower == msg.sender, NotTheOwner());
        require(
            linearAccrual.debt(loan.rateId, loan.normalizedDebt) + int128(amount) <= int128(loan.maxBorrowAmount.raw()),
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

        SafeTransferLib.safeTransferFrom(loan.borrowAsset, owner, address(this), amount);
        balanceSheet.deposit(poolId, loan.scId, loan.borrowAsset, loan.tokenId, amount);
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

    function getQuote(uint128, AssetId base, AssetId /* quote */ ) external view returns (uint128 quoteAmount) {
        // TODO: how to know conversion to quote asset?

        Loan storage loan = loans[base];
        int128 debt = linearAccrual.debt(loan.rateId, loan.normalizedDebt);
        quoteAmount = debt > 0 ? uint128(debt) : 0;
    }
}
