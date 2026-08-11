// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IDeployGate} from "./interfaces/IDeployGate.sol";
import {ICreateXLike} from "./interfaces/ICreateXLike.sol";

import {Auth} from "../../misc/Auth.sol";

/// @title  DeployGate
/// @notice Deploys a set of contracts through CreateX CREATE3 in two steps: an admin commits what may be
///         deployed and where, and any of the executors it named then deploys it. Committing is one
///         transaction whatever the contract count, and an executor gains no privilege beyond deploying
///         exactly what was committed.
contract DeployGate is Auth, IDeployGate {
    ICreateXLike public constant CREATE_X = ICreateXLike(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    /// @inheritdoc IDeployGate
    uint256 public nonce;
    /// @inheritdoc IDeployGate
    uint256 public deployed;

    /// @inheritdoc IDeployGate
    mapping(address who => bool canDeploy) public isExecutor;
    mapping(uint256 nonce => mapping(bytes32 salt => bytes32 commitment)) internal _validated;

    constructor(address admin, address governance, address[] memory executors) Auth(admin) {
        require(governance != address(0), NoGovernance());

        wards[governance] = 1;
        emit Rely(governance);

        for (uint256 i; i < executors.length; i++) {
            isExecutor[executors[i]] = true;
            emit UpdateExecutor(executors[i], true);
        }
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IDeployGate
    function updateExecutor(address who, bool canDeploy) external auth {
        isExecutor[who] = canDeploy;
        emit UpdateExecutor(who, canDeploy);
    }

    /// @inheritdoc IDeployGate
    function validate(bytes32[] calldata salts, bytes32[] calldata initCodeHashes) external auth {
        require(salts.length == initCodeHashes.length, LengthMismatch());

        ++nonce;
        deployed = 0;

        for (uint256 i; i < salts.length; i++) {
            require(address(bytes20(salts[i])) == address(this) && salts[i][20] == 0, InvalidSalt(salts[i]));
            // A repeat would leave one commitment behind two events, so the log would stop saying what is
            // enforceable, and only one of the two positions would be reachable
            require(_validated[nonce][salts[i]] == 0, DuplicateSalt(salts[i]));

            _validated[nonce][salts[i]] = commitment(initCodeHashes[i], i);
            emit Validate(salts[i], initCodeHashes[i]);
        }
    }

    //----------------------------------------------------------------------------------------------
    // Deployment
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IDeployGate
    function deploy(bytes32 salt, bytes calldata initCode) external returns (address target) {
        require(isExecutor[msg.sender], NotExecutor());
        require(_validated[nonce][salt] == commitment(keccak256(initCode), deployed), NotValidated(salt));

        delete _validated[nonce][salt];
        ++deployed;

        target = CREATE_X.deployCreate3(salt, initCode);

        emit Deploy(salt, target);
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IDeployGate
    function validated(bytes32 salt) external view returns (bytes32) {
        return _validated[nonce][salt];
    }

    /// @inheritdoc IDeployGate
    function commitment(bytes32 initCodeHash, uint256 index) public pure returns (bytes32) {
        return keccak256(abi.encode(initCodeHash, index));
    }
}
