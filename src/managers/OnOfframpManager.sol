// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";
import {Recoverable} from "src/misc/Recoverable.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {IERC165} from "src/misc/interfaces/IERC165.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {MessageLib, UpdateContractType} from "src/common/libraries/MessageLib.sol";

import {IPoolEscrow} from "src/vaults/interfaces/IEscrow.sol";
import {IBalanceSheet} from "src/vaults/interfaces/IBalanceSheet.sol";
import {IUpdateContract} from "src/vaults/interfaces/IUpdateContract.sol";

import {IDepositManager, IWithdrawManager} from "src/managers/interfaces/IBalanceSheetManager.sol";

contract OnOfframpManager is Auth, Recoverable, IDepositManager, IWithdrawManager, IUpdateContract {
    using MathLib for uint256;

    event UpdateManager(PoolId indexed poolId, address who, bool canManage);

    error NotAllowedOnrampAsset();
    error ZeroAssetsDeposited();
    error InvalidOfframpDestination();

    IBalanceSheet public immutable balanceSheet;

    mapping(address asset => bool) public onramp;
    mapping(PoolId => mapping(address => bool)) public manager;
    mapping(address asset => mapping(address receiver => bool)) public offramp;

    constructor(IBalanceSheet balanceSheet_, address deployer) Auth(deployer) {
        balanceSheet = balanceSheet_;
    }

    modifier authOrManager(PoolId poolId) {
        require(wards[msg.sender] == 1 || manager[poolId][msg.sender], IAuth.NotAuthorized());
        _;
    }

    //----------------------------------------------------------------------------------------------
    // Owner actions
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IUpdateContract
    function update(PoolId poolId, ShareClassId, /* scId */ bytes calldata payload) external auth {
        uint8 kind = uint8(MessageLib.updateContractType(payload));

        if (kind == uint8(UpdateContractType.UpdateManager)) {
            MessageLib.UpdateContractUpdateManager memory m = MessageLib.deserializeUpdateContractUpdateManager(payload);
            address who = m.who.toAddress();

            manager[poolId][who] = m.canManage;
            emit UpdateManager(poolId, who, m.canManage);
        } else if (kind == uint8(UpdateContractType.UpdateAddress)) {
            MessageLib.UpdateContractUpdateAddress memory m = MessageLib.deserializeUpdateContractUpdateAddress(payload);
            address who = m.who.toAddress();

            manager[poolId][who] = m.canManage;
            emit UpdateAddress(poolId, who, m.canManage);
        } else {
            revert UnknownUpdateContractType();
        }
    }

    //----------------------------------------------------------------------------------------------
    // Permissionless actions
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IDepositManager
    function deposit(PoolId poolId, ShareClassId scId, address asset, uint256, /* tokenId */ uint128 /* amount */ )
        external
    {
        require(onramp[asset], NotAllowedOnrampAsset());

        IPoolEscrow escrow = balanceSheet.escrow(poolId);
        (uint128 holding,) = escrow.holding(scId, asset, 0);
        uint128 amount = IERC20(asset).balanceOf(address(escrow)) - holding;
        require(amount > 0, ZeroAssetsDeposited());

        balanceSheet.noteDeposit(poolId, scId, asset, 0, amount);
    }

    /// @inheritdoc IWithdrawManager
    function withdraw(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256, /* tokenId */
        uint128 amount,
        address receiver
    ) external authOrManager {
        require(offramp[asset][receiver], InvalidOfframpDestination());
        balanceSheet.withdraw(poolId, scId, asset, 0, receiver, amount);
    }

    //----------------------------------------------------------------------------------------------
    // ERC-165
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return interfaceId == type(IDepositManager).interfaceId || interfaceId == type(IWithdrawManager).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }
}
