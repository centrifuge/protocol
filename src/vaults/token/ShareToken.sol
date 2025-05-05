// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "src/misc/ERC20.sol";
import {IERC20, IERC20Metadata} from "src/misc/interfaces/IERC20.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {IERC7575Share, IERC165} from "src/misc/interfaces/IERC7575.sol";

import {
    IHook,
    HookData,
    SUCCESS_CODE_ID,
    SUCCESS_MESSAGE,
    ERROR_CODE_ID,
    ERROR_MESSAGE
} from "src/common/interfaces/IHook.sol";
import {IShareToken, IERC1404} from "src/vaults/interfaces/token/IShareToken.sol";

/// @title  Share Token
/// @notice Extension of ERC20 + ERC1404,
///         integrating an external hook optionally for ERC20 callbacks and ERC1404 checks.
contract ShareToken is ERC20, IShareToken {
    using MathLib for uint256;

    mapping(address => Balance) private balances;

    /// @inheritdoc IShareToken
    address public hook;

    /// @inheritdoc IERC7575Share
    mapping(address asset => address) public vault;

    constructor(uint8 decimals_) ERC20(decimals_) {}

    modifier authOrHook() {
        require(wards[msg.sender] == 1 || msg.sender == hook, NotAuthorizedOrHook());
        _;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IShareToken
    function file(bytes32 what, address data) external authOrHook {
        if (what == "hook") hook = data;
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    /// @inheritdoc IShareToken
    function file(bytes32 what, string memory data) public override(ERC20, IShareToken) auth {
        super.file(what, data);
    }

    /// @inheritdoc IShareToken
    function updateVault(address asset, address vault_) external auth {
        vault[asset] = vault_;
        emit VaultUpdate(asset, vault_);
    }

    //----------------------------------------------------------------------------------------------
    // ERC-20 overrides
    //----------------------------------------------------------------------------------------------

    function _balanceOf(address user) internal view override returns (uint256) {
        return balances[user].amount;
    }

    function _setBalance(address user, uint256 value) internal override {
        balances[user].amount = value.toUint128();
    }

    /// @inheritdoc IShareToken
    function hookDataOf(address user) public view returns (bytes16) {
        return balances[user].hookData;
    }

    /// @inheritdoc IShareToken
    function setHookData(address user, bytes16 hookData) public authOrHook {
        balances[user].hookData = hookData;
        emit SetHookData(user, hookData);
    }

    /// @inheritdoc IERC20
    function transfer(address to, uint256 value) public override(ERC20, IERC20) returns (bool success) {
        success = super.transfer(to, value);
        _onTransfer(msg.sender, to, value);
    }

    /// @inheritdoc IERC20
    function transferFrom(address from, address to, uint256 value)
        public
        override(ERC20, IERC20)
        returns (bool success)
    {
        success = super.transferFrom(from, to, value);
        _onTransfer(from, to, value);
    }

    /// @inheritdoc IShareToken
    function mint(address to, uint256 value) public override(ERC20, IShareToken) {
        super.mint(to, value);
        require(totalSupply <= type(uint128).max, ExceedsMaxSupply());
        _onTransfer(address(0), to, value);
    }

    /// @inheritdoc IShareToken
    function burn(address from, uint256 value) public override(ERC20, IShareToken) {
        super.burn(from, value);
        _onTransfer(from, address(0), value);
    }

    function _onTransfer(address from, address to, uint256 value) internal {
        address hook_ = hook;
        require(
            hook_ == address(0)
                || IHook(hook_).onERC20Transfer(from, to, value, HookData(hookDataOf(from), hookDataOf(to)))
                    == IHook.onERC20Transfer.selector,
            RestrictionsFailed()
        );
    }

    /// @inheritdoc IShareToken
    function authTransferFrom(address sender, address from, address to, uint256 value)
        public
        auth
        returns (bool success)
    {
        success = _transferFrom(sender, from, to, value);
        address hook_ = hook;
        if (hook_ != address(0)) {
            IHook(hook_).onERC20AuthTransfer(sender, from, to, value, HookData(hookDataOf(from), hookDataOf(to)));
        }
    }

    //----------------------------------------------------------------------------------------------
    // ERC-1404
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IShareToken
    function checkTransferRestriction(address from, address to, uint256 value) public view returns (bool) {
        return detectTransferRestriction(from, to, value) == SUCCESS_CODE_ID;
    }

    /// @inheritdoc IERC1404
    function detectTransferRestriction(address from, address to, uint256 value) public view returns (uint8) {
        address hook_ = hook;
        if (hook_ == address(0)) return SUCCESS_CODE_ID;
        return IHook(hook_).checkERC20Transfer(from, to, value, HookData(hookDataOf(from), hookDataOf(to)))
            ? SUCCESS_CODE_ID
            : ERROR_CODE_ID;
    }

    /// @inheritdoc IERC1404
    function messageForTransferRestriction(uint8 restrictionCode) external pure returns (string memory) {
        return restrictionCode == SUCCESS_CODE_ID ? SUCCESS_MESSAGE : ERROR_MESSAGE;
    }

    //----------------------------------------------------------------------------------------------
    // ERC-165
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC7575Share).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
