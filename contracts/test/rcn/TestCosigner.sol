pragma solidity ^0.4.19;

import "./../../interfaces/NanoLoanEngine.sol";
import "./../../interfaces/Engine.sol";
import "./../../interfaces/Cosigner.sol";
import "./../../interfaces/Oracle.sol";

contract TestCosigner is Cosigner {
    function url() public view returns (string) {}

    function cost(address engine, uint256 index, bytes data, bytes oracleData) public view returns (uint256) {
        return _cost(NanoLoanEngine(engine), index, data, oracleData);
    }
    
    function _cost(NanoLoanEngine engine, uint256 index, bytes, bytes oracleData) internal returns (uint256) {
        return engine.convertRate(engine.getOracle(index), engine.getCurrency(index), oracleData, engine.getAmount(index)) / 100;
    }

    function requestCosign(Engine engine, uint256 index, bytes data, bytes oracleData) public returns (bool) {
        return engine.cosign(index, cost(engine, index, data, oracleData));
    }
    
    function claim(address, uint256, bytes) public returns (bool) { }
}