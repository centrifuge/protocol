// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DeployPhase} from "../../script/deploy/GatedDeployer.s.sol";
import {LaunchDeployer} from "../../script/deploy/LaunchDeployer.s.sol";

import "forge-std/Test.sol";

contract RevokedContract {
    uint256 public value;

    constructor(uint256 value_) {
        value = value_;
    }
}

contract LaunchDeployerTest is Test, LaunchDeployer {
    function _executors() internal view returns (address[] memory executors) {
        executors = new address[](1);
        executors[0] = address(this);
    }

    function _initCode(uint256 value) internal pure returns (bytes memory) {
        return abi.encodePacked(type(RevokedContract).creationCode, abi.encode(value));
    }

    function commitAs(string memory deploymentId_) external {
        _initGated(deploymentId_, DeployPhase.Commit, address(this), _executors());
        uint256 snapshot = vm.snapshotState();

        submit("revokedContract", "v3.1", _initCode(1));
        (bytes32[] memory salts, bytes32[] memory initCodeHashes) = _queuedCommitment();

        vm.revertToState(snapshot);
        _commit(salts, initCodeHashes);
    }

    function deployAs(string memory deploymentId_) external returns (address) {
        _initGated(deploymentId_, DeployPhase.Deploy, address(this), _executors());
        return submit("revokedContract", "v3.1", _initCode(1));
    }

    function revokeAs(string memory deploymentId_) external {
        _revoke(deploymentId_, address(this));
    }
}

contract LaunchDeployerTestRevoke is LaunchDeployerTest {
    function setUp() public {
        this.commitAs("");
        this.commitAs("rev2");
    }

    function testRevokingAnIsolatedDeploymentKeepsTheCanonicalOne() public {
        this.revokeAs("rev2");

        assertGt(this.deployAs("").code.length, 0, "the canonical commitment is still deployable");
        vm.expectRevert("Deployment does not match what was committed, commit again");
        this.deployAs("rev2");
    }

    function testRevokingTheCanonicalDeploymentKeepsAnIsolatedOne() public {
        this.revokeAs("");

        assertGt(this.deployAs("rev2").code.length, 0, "the isolated commitment is still deployable");
        vm.expectRevert("Deployment does not match what was committed, commit again");
        this.deployAs("");
    }
}
