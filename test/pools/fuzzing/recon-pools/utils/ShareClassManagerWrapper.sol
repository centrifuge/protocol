import {ShareClassManager} from "src/hub/ShareClassManager.sol";
import {IHubRegistry} from "src/hub/interfaces/IHubRegistry.sol";

/// @dev Wrapper so we can reset the epoch increment for testing
contract ShareClassManagerWrapper is ShareClassManager {
    constructor(IHubRegistry hubRegistry, address deployer) ShareClassManager(hubRegistry, deployer) {
        hubRegistry = hubRegistry;
    }

    /// @dev We need to reset the epoch increment for shortcut functions which make multiple calls to the share class in the same transaction
    /// since these calls don't reset the epoch increment as would normally be done with multiple transactions we need to manually reset it here
    function setEpochIncrement(uint32 epochIncrement) public {
        _epochIncrement = epochIncrement;
    }
}