// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Auth} from "./Auth.sol";
import {EIP712Lib} from "./libraries/EIP712Lib.sol";
import {SignatureLib} from "./libraries/SignatureLib.sol";
import {IERC20, IERC20Metadata, IERC20Permit} from "./interfaces/IERC20.sol";

/// @title  ERC20
/// @notice Standard ERC-20 implementation, with mint/burn functionality and permit logic.
/// @author Modified from https://github.com/makerdao/xdomain-dss/blob/master/src/Dai.sol
contract ERC20 is Auth, IERC20Metadata, IERC20Permit {
    event File(bytes32 indexed what, string data);

    error FileUnrecognizedParam();

    // Metadata
    string public name;
    string public symbol;
    uint8 public immutable decimals;

    // Balances
    uint256 public totalSupply;
    mapping(address => uint256) private balances;
    mapping(address => mapping(address => uint256)) public allowance;

    // EIP-712
    bytes32 private immutable nameHash;
    bytes32 private immutable versionHash;
    mapping(address => uint256) public nonces;
    uint256 public immutable deploymentChainId;
    bytes32 private immutable _DOMAIN_SEPARATOR;
    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    constructor(uint8 decimals_) Auth(msg.sender) {
        decimals = decimals_;

        nameHash = keccak256(bytes("Centrifuge"));
        versionHash = keccak256(bytes("1"));
        deploymentChainId = block.chainid;
        _DOMAIN_SEPARATOR = EIP712Lib.calculateDomainSeparator(nameHash, versionHash);
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    function file(bytes32 what, string memory data) public virtual auth {
        if (what == "name") name = data;
        else if (what == "symbol") symbol = data;
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    //----------------------------------------------------------------------------------------------
    // ERC20 balances
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC20
    function balanceOf(address user) public view virtual returns (uint256) {
        return _balanceOf(user);
    }

    function _balanceOf(address user) internal view virtual returns (uint256) {
        return balances[user];
    }

    function _setBalance(address user, uint256 value) internal virtual {
        balances[user] = value;
    }

    //----------------------------------------------------------------------------------------------
    // ERC20 mutations
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC20
    function transfer(address to, uint256 value) public virtual returns (bool) {
        require(to != address(0) && to != address(this), InvalidAddress());
        uint256 balance = balanceOf(msg.sender);
        require(balance >= value, InsufficientBalance());

        unchecked {
            _setBalance(msg.sender, balance - value);
            // We don't need an overflow check here b/c sum of all balances == totalSupply
            _setBalance(to, _balanceOf(to) + value);
        }

        emit Transfer(msg.sender, to, value);

        return true;
    }

    /// @inheritdoc IERC20
    function transferFrom(address from, address to, uint256 value) public virtual returns (bool) {
        return _transferFrom(msg.sender, from, to, value);
    }

    function _transferFrom(address sender, address from, address to, uint256 value) internal virtual returns (bool) {
        require(to != address(0) && to != address(this), InvalidAddress());
        uint256 balance = balanceOf(from);
        require(balance >= value, InsufficientBalance());

        if (from != sender) {
            uint256 allowed = allowance[from][sender];
            if (allowed != type(uint256).max) {
                require(allowed >= value, InsufficientAllowance());
                unchecked {
                    allowance[from][sender] = allowed - value;
                }
            }
        }

        unchecked {
            _setBalance(from, balance - value);
            // We don't need an overflow check here b/c sum of all balances == totalSupply
            _setBalance(to, _balanceOf(to) + value);
        }

        emit Transfer(from, to, value);

        return true;
    }

    /// @inheritdoc IERC20
    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;

        emit Approval(msg.sender, spender, value);

        return true;
    }

    //----------------------------------------------------------------------------------------------
    // Mint/burn
    //----------------------------------------------------------------------------------------------

    function mint(address to, uint256 value) public virtual auth {
        require(to != address(0) && to != address(this), InvalidAddress());
        unchecked {
            // We don't need an overflow check here b/c balances[to] <= totalSupply
            // and there is an overflow check below
            _setBalance(to, _balanceOf(to) + value);
        }
        totalSupply += value;

        emit Transfer(address(0), to, value);
    }

    function burn(address from, uint256 value) public virtual auth {
        uint256 balance = balanceOf(from);
        require(balance >= value, InsufficientBalance());

        if (from != msg.sender) {
            uint256 allowed = allowance[from][msg.sender];
            if (allowed != type(uint256).max) {
                require(allowed >= value, InsufficientAllowance());

                unchecked {
                    allowance[from][msg.sender] = allowed - value;
                }
            }
        }

        unchecked {
            // We don't need overflow checks b/c require(balance >= value) and balance <= totalSupply
            _setBalance(from, balance - value);
            totalSupply -= value;
        }

        emit Transfer(from, address(0), value);
    }

    //----------------------------------------------------------------------------------------------
    // Permit
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC20Permit
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        permit(owner, spender, value, deadline, abi.encodePacked(r, s, v));
    }

    function permit(address owner, address spender, uint256 value, uint256 deadline, bytes memory signature) public {
        require(block.timestamp <= deadline, PermitExpired());

        uint256 nonce;
        unchecked {
            nonce = nonces[owner]++;
        }

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR(),
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline))
            )
        );

        require(SignatureLib.isValidSignature(owner, digest, signature), InvalidPermit());

        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    /// @inheritdoc IERC20Permit
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return block.chainid == deploymentChainId
            ? _DOMAIN_SEPARATOR
            : EIP712Lib.calculateDomainSeparator(nameHash, versionHash);
    }
}
