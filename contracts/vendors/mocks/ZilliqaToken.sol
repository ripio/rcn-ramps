pragma solidity ^0.4.24;

import "./BasicTestToken.sol";


contract ZilliqaToken is MintableToken, StandardBurnableToken {
    string public name = "Zilliqa";
    string public symbol = "ZIL";
    uint8 public decimals = 12;
    uint public totalSupply = 21 * (10 ** 18);

    constructor () public {
        balances[msg.sender] = totalSupply;
    }
}
