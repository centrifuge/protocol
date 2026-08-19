// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ICreateXLike} from "./ICreateXLike.sol";

import {IDeployGate} from "../IDeployGate.sol";

/// @title  DeployGate
/// @notice Deploys a set of contracts through CreateX CREATE3 in two steps: a validator commits what may be
///         deployed, where, in what order and by whom, and any of the executors it named then deploys it.
///         Committing is one transaction whatever the contract count, and an executor gains no privilege
///         beyond deploying exactly what was committed.
///
/// @dev    One gate serves everyone: it takes no constructor arguments, holds no privilege of its own, and
///         holds none over anything it deploys, so it is the same contract at the same address on every
///         chain and whoever finds a chain without one deploys it themselves.
///
///         That rests on the gate being deployed through CREATE2, where the address covers the init code,
///         and not through CREATE3, where it does not: a CREATE3 gate address would be code anyone could
///         choose, and this contract's code is the whole of its authority.
contract DeployGate is IDeployGate {
    ICreateXLike public constant CREATE_X = ICreateXLike(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    mapping(address validator => mapping(bytes32 id => uint256)) public nonce;
    mapping(address validator => mapping(bytes32 id => uint256)) public deployed;
    mapping(address validator => mapping(address who => bool)) public isDelegate;
    mapping(address validator => mapping(bytes32 id => mapping(uint256 nonce => mapping(address who => bool)))) internal
        _executor;
    mapping(
        address validator => mapping(bytes32 id => mapping(uint256 nonce => mapping(bytes32 salt => bytes32 hash)))
    ) internal _validated;

    //----------------------------------------------------------------------------------------------
    // Validation
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IDeployGate
    function validate(
        address validator,
        bytes32 id,
        bytes32[] calldata salts,
        bytes32[] calldata initCodeHashes,
        address[] calldata executors
    ) external {
        require(msg.sender == validator || isDelegate[validator][msg.sender], NotValidator());
        require(salts.length == initCodeHashes.length, LengthMismatch());

        uint256 current = ++nonce[validator][id];
        deployed[validator][id] = 0;

        for (uint256 i; i < executors.length; i++) {
            _executor[validator][id][current][executors[i]] = true;
        }

        for (uint256 i; i < salts.length; i++) {
            // A repeat would leave one entry behind two positions in the log, so what it says would stop
            // being what is enforceable, and only one of the two would be reachable
            require(_validated[validator][id][current][salts[i]] == 0, DuplicateSalt(salts[i]));

            _validated[validator][id][current][salts[i]] = commitment(initCodeHashes[i], i);
        }

        // One event for the whole commitment, so that it can be read back from a single log. It carries the
        // generation it opens, which is what everything it grants is keyed by: without it a reader has to
        // count the commitments that came before to know which of them the gate still enforces
        emit Validate(validator, id, current, salts, initCodeHashes, executors);
    }

    /// @inheritdoc IDeployGate
    function setDelegate(address delegatee, bool isValid) external {
        isDelegate[msg.sender][delegatee] = isValid;
        emit SetDelegate(msg.sender, delegatee, isValid);
    }

    //----------------------------------------------------------------------------------------------
    // Deployment
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IDeployGate
    function deploy(address validator, bytes32 id, bytes32 salt, bytes calldata initCode)
        external
        returns (address target)
    {
        uint256 current = nonce[validator][id];
        require(_executor[validator][id][current][msg.sender], NotExecutor());

        bytes32 expected = commitment(keccak256(initCode), deployed[validator][id]);
        require(_validated[validator][id][current][salt] == expected, NotValidated(salt));

        delete _validated[validator][id][current][salt];
        ++deployed[validator][id];

        target = CREATE_X.deployCreate3(createXSalt(validator, salt), initCode);
        emit Deploy(validator, id, current, salt, target);
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IDeployGate
    function isExecutor(address validator, bytes32 id, address who) external view returns (bool) {
        return _executor[validator][id][nonce[validator][id]][who];
    }

    /// @inheritdoc IDeployGate
    function validated(address validator, bytes32 id, bytes32 salt) external view returns (bytes32) {
        return _validated[validator][id][nonce[validator][id]][salt];
    }

    /// @inheritdoc IDeployGate
    function commitment(bytes32 initCodeHash, uint256 index) public pure returns (bytes32) {
        return keccak256(abi.encode(initCodeHash, index));
    }

    /// @inheritdoc IDeployGate
    function createXSalt(address validator, bytes32 salt) public view returns (bytes32) {
        return
            bytes32(
                abi.encodePacked(bytes20(address(this)), bytes1(0x0), bytes11(keccak256(abi.encode(validator, salt))))
            );
    }

    /// @inheritdoc IDeployGate
    function addressOf(address validator, bytes32 salt) external view returns (address) {
        bytes32 guarded = keccak256(abi.encodePacked(uint256(uint160(address(this))), createXSalt(validator, salt)));

        return CREATE_X.computeCreate3Address(guarded);
    }
}
