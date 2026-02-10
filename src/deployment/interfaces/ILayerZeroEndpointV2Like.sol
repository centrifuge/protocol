// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

struct SetConfigParam {
    uint32 eid;
    uint32 configType; // 1 for Executor config, 2 for ULN config
    bytes config;
}

struct UlnConfig {
    uint64 confirmations;
    // we store the length of required DVNs and optional DVNs instead of using DVN.length directly to save gas
    uint8 requiredDVNCount; // 0 indicate DEFAULT, NIL_DVN_COUNT indicate NONE (to override the value of default)
    uint8 optionalDVNCount; // 0 indicate DEFAULT, NIL_DVN_COUNT indicate NONE (to override the value of default)
    uint8 optionalDVNThreshold; // (0, optionalDVNCount]
    address[] requiredDVNs; // no duplicates. sorted an an ascending order. allowed overlap with optionalDVNs
    address[] optionalDVNs; // no duplicates. sorted an an ascending order. allowed overlap with requiredDVNs
}

interface ILayerZeroEndpointV2Like {
    /// @notice Delegate is authorized by the oapp to configure anything in layerzero
    function setDelegate(address _delegate) external;

    /// @notice Get the delegate address for an oapp
    function delegates(address oapp) external view returns (address);

    /// @notice Set configuration
    function setConfig(address _oapp, address _lib, SetConfigParam[] calldata _params) external;

    /// @notice Get default send library for an endpoint id
    function defaultSendLibrary(uint32 _eid) external view returns (address);

    /// @notice Get default receive library for an endpoint id
    function defaultReceiveLibrary(uint32 _eid) external view returns (address);

    /// @notice Set the send library for an oapp and eid
    function setSendLibrary(address _oapp, uint32 _eid, address _newLib) external;

    /// @notice Set the receive library for an oapp and eid
    function setReceiveLibrary(address _oapp, uint32 _eid, address _newLib, uint256 _gracePeriod) external;
}
