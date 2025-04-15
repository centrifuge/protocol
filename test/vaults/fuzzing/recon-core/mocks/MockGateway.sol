// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

contract MockGateway {
    //<>=============================================================<>
    //||                                                             ||
    //||                    NON-VIEW FUNCTIONS                       ||
    //||                                                             ||
    //<>=============================================================<>
    // Mock implementation of deny
    function deny(address user) public {
        
    }

    // Mock implementation of disputeMessageRecovery
    function disputeMessageRecovery(uint16 centrifugeId, address adapter, bytes32 batchHash) public {
        
    }

    // Mock implementation of endBatching
    function endBatching() public {
        
    }

    // Mock implementation of executeMessageRecovery
    function executeMessageRecovery(uint16 centrifugeId, address adapter, bytes memory message) public {
        
    }

    // Mock implementation of file
    function file(bytes32 what, address instance) public {
        
    }

    // Mock implementation of file
    function file(bytes32 what, uint16 centrifugeId, address[] memory addresses) public {
        
    }

    // Mock implementation of handle
    function handle(uint16 centrifugeId, bytes memory payload) public {
        
    }

    // Mock implementation of initiateMessageRecovery
    function initiateMessageRecovery(uint16 centrifugeId, address adapter, bytes32 batchHash) public {
        
    }

    // Mock implementation of payTransaction
    function payTransaction(address payer) public payable {
        
    }

    // Mock implementation of recoverTokens
    function recoverTokens(address token, address receiver, uint256 amount) public {
        
    }

    // Mock implementation of recoverTokens
    function recoverTokens(address token, uint256 tokenId, address receiver, uint256 amount) public {
        
    }

    // Mock implementation of rely
    function rely(address user) public {
        
    }

    // Mock implementation of retry
    function retry(uint16 centrifugeId, bytes memory message) public {
        
    }

    // Mock implementation of send
    function send(uint16 centrifugeId, bytes memory message) public {
        
    }

    // Mock implementation of setRefundAddress
    function setRefundAddress(uint64 poolId, address refund) public {
        
    }

    // Mock implementation of startBatching
    function startBatching() public {
        
    }

    // Mock implementation of subsidizePool
    function subsidizePool(uint64 poolId) public {
        
    }


    //<>=============================================================<>
    //||                                                             ||
    //||                    SETTER FUNCTIONS                         ||
    //||                                                             ||
    //<>=============================================================<>
    // Function to set return values for MAX_ADAPTER_COUNT
    function setMAX_ADAPTER_COUNTReturn(uint8 _value0) public {
        _MAX_ADAPTER_COUNTReturn_0 = _value0;
    }

    // Function to set return values for PRIMARY_ADAPTER_ID
    function setPRIMARY_ADAPTER_IDReturn(uint8 _value0) public {
        _PRIMARY_ADAPTER_IDReturn_0 = _value0;
    }

    // Function to set return values for RECOVERY_CHALLENGE_PERIOD
    function setRECOVERY_CHALLENGE_PERIODReturn(uint256 _value0) public {
        _RECOVERY_CHALLENGE_PERIODReturn_0 = _value0;
    }

    // Function to set return values for activeSessionId
    function setActiveSessionIdReturn(uint64 _value0) public {
        _activeSessionIdReturn_0 = _value0;
    }

    // Function to set return values for adapters
    function setAdaptersReturn(address _value0) public {
        _adaptersReturn_0 = _value0;
    }

    // Function to set return values for batchGasLimit
    function setBatchGasLimitReturn(uint128 _value0) public {
        _batchGasLimitReturn_0 = _value0;
    }

    // Function to set return values for batchLocators
    function setBatchLocatorsReturn(uint16 _value0, uint64 _value1) public {
        _batchLocatorsReturn_0 = _value0;
        _batchLocatorsReturn_1 = _value1;
    }

    // Function to set return values for estimate
    function setEstimateReturn(uint256 _value0) public {
        _estimateReturn_0 = _value0;
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

    // Function to set return values for inboundBatch
    function setInboundBatchReturn(uint64 _value0, bytes memory _value1) public {
        _inboundBatchReturn_0 = _value0;
        _inboundBatchReturn_1 = _value1;
    }

    // Function to set return values for isBatching
    function setIsBatchingReturn(bool _value0) public {
        _isBatchingReturn_0 = _value0;
    }

    // Function to set return values for localCentrifugeId
    function setLocalCentrifugeIdReturn(uint16 _value0) public {
        _localCentrifugeIdReturn_0 = _value0;
    }

    // Function to set return values for outboundBatch
    function setOutboundBatchReturn(bytes memory _value0) public {
        _outboundBatchReturn_0 = _value0;
    }

    // Function to set return values for processor
    function setProcessorReturn(address _value0) public {
        _processorReturn_0 = _value0;
    }

    // Function to set return values for quorum
    function setQuorumReturn(uint8 _value0) public {
        _quorumReturn_0 = _value0;
    }

    // Function to set return values for recoveries
    function setRecoveriesReturn(uint256 _value0) public {
        _recoveriesReturn_0 = _value0;
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

    // Function to set return values for transactionPayer
    function setTransactionPayerReturn(address _value0) public {
        _transactionPayerReturn_0 = _value0;
    }

    // Function to set return values for votes
    function setVotesReturn(uint16[8] memory _value0) public {
        delete _votesReturn_0;
        for(uint i = 0; i < 8; i++) {
            _votesReturn_0[i] = _value0[i];
        }
    }

    // Function to set return values for wards
    function setWardsReturn(uint256 _value0) public {
        _wardsReturn_0 = _value0;
    }


    /*******************************************************************
     *   ⚠️ WARNING ⚠️ WARNING ⚠️ WARNING ⚠️ WARNING ⚠️ WARNING ⚠️  *
     *-----------------------------------------------------------------*
     *      Generally you only need to modify the sections above.      *
     *          The code below handles system operations.              *
     *******************************************************************/

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
    event DisputeMessageRecovery(uint16 centrifugeId, bytes32 batchHash, address adapter);
    event ExecuteMessage(uint16 centrifugeId, bytes message);
    event ExecuteMessageRecovery(uint16 centrifugeId, bytes message, address adapter);
    event FailMessage(uint16 centrifugeId, bytes message, bytes error);
    event File(bytes32 what, uint16 centrifugeId, address[] adapters);
    event File(bytes32 what, address addr);
    event InitiateMessageRecovery(uint16 centrifugeId, bytes32 batchHash, address adapter);
    event PrepareMessage(uint16 centrifugeId, uint64 poolId, bytes message);
    event ProcessBatch(uint16 centrifugeId, bytes32 batchId, bytes batch, address adapter);
    event ProcessProof(uint16 centrifugeId, bytes32 batchId, bytes32 batchHash, address adapter);
    event RecoverMessage(address adapter, bytes message);
    event RecoverProof(address adapter, bytes32 batchHash);
    event Rely(address user);
    event SendBatch(uint16 centrifugeId, bytes32 batchId, bytes batch, address adapter);
    event SendProof(uint16 centrifugeId, bytes32 batchId, bytes proof, address adapter);
    event SetRefundAddress(uint64 poolId, address refund);
    event SubsidizePool(uint64 poolId, address sender, uint256 amount);

    //<>=============================================================<>
    //||                                                             ||
    //||         ⚠️  INTERNAL STORAGE - DO NOT MODIFY  ⚠️           ||
    //||                                                             ||
    //<>=============================================================<>
    uint8 private _MAX_ADAPTER_COUNTReturn_0;
    uint8 private _PRIMARY_ADAPTER_IDReturn_0;
    uint256 private _RECOVERY_CHALLENGE_PERIODReturn_0;
    uint64 private _activeSessionIdReturn_0;
    address private _adaptersReturn_0;
    uint128 private _batchGasLimitReturn_0;
    uint16 private _batchLocatorsReturn_0;
    uint64 private _batchLocatorsReturn_1;
    uint256 private _estimateReturn_0;
    uint256 private _failedMessagesReturn_0;
    uint256 private _fuelReturn_0;
    address private _gasServiceReturn_0;
    uint64 private _inboundBatchReturn_0;
    bytes private _inboundBatchReturn_1;
    bool private _isBatchingReturn_0;
    uint16 private _localCentrifugeIdReturn_0;
    bytes private _outboundBatchReturn_0;
    address private _processorReturn_0;
    uint8 private _quorumReturn_0;
    uint256 private _recoveriesReturn_0;
    address private _rootReturn_0;
    uint96 private _subsidyReturn_0;
    address private _subsidyReturn_1;
    address private _transactionPayerReturn_0;
    uint16[8] private _votesReturn_0;
    uint256 private _wardsReturn_0;

    //<>=============================================================<>
    //||                                                             ||
    //||          ⚠️  VIEW FUNCTIONS - DO NOT MODIFY  ⚠️            ||
    //||                                                             ||
    //<>=============================================================<>
    // Mock implementation of MAX_ADAPTER_COUNT
    function MAX_ADAPTER_COUNT() public view returns (uint8) {
        return _MAX_ADAPTER_COUNTReturn_0;
    }

    // Mock implementation of PRIMARY_ADAPTER_ID
    function PRIMARY_ADAPTER_ID() public view returns (uint8) {
        return _PRIMARY_ADAPTER_IDReturn_0;
    }

    // Mock implementation of RECOVERY_CHALLENGE_PERIOD
    function RECOVERY_CHALLENGE_PERIOD() public view returns (uint256) {
        return _RECOVERY_CHALLENGE_PERIODReturn_0;
    }

    // Mock implementation of activeSessionId
    function activeSessionId(uint16 centrifugeId) public view returns (uint64) {
        return _activeSessionIdReturn_0;
    }

    // Mock implementation of adapters
    function adapters(uint16 centrifugeId, uint256 arg1) public view returns (address) {
        return _adaptersReturn_0;
    }

    // Mock implementation of batchGasLimit
    function batchGasLimit(uint16 centrifugeId, uint64 arg1) public view returns (uint128) {
        return _batchGasLimitReturn_0;
    }

    // Mock implementation of batchLocators
    function batchLocators(uint256 arg0) public view returns (uint16, uint64) {
        return (_batchLocatorsReturn_0, _batchLocatorsReturn_1);
    }

    // Mock implementation of estimate
    function estimate(uint16 centrifugeId, bytes memory payload) public view returns (uint256) {
        return _estimateReturn_0;
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

    // Mock implementation of inboundBatch
    function inboundBatch(uint16 centrifugeId, bytes32 batchHash) public view returns (uint64, bytes memory) {
        return (_inboundBatchReturn_0, _inboundBatchReturn_1);
    }

    // Mock implementation of isBatching
    function isBatching() public view returns (bool) {
        return _isBatchingReturn_0;
    }

    // Mock implementation of localCentrifugeId
    function localCentrifugeId() public view returns (uint16) {
        return _localCentrifugeIdReturn_0;
    }

    // Mock implementation of outboundBatch
    function outboundBatch(uint16 centrifugeId, uint64 arg1) public view returns (bytes memory) {
        return _outboundBatchReturn_0;
    }

    // Mock implementation of processor
    function processor() public view returns (address) {
        return _processorReturn_0;
    }

    // Mock implementation of quorum
    function quorum(uint16 centrifugeId) public view returns (uint8) {
        return _quorumReturn_0;
    }

    // Mock implementation of recoveries
    function recoveries(uint16 centrifugeId, address adapter, bytes32 batchHash) public view returns (uint256) {
        return _recoveriesReturn_0;
    }

    // Mock implementation of root
    function root() public view returns (address) {
        return _rootReturn_0;
    }

    // Mock implementation of subsidy
    function subsidy(uint64 arg0) public view returns (uint96, address) {
        return (_subsidyReturn_0, _subsidyReturn_1);
    }

    // Mock implementation of transactionPayer
    function transactionPayer() public view returns (address) {
        return _transactionPayerReturn_0;
    }

    // Mock implementation of votes
    function votes(uint16 centrifugeId, bytes32 batchHash) public view returns (uint16[8] memory) {
        return _votesReturn_0;
    }

    // Mock implementation of wards
    function wards(address arg0) public view returns (uint256) {
        return _wardsReturn_0;
    }

}