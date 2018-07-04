pragma solidity ^0.4.19;

import "./interfaces/TokenConverter.sol";
import "./interfaces/NanoLoanEngine.sol";
import "./interfaces/Token.sol";
import "./interfaces/Oracle.sol";
import "./interfaces/Cosigner.sol";

import "./utils/RpSafeMath.sol";

contract EtherRamp {
    using RpSafeMath for uint256;

    uint256 public constant I_MARGIN_SPEND = 0;
    uint256 public constant I_MAX_SPEND = 1;
    uint256 public constant I_REBUY_THRESHOLD = 2;

    uint256 public constant I_ENGINE = 0;
    uint256 public constant I_INDEX = 1;

    uint256 public constant I_PAY_AMOUNT = 2;
    uint256 public constant I_PAY_FROM = 3;

    uint256 public constant I_LEND_COSIGNER = 2;

    function pay(
        TokenConverter converter,
        Token fromToken,
        bytes32[4] memory loanParams,
        bytes oracleData,
        uint256[3] memory convertRules
    ) public payable returns (bool) {
        Token rcn = NanoLoanEngine(address(loanParams[I_ENGINE])).rcn();

        uint256 initialBalance = rcn.balanceOf(this);
        uint256 requiredRcn = getRequiredRcnPay(loanParams, oracleData);

        

        uint256 bought;
        if(msg.value > 0){
            bought = converter.buy.value(msg.value)(rcn, msg.value, 1);

            // Pay loan
            require(
                executeOptimalPay({
                    params: loanParams,
                    oracleData: oracleData,
                    rcnToPay: bought
                })
            );

            // TODO rebuy
            require(rcn.transfer(msg.sender, bought.safeSubtract(requiredRcn)));
        } else {
            uint256 optimalSell = getOptimalSell(converter, fromToken, rcn, requiredRcn, convertRules[I_MARGIN_SPEND]);
            require(fromToken.transferFrom(msg.sender, this, optimalSell));

            bought = convertSafe(converter, fromToken, rcn, optimalSell);

            // Pay loan
            require(
                executeOptimalPay({
                    params: loanParams,
                    oracleData: oracleData,
                    rcnToPay: bought
                })
            );

            require(
                rebuyAndReturn({
                    converter: converter,
                    fromToken: rcn,
                    toToken: fromToken,
                    amount: rcn.balanceOf(this) - initialBalance,
                    spentAmount: optimalSell,
                    convertRules: convertRules
                })
            );
        }

        require(rcn.balanceOf(this) == initialBalance);
        return true;
    }

    function lend(
        TokenConverter converter,
        Token fromToken,
        bytes32[3] memory loanParams,
        bytes oracleData,
        bytes cosignerData,
        uint256[3] memory convertRules
    ) public payable returns (bool) {
        Token rcn = NanoLoanEngine(address(loanParams[I_ENGINE])).rcn();
        uint256 initialBalance = rcn.balanceOf(this);
        uint256 requiredRcn = getRequiredRcnLend(loanParams, oracleData, cosignerData);

        uint256 bought;
        if(msg.value > 0){
            uint256 prevBalance = rcn.balanceOf(this);
            bought = converter.buy.value(msg.value)(rcn, msg.value, 1);
            require(bought == rcn.balanceOf(this) - prevBalance);
            require(lendLoan(loanParams, rcn, bought, oracleData, cosignerData));

            // TODO rebuy
            require(rcn.transfer(msg.sender, bought.safeSubtract(requiredRcn)));
        } else {
            uint256 optimalSell = getOptimalSell(converter, fromToken, rcn, requiredRcn, convertRules[I_MARGIN_SPEND]);
            require(fromToken.transferFrom(msg.sender, this, optimalSell));

            bought = convertSafe(converter, fromToken, rcn, optimalSell);
            require(lendLoan(loanParams, rcn, bought, oracleData, cosignerData));

            require(
                rebuyAndReturn({
                    converter: converter,
                    fromToken: rcn,
                    toToken: fromToken,
                    amount: rcn.balanceOf(this) - initialBalance,
                    spentAmount: optimalSell,
                    convertRules: convertRules
                })
            );
        }

        require(rcn.balanceOf(this) == initialBalance);
        return true;
    }

    function rebuyAndReturn(
        TokenConverter converter,
        Token fromToken,
        Token toToken,
        uint256 amount,
        uint256 spentAmount,
        uint256[3] memory convertRules
    ) internal returns (bool) {
        uint256 threshold = convertRules[I_REBUY_THRESHOLD];
        uint256 bought;
        if (amount != 0) {
            if (amount > threshold) {
                bought = convertSafe(converter, fromToken, toToken, amount);
                require(toToken.transfer(msg.sender, bought));
            } else {
                require(fromToken.transfer(msg.sender, amount));
            }
        }
        uint256 maxSpend = convertRules[I_MAX_SPEND];
        require(bought.safeAdd(spentAmount) <= maxSpend || maxSpend == 0);

        return true;
    }

    function getOptimalSell(
        TokenConverter converter,
        Token fromToken,
        Token toToken,
        uint256 requiredTo,
        uint256 extraSell
    ) internal view returns (uint256 sellAmount) {
        uint256 sellRate = (10 ** 18 * converter.getReturn(toToken, fromToken, requiredTo)) / requiredTo;
        return applyRate(requiredTo, sellRate).safeMult(uint256(100000).safeAdd(extraSell)) / 100000;
    }

    function convertSafe(
        TokenConverter converter,
        Token fromToken,
        Token toToken,
        uint256 amount
    ) internal returns (uint256 bought) {
        require(fromToken.approve(converter, amount));
        uint256 prevBalance = toToken.balanceOf(this);
        uint256 boughtAmount = converter.convert(fromToken, toToken, amount, 1);
        require(boughtAmount == toToken.balanceOf(this) - prevBalance);
        require(fromToken.approve(converter, 0));
        return boughtAmount;
    }

    function executeOptimalPay(
        bytes32[4] memory params,
        bytes oracleData,
        uint256 rcnToPay
    ) internal returns (bool) {
        NanoLoanEngine engine = NanoLoanEngine(address(params[I_ENGINE]));
        uint256 index = uint256(params[I_INDEX]);
        Oracle oracle = engine.getOracle(index);

        uint256 toPay;

        if (oracle == address(0)) {
            toPay = rcnToPay;
        } else {
            uint256 rate;
            uint256 decimals;
            bytes32 currency = engine.getCurrency(index);

            (rate, decimals) = oracle.getRate(currency, oracleData);
            toPay = (rate * rcnToPay * 10 ** (18 - decimals)) / 10 ** 18;
        }

        Token rcn = engine.rcn();
        require(rcn.approve(engine, rcnToPay));
        require(engine.pay(index, toPay, address(params[I_PAY_FROM]), oracleData));
        require(rcn.approve(engine, 0));

        return true;
    }

    function lendLoan(
        bytes32[3] memory loanParams,
        Token rcn,
        uint256 bought,
        bytes oracleData,
        bytes cosignerData
    )internal returns(bool) {
        require(rcn.approve(address(loanParams[I_ENGINE]), bought));
        require(executeLend(loanParams, oracleData, cosignerData));
        require(rcn.approve(address(loanParams[I_ENGINE]), 0));
        require(executeTransfer(loanParams, msg.sender));
        return true;
    }

    function executeLend(
        bytes32[3] memory params,
        bytes oracleData,
        bytes cosignerData
    ) internal returns (bool) {
        NanoLoanEngine engine = NanoLoanEngine(address(params[I_ENGINE]));
        uint256 index = uint256(params[I_INDEX]);
        return engine.lend(index, oracleData, Cosigner(address(params[I_LEND_COSIGNER])), cosignerData);
    }

    function executeTransfer(
        bytes32[3] memory params,
        address to
    ) internal returns (bool) {
        return NanoLoanEngine(address(params[0])).transfer(to, uint256(params[1]));
    }

    function applyRate(
        uint256 amount,
        uint256 rate
    ) pure internal returns (uint256) {
        return amount.safeMult(rate) / 10 ** 18;
    }

    function getRequiredRcnLend(
        bytes32[3] memory params,
        bytes oracleData,
        bytes cosignerData
    ) internal view returns (uint256 required) {
        NanoLoanEngine engine = NanoLoanEngine(address(params[I_ENGINE]));
        uint256 index = uint256(params[I_INDEX]);
        Cosigner cosigner = Cosigner(address(params[I_LEND_COSIGNER]));

        if (cosigner != address(0)) {
            required += cosigner.cost(engine, index, cosignerData, oracleData);
        }
        required += engine.convertRate(engine.getOracle(index), engine.getCurrency(index), oracleData, engine.getAmount(index));
    }

    function getRequiredRcnPay(
        bytes32[4] memory params,
        bytes oracleData
    ) internal view returns (uint256) {
        NanoLoanEngine engine = NanoLoanEngine(address(params[I_ENGINE]));
        uint256 index = uint256(params[I_INDEX]);
        uint256 amount = uint256(params[I_PAY_AMOUNT]);
        return engine.convertRate(engine.getOracle(index), engine.getCurrency(index), oracleData, amount);
    }
}
