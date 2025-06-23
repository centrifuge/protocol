// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

contract MockGateway {
    //<>=============================================================<>
    //||                                                             ||
    //||                    NON-VIEW FUNCTIONS                       ||
    //||                                                             ||
    //<>=============================================================<>
    // Mock implementation of addUnpaidMessage
    function addUnpaidMessage(uint16 centrifugeId, bytes memory message) public {}

    // Mock implementation of deny
    function deny(address user) public {}

    // Mock implementation of endBatching
    function endBatching() public {}

    // Mock implementation of endTransactionPayment
    function endTransactionPayment() public {}

    // Mock implementation of file
    function file(bytes32 what, address instance) public {}

    // Mock implementation of handle
    function handle(uint16 centrifugeId, bytes memory batch) public {}

    // Mock implementation of recoverTokens
    function recoverTokens(address token, address receiver, uint256 amount) public {}

    // Mock implementation of recoverTokens
    function recoverTokens(address token, uint256 tokenId, address receiver, uint256 amount) public {}

    // Mock implementation of rely
    function rely(address user) public {}

    // Mock implementation of repay
    function repay(uint16 centrifugeId, bytes memory batch) public payable {}

    // Mock implementation of retry
    function retry(uint16 centrifugeId, bytes memory message) public {}

    // Mock implementation of send
    function send(uint16 centrifugeId, bytes memory message) public {}

    // Mock implementation of setRefundAddress
    function setRefundAddress(uint64 poolId, address refund) public {}

    // Mock implementation of startBatching
    function startBatching() public {}

    // Mock implementation of startTransactionPayment
    function startTransactionPayment(address payer) public payable {}

    // Mock implementation of subsidizePool
    function subsidizePool(uint64 poolId) public payable {}

    receive() external payable {}

    //<>=============================================================<>
    //||                                                             ||
    //||                    SETTER FUNCTIONS                         ||
    //||                                                             ||
    //<>=============================================================<>
    // Function to set return values for BATCH_LOCATORS_SLOT
    function setBATCH_LOCATORS_SLOTReturn(bytes32 _value0) public {
        _BATCH_LOCATORS_SLOTReturn_0 = _value0;
    }

    // Function to set return values for GLOBAL_POT
    function setGLOBAL_POTReturn(uint64 _value0) public {
        _GLOBAL_POTReturn_0 = _value0;
    }

    // Function to set return values for adapter
    function setAdapterReturn(address _value0) public {
        _adapterReturn_0 = _value0;
    }

    // Function to set return values for failedMessages
    function setFailedMessagesReturn(uint256 _value0) public {
        _failedMessagesReturn_0 = _value0;
    }

    // Function to set return values for fuel
    function setFuelReturn(uint256 _value0) public {
        _fuelReturn_0 = _value0;
    }

    // Function to set return values for gasService
    function setGasServiceReturn(address _value0) public {
        _gasServiceReturn_0 = _value0;
    }

    // Function to set return values for isBatching
    function setIsBatchingReturn(bool _value0) public {
        _isBatchingReturn_0 = _value0;
    }

    // Function to set return values for processor
    function setProcessorReturn(address _value0) public {
        _processorReturn_0 = _value0;
    }

    // Function to set return values for root
    function setRootReturn(address _value0) public {
        _rootReturn_0 = _value0;
    }

    // Function to set return values for subsidy
    function setSubsidyReturn(uint96 _value0, address _value1) public {
        _subsidyReturn_0 = _value0;
        _subsidyReturn_1 = _value1;
    }

    // Function to set return values for transactionRefund
    function setTransactionRefundReturn(address _value0) public {
        _transactionRefundReturn_0 = _value0;
    }

    // Function to set return values for underpaid
    function setUnderpaidReturn(uint128 _value0, uint128 _value1) public {
        _underpaidReturn_0 = _value0;
        _underpaidReturn_1 = _value1;
    }

    // Function to set return values for wards
    function setWardsReturn(uint256 _value0) public {
        _wardsReturn_0 = _value0;
    }

    /**
     *
     *   ⚠️ WARNING ⚠️ WARNING ⚠️ WARNING ⚠️ WARNING ⚠️ WARNING ⚠️  *
     * -----------------------------------------------------------------*
     *      Generally you only need to modify the sections above.      *
     *          The code below handles system operations.              *
     *
     */

    //<>=============================================================<>
    //||                                                             ||
    //||        ⚠️  STRUCT DEFINITIONS - DO NOT MODIFY  ⚠️          ||
    //||                                                             ||
    //<>=============================================================<>

    //<>=============================================================<>
    //||                                                             ||
    //||        ⚠️  EVENTS DEFINITIONS - DO NOT MODIFY  ⚠️          ||
    //||                                                             ||
    //<>=============================================================<>
    event Deny(address user);
    event ExecuteMessage(uint16 centrifugeId, bytes message);
    event FailMessage(uint16 centrifugeId, bytes message, bytes error);
    event File(bytes32 what, address addr);
    event PrepareMessage(uint16 centrifugeId, uint64 poolId, bytes message);
    event Rely(address user);
    event RepayBatch(uint16 centrifugeId, bytes batch);
    event SetRefundAddress(uint64 poolId, address refund);
    event SubsidizePool(uint64 poolId, address sender, uint256 amount);
    event UnderpaidBatch(uint16 centrifugeId, bytes batch);

    //<>=============================================================<>
    //||                                                             ||
    //||         ⚠️  INTERNAL STORAGE - DO NOT MODIFY  ⚠️           ||
    //||                                                             ||
    //<>=============================================================<>
    bytes32 private _BATCH_LOCATORS_SLOTReturn_0;
    uint64 private _GLOBAL_POTReturn_0;
    address private _adapterReturn_0;
    uint256 private _failedMessagesReturn_0;
    uint256 private _fuelReturn_0;
    address private _gasServiceReturn_0;
    bool private _isBatchingReturn_0;
    address private _processorReturn_0;
    address private _rootReturn_0;
    uint96 private _subsidyReturn_0;
    address private _subsidyReturn_1;
    address private _transactionRefundReturn_0;
    uint128 private _underpaidReturn_0;
    uint128 private _underpaidReturn_1;
    uint256 private _wardsReturn_0;

    //<>=============================================================<>
    //||                                                             ||
    //||          ⚠️  VIEW FUNCTIONS - DO NOT MODIFY  ⚠️            ||
    //||                                                             ||
    //<>=============================================================<>
    // Mock implementation of BATCH_LOCATORS_SLOT
    function BATCH_LOCATORS_SLOT() public view returns (bytes32) {
        return _BATCH_LOCATORS_SLOTReturn_0;
    }

    // Mock implementation of GLOBAL_POT
    function GLOBAL_POT() public view returns (uint64) {
        return _GLOBAL_POTReturn_0;
    }

    // Mock implementation of adapter
    function adapter() public view returns (address) {
        return _adapterReturn_0;
    }

    // Mock implementation of failedMessages
    function failedMessages(uint16 centrifugeId, bytes32 messageHash) public view returns (uint256) {
        return _failedMessagesReturn_0;
    }

    // Mock implementation of fuel
    function fuel() public view returns (uint256) {
        return _fuelReturn_0;
    }

    // Mock implementation of gasService
    function gasService() public view returns (address) {
        return _gasServiceReturn_0;
    }

    // Mock implementation of isBatching
    function isBatching() public view returns (bool) {
        return _isBatchingReturn_0;
    }

    // Mock implementation of processor
    function processor() public view returns (address) {
        return _processorReturn_0;
    }

    // Mock implementation of root
    function root() public view returns (address) {
        return _rootReturn_0;
    }

    // Mock implementation of subsidy
    function subsidy(uint64 arg0) public view returns (uint96, address) {
        return (_subsidyReturn_0, _subsidyReturn_1);
    }

    // Mock implementation of transactionRefund
    function transactionRefund() public view returns (address) {
        return _transactionRefundReturn_0;
    }

    // Mock implementation of underpaid
    function underpaid(uint16 centrifugeId, bytes32 batchHash) public view returns (uint128, uint128) {
        return (_underpaidReturn_0, _underpaidReturn_1);
    }

    // Mock implementation of wards
    function wards(address arg0) public view returns (uint256) {
        return _wardsReturn_0;
    }
}
