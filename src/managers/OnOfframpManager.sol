// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {IERC165} from "src/misc/interfaces/IERC165.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {UpdateContractType, UpdateContractMessageLib} from "src/spoke/libraries/UpdateContractMessageLib.sol";

import {IBalanceSheet} from "src/spoke/interfaces/IBalanceSheet.sol";
import {IUpdateContract} from "src/spoke/interfaces/IUpdateContract.sol";

import {IOnOfframpManager} from "src/managers/interfaces/IOnOfframpManager.sol";
import {IOnOfframpManagerFactory} from "src/managers/interfaces/IOnOfframpManagerFactory.sol";
import {IDepositManager, IWithdrawManager} from "src/managers/interfaces/IBalanceSheetManager.sol";

contract OnOfframpManager is IOnOfframpManager {
    using CastLib for *;
    using MathLib for uint256;

    PoolId public immutable poolId;
    address public immutable spoke;
    ShareClassId public immutable scId;
    IBalanceSheet public immutable balanceSheet;

    bool public permissionless;
    mapping(address => bool) public manager;
    mapping(address asset => bool) public onramp;
    mapping(address asset => mapping(address receiver => bool)) public offramp;

    constructor(PoolId poolId_, ShareClassId scId_, address spoke_, IBalanceSheet balanceSheet_) {
        poolId = poolId_;
        scId = scId_;
        spoke = spoke_;
        balanceSheet = balanceSheet_;
    }

    modifier isManager() {
        require(manager[msg.sender], IAuth.NotAuthorized());
        _;
    }

    //----------------------------------------------------------------------------------------------
    // Owner actions
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IUpdateContract
    function update(PoolId poolId_, ShareClassId, /* scId */ bytes calldata payload) external {
        require(poolId == poolId_, InvalidPoolId());
        require(msg.sender == spoke, NotAuthorized());

        uint8 kind = uint8(UpdateContractMessageLib.updateContractType(payload));

        if (kind == uint8(UpdateContractType.UpdateAddress)) {
            UpdateContractMessageLib.UpdateContractUpdateAddress memory m =
                UpdateContractMessageLib.deserializeUpdateContractUpdateAddress(payload);
            address who = m.who.toAddress();

            if (m.kind == "onramp") {
                onramp[who] = m.isEnabled;
                emit UpdateOnramp(who, m.isEnabled);
            } else if (m.kind == "offramp") {
                address asset = m.what.toAddress();
                offramp[asset][who] = m.isEnabled;
                emit UpdateOfframp(asset, who, m.isEnabled);
            }
        } else if (kind == uint8(UpdateContractType.Toggle)) {
            UpdateContractMessageLib.UpdateContractToggle memory m =
                UpdateContractMessageLib.deserializeUpdateContractToggle(payload);

            if (m.what == "permissionless") {
                permissionless = m.isEnabled;
                emit UpdatePermissionless(m.isEnabled);
            }
        } else {
            revert UnknownUpdateContractType();
        }
    }

    //----------------------------------------------------------------------------------------------
    // Deposit & withdraw actions
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IDepositManager
    function deposit(address asset, uint256, /* tokenId */ uint128 amount, address owner) external isManager {
        require(onramp[asset], NotAllowedOnrampAsset());
        require(owner == address(this) || owner == msg.sender);
        require(amount <= IERC20(asset).balanceOf(owner), InvalidAmount());

        balanceSheet.deposit(poolId, scId, asset, 0, amount);
    }

    /// @inheritdoc IWithdrawManager
    function withdraw(address asset, uint256, /* tokenId */ uint128 amount, address receiver) external isManager {
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

contract OnOfframpManagerFactory is IOnOfframpManagerFactory {
    address public immutable spoke;
    IBalanceSheet public immutable balanceSheet;

    constructor(address spoke_, IBalanceSheet balanceSheet_) {
        spoke = spoke_;
        balanceSheet = balanceSheet_;
    }

    /// @inheritdoc IOnOfframpManagerFactory
    function newManager(PoolId poolId, ShareClassId scId) external returns (IOnOfframpManager) {
        OnOfframpManager manager = new OnOfframpManager{salt: keccak256(abi.encode(poolId.raw(), scId.raw()))}(
            poolId, scId, spoke, balanceSheet
        );

        emit DeployOnOfframpManager(poolId, scId, address(manager));
        return IOnOfframpManager(manager);
    }
}
