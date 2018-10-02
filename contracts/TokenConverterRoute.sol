pragma solidity ^0.4.24;

import "./interfaces/TokenConverter.sol";
import "./interfaces/AvailableProvider.sol";
import "./interfaces/Token.sol";
import "./utils/Ownable.sol";
import "./vendors/bancor/converter/BancorGasPriceLimit.sol";


contract TokenConverterRoute is TokenConverter, Ownable {
    
    address public constant ETH_ADDRESS = 0x00eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee;
    uint256 constant internal MAX_UINT = uint256(0) - 1;
    TokenConverter[] private converters;
    mapping (address => AvailableProvider) private availability;
    
    function addConverter(TokenConverter converter, AvailableProvider availabilityContract) onlyOwner public {
        converters.push(converter);
        availability[converter] = availabilityContract;        
    }
    
    function removeConverter(address converter) onlyOwner public returns (bool) {
        
        require(converter != address(0), "The address to remove not is available.");
        uint length = converters.length;
        require(length > 0, "Not exist element for remove.");
        
        for (uint i = 0; i < length; i++) {
            if (converters[i] == converter) {
                converters[i] =  converters[length-1];
                require(1 <= length, "Reverts on overflow.");
                converters.length--;
                return true;
            }
        }
        
        return false;
        
    }
    
    function convert(Token _from, Token _to, uint256 _amount, uint256 _minReturn) external payable returns (uint256 amount) {
        address betterProxy = _getBetterProxy(_from, _to, _amount);
        TokenConverter converter =  TokenConverter(betterProxy);
        pullAmount(_from, _amount);
        return converter.convert.value(msg.value)(_from, _to, _amount, _minReturn);   
    }

    function getReturn(Token _from, Token _to, uint256 _amount) external view returns (uint256 amount) {
        address betterProxy = _getBetterProxy(_from, _to, _amount);
        TokenConverter converter =  TokenConverter(betterProxy);
        return converter.getReturn(_from, _to, _amount);
    }
    
    function pullAmount(
        Token token,
        uint256 amount
    ) private {
        if (token == ETH_ADDRESS) {
            require(msg.value >= amount, "Error pulling ETH amount");
        } else {
            require(token.transferFrom(msg.sender, this, amount), "Error pulling Token amount");
        }
    }
    
    function _getBetterProxy(Token _from, Token _to, uint256 _amount) private view returns (address) {
        uint minRate = MAX_UINT;
        address betterProxy = 0x0;
     
        uint length = converters.length;
        for (uint256 i = 0; i < length; i++) {
            
            TokenConverter converter = TokenConverter(converters[i]);
            if (_isAvailable(converter, tx.gasprice)) {
                
                uint newRate = converter.getReturn(_from, _to, _amount);
                if  (newRate > 0 && newRate < minRate) {
                    minRate = newRate;
                    betterProxy = converter;
                }
                
            }
                
        }
        
        return betterProxy;
    }

    function _isAvailable(address converter, uint256 _gasPrice) private view returns (bool) {
        
        if (address(availability[converter]) == address(0x0))
            return AvailableProvider(converter).isAvailable(_gasPrice);            
            
        //bancor workaround
        return (_gasPrice < BancorGasPriceLimit(availability[converter]).gasPrice());
    }

}

contract KyberProxy is TokenConverter, AvailableProvider, Ownable {
  
    uint256 constant internal MAX_UINT = uint256(0) - 1;
    ERC20 constant internal ETH_TOKEN_ADDRESS = ERC20(0x00eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee);

    KyberNetworkProxy kyber;

    event ETHReceived(address indexed sender, uint amount);
    event Swap(address indexed sender, ERC20 srcToken, ERC20 destToken, uint amount);

    constructor (KyberNetworkProxy _kyber) public {
        kyber = _kyber;
    }

    function isAvailable(uint256 gasPrice) external view returns (bool) {
        return gasPrice < kyber.maxGasPrice() && kyber.enabled();
    }

    function getReturn(
        Token from,
        Token to, 
        uint256 srcQty
    ) external view returns (uint256) {
        ERC20 srcToken = ERC20(from);
        ERC20 destToken = ERC20(to);   
        (uint256 amount,) = kyber.getExpectedRate(srcToken, destToken, srcQty);
        return amount;
    }

    function convert(
        Token from,
        Token to, 
        uint256 srcQty, 
        uint256 minReturn
    ) external payable returns (uint256 destAmount) {

        ERC20 srcToken = ERC20(from);
        ERC20 destToken = ERC20(to);       

        if (srcToken == ETH_TOKEN_ADDRESS && destToken != ETH_TOKEN_ADDRESS) {
            require(msg.value == srcQty, "ETH not enought");
            execSwapEtherToToken(srcToken, srcQty, msg.sender);
        } else if (srcToken != ETH_TOKEN_ADDRESS && destToken == ETH_TOKEN_ADDRESS) {
            require(msg.value == 0, "ETH not required");    
            execSwapTokenToEther(srcToken, srcQty, destToken);
        } else {
            require(msg.value == 0, "ETH not required");    
            execSwapTokenToToken(srcToken, srcQty, destToken, msg.sender);
        }

        require(destAmount > minReturn, "Return amount too low");   
        emit Swap(msg.sender, srcToken, destToken, destAmount);
    
        return destAmount;
    }

    /*
    @dev Swap the user's ETH to ERC20 token
    @param token destination token contract address
    @param destAddress address to send swapped tokens to
    */
    function execSwapEtherToToken(
        ERC20 token, 
        uint srcQty,
        address destAddress) 
    internal returns (uint) {

        (uint minConversionRate,) = kyber.getExpectedRate(ETH_TOKEN_ADDRESS, token, srcQty);

        // Swap the ETH to ERC20 token
        uint destAmount = kyber.swapEtherToToken.value(srcQty)(token, minConversionRate);

        // Send the swapped tokens to the destination address
        require(token.transfer(destAddress, destAmount));

        return destAmount;

    }

    /*
    @dev Swap the user's ERC20 token to ETH
    @param token source token contract address
    @param tokenQty amount of source tokens
    @param destAddress address to send swapped ETH to
    */
    function execSwapTokenToEther(
        ERC20 token, 
        uint256 tokenQty, 
        address destAddress
    ) internal returns (uint) {
            
        // Check that the player has transferred the token to this contract
        require(token.transferFrom(msg.sender, this, tokenQty), "Error pulling tokens");

        // Set the spender's token allowance to tokenQty
        require(token.approve(kyber, tokenQty));

        (uint minConversionRate,) = kyber.getExpectedRate(token, ETH_TOKEN_ADDRESS, tokenQty);

        // Swap the ERC20 token to ETH
        uint destAmount = kyber.swapTokenToEther(token, tokenQty, minConversionRate);

        // Send the swapped ETH to the destination address
        destAddress.transfer(destAmount);

        return destAmount;

    }

    /*
    @dev Swap the user's ERC20 token to another ERC20 token
    @param srcToken source token contract address
    @param srcQty amount of source tokens
    @param destToken destination token contract address
    @param destAddress address to send swapped tokens to
    */
    function execSwapTokenToToken(
        ERC20 srcToken, 
        uint256 srcQty, 
        ERC20 destToken, 
        address destAddress
    ) internal returns (uint) {

        // Check that the player has transferred the token to this contract
        require(srcToken.transferFrom(msg.sender, this, srcQty), "Error pulling tokens");

        // Set the spender's token allowance to tokenQty
        require(srcToken.approve(kyber, srcQty));

        (uint minConversionRate,) = kyber.getExpectedRate(srcToken, ETH_TOKEN_ADDRESS, srcQty);

        // Swap the ERC20 token to ERC20
        uint destAmount = kyber.swapTokenToToken(srcToken, srcQty, destToken, minConversionRate);

        // Send the swapped tokens to the destination address
        require(destToken.transfer(destAddress, destAmount));

        return destAmount;
    }

    function withdrawTokens(
        Token _token,
        address _to,
        uint256 _amount
    ) external onlyOwner returns (bool) {
        return _token.transfer(_to, _amount);
    }

    function withdrawEther(
        address _to,
        uint256 _amount
    ) external onlyOwner {
        _to.transfer(_amount);
    }

    function setConverter(
        KyberNetworkProxy _converter
    ) public onlyOwner returns (bool) {
        kyber = _converter;
    }

    function() external payable {
        emit ETHReceived(msg.sender, msg.value);
    }
	
}