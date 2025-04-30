// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {IERC6909NFT} from "src/misc/interfaces/IERC6909.sol";
import {ERC6909NFT} from "src/misc/ERC6909NFT.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {AccountId} from "src/common/types/AccountId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {IHub} from "src/hub/interfaces/IHub.sol";

import {IBalanceSheet} from "src/vaults/interfaces/IBalanceSheet.sol";
import {IPoolManager} from "src/vaults/interfaces/IPoolManager.sol";

struct Loan {
    // Fixed properties
    ShareClassId scId;
    address owner;
    address asset;
    D18 ltv;
    D18 value;
    // TODO: add rate ID, integrate with Linear Accrual contract

    // Ongoing
    D18 outstanding;
    D18 totalBorrowed;
    D18 totalRepaid;
}

contract LoansManager is ERC6909NFT, IERC7726 {
    error NotHubChain();
    error NotTheOwner();
    error NonZeroOutstanding();
    error ExceedsLTV();

    PoolId public immutable poolId;
    AccountId public immutable equityAccount;
    AccountId public immutable lossAccount;
    AccountId public immutable gainAccount;

    IHub public hub;
    IPoolManager public poolManager;
    IBalanceSheet public balanceSheet;

    mapping(uint256 tokenId => Loan) public loans;

    constructor(
        PoolId poolId_,
        IHub hub_,
        IPoolManager poolManager_,
        IBalanceSheet balanceSheet_,
        AccountId equityAccount_,
        AccountId lossAccount_,
        AccountId gainAccount_,
        address deployer
    ) ERC6909NFT(deployer) {
        require(hub_.sender().localCentrifugeId() == poolId_.centrifugeId(), NotHubChain());

        poolId = poolId_;
        equityAccount = equityAccount_;
        lossAccount = lossAccount_;
        gainAccount = gainAccount_;

        hub = hub_;
        poolManager = poolManager_;
        balanceSheet = balanceSheet_;
    }

    //----------------------------------------------------------------------------------------------
    // Open/close
    //----------------------------------------------------------------------------------------------

    function create(ShareClassId scId, address owner, address asset, string memory tokenURI, uint128 ltv, uint128 value)
        external
    {
        uint256 loanId = mint(address(this), tokenURI);
        AssetId assetId = poolManager.registerAsset(poolId.centrifugeId(), address(this), loanId);

        loans[loanId] = Loan({
            scId: scId,
            owner: owner,
            asset: asset,
            ltv: d18(ltv),
            value: d18(value),
            outstanding: d18(0),
            totalBorrowed: d18(0),
            totalRepaid: d18(0)
        });

        balanceSheet.deposit(poolId, scId, address(this), loanId, address(this), 1);

        // TODO: how to ensure unique loan ID?
        AccountId assetAccount = AccountId.wrap(uint32(loanId << 2));
        hub.createAccount(poolId, assetAccount, true);

        hub.createHolding(
            poolId, scId, assetId, IERC7726(address(this)), assetAccount, equityAccount, lossAccount, gainAccount
        );
    }

    function close(uint256 loanId) external {
        Loan storage loan = loans[loanId];
        require(loan.owner == msg.sender, NotTheOwner());
        require(loan.outstanding.isNull(), NonZeroOutstanding());

        balanceSheet.withdraw(poolId, loan.scId, address(this), loanId, address(this), 1);
        _burn(address(this), loanId, 1);
    }

    //----------------------------------------------------------------------------------------------
    // Ongoing
    //----------------------------------------------------------------------------------------------

    function borrow(uint256 loanId, uint128 amount, address receiver) external {
        Loan storage loan = loans[loanId];
        require(loan.owner == msg.sender, NotTheOwner());
        require(loan.outstanding + d18(amount) <= loan.ltv * loan.value, ExceedsLTV());

        loan.outstanding = loan.outstanding + d18(amount);
        loan.totalBorrowed = loan.totalBorrowed + d18(amount);

        balanceSheet.withdraw(poolId, loan.scId, loan.asset, loanId, receiver, amount);
    }

    function repay(uint256 loanId, uint128 amount, address owner) external {
        Loan storage loan = loans[loanId];
        require(loan.owner == msg.sender, NotTheOwner());

        loan.outstanding = loan.outstanding - d18(amount);
        loan.totalRepaid = loan.totalRepaid + d18(amount);

        balanceSheet.deposit(poolId, loan.scId, loan.asset, loanId, owner, amount);
    }

    //----------------------------------------------------------------------------------------------
    // Valuation
    //----------------------------------------------------------------------------------------------

    function getQuote(uint256 baseAmount, address base, address quote) external view returns (uint256 quoteAmount) {
        // TODO: calculate valuation of loan using outstanding supply
        quoteAmount = 0;
    }
}
