// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title LMSRMath
/// @notice Logarithmic Market Scoring Rule pricing math using WAD-based fixed-point arithmetic.
/// @dev C(q) = b·ln(Σ exp(qᵢ/b)), where b = funding/ln(N). Prices = softmax.
library LMSRMath {
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for int256;

    int256 internal constant WAD = 1e18;

    error InvalidNumOutcomes();
    error ZeroFunding();
    error ArrayLengthMismatch();
    error InvalidDecimals();
    error InvalidOutcomeIndex();
    error InsufficientLiquidity();

    /// @notice Compute the LMSR cost function C(q) = b·ln(Σ exp(qᵢ/b))
    /// @param quantities Token quantities per outcome (in token decimals)
    /// @param funding Market funding amount (in token decimals)
    /// @param decimals Token decimal places (e.g. 6 for USDC)
    /// @return cost The cost value in token decimals
    function calcCostFunction(
        uint256[] memory quantities,
        uint256 funding,
        uint8 decimals
    ) internal pure returns (uint256 cost) {
        uint256 n = quantities.length;
        _validateInputs(n, funding, decimals);

        int256 bWad = _computeB(funding, n, decimals);
        int256 scale = int256(10 ** uint256(decimals));

        // Find max quantity and compute shifted exponential sum
        uint256 maxQ = _max(quantities);
        int256 maxQWad = int256(maxQ) * WAD / scale;

        uint256 sumExp = _sumExpShifted(quantities, maxQ, bWad, scale);

        // C(q) = maxQ + b * ln(Σ exp((qᵢ - maxQ)/b))
        int256 lnSum = FixedPointMathLib.lnWad(int256(sumExp));
        int256 costWad = maxQWad + _sMulWad(bWad, lnSum);

        cost = uint256(costWad) * uint256(scale) / uint256(WAD);
    }

    /// @notice Compute the marginal price (softmax) for a given outcome
    /// @param quantities Token quantities per outcome (in token decimals)
    /// @param funding Market funding amount (in token decimals)
    /// @param outcomeIndex Index of the outcome to price
    /// @param decimals Token decimal places
    /// @return price WAD-scaled price [0, 1e18]
    function calcMarginalPrice(
        uint256[] memory quantities,
        uint256 funding,
        uint256 outcomeIndex,
        uint8 decimals
    ) internal pure returns (uint256 price) {
        uint256 n = quantities.length;
        _validateInputs(n, funding, decimals);
        if (outcomeIndex >= n) revert InvalidOutcomeIndex();

        int256 bWad = _computeB(funding, n, decimals);
        int256 scale = int256(10 ** uint256(decimals));

        uint256 minQ = _min(quantities);

        uint256 sumExp = _sumExpShiftedNeg(quantities, minQ, bWad, scale);

        // price_i = exp((minQ - q_i) / b) / sumExp  (negated convention)
        int256 diff = (int256(minQ) - int256(quantities[outcomeIndex])) * WAD / scale;
        int256 ratio = diff * WAD / bWad;
        uint256 expVal = uint256(FixedPointMathLib.expWad(ratio));

        price = expVal.mulWad(uint256(WAD)) * uint256(WAD) / sumExp;
    }

    /// @notice Compute the net cost of a trade: C(q + delta) - C(q)
    /// @param balances Current token balances per outcome
    /// @param amounts Trade amounts per outcome (positive=buy, negative=sell)
    /// @param funding Market funding amount
    /// @param decimals Token decimal places
    /// @param roundUp If true, round in favor of the protocol
    /// @return netCost Signed cost (positive=trader pays, negative=trader receives)
    function calcNetCost(
        uint256[] memory balances,
        int256[] memory amounts,
        uint256 funding,
        uint8 decimals,
        bool roundUp
    ) internal pure returns (int256 netCost) {
        uint256 n = balances.length;
        if (n != amounts.length) revert ArrayLengthMismatch();
        _validateInputs(n, funding, decimals);

        int256 bWad = _computeB(funding, n, decimals);
        int256 scale = int256(10 ** uint256(decimals));

        // Build signed vectors: qBefore = -balances, qAfter = amounts - balances
        int256[] memory qBefore = new int256[](n);
        int256[] memory qAfter = new int256[](n);
        for (uint256 i; i < n; ++i) {
            qBefore[i] = -int256(balances[i]);
            qAfter[i] = amounts[i] - int256(balances[i]);
        }

        int256 costBefore = _costFunctionWadSigned(qBefore, bWad, scale);
        int256 costAfter = _costFunctionWadSigned(qAfter, bWad, scale);
        int256 netCostWad = costAfter - costBefore;
        netCost = netCostWad * scale / WAD;

        if (roundUp && netCost > 0) {
            // If there's a fractional remainder, round up
            if (netCostWad * scale != netCost * WAD) {
                netCost += 1;
            }
        }
    }

    /// @notice Compute the marginal price for a binary market (sigmoid)
    /// @param balanceYes YES outcome token quantity
    /// @param balanceNo NO outcome token quantity
    /// @param funding Market funding amount
    /// @param decimals Token decimal places
    /// @return price WAD-scaled price of YES outcome [0, 1e18]
    function calcMarginalPriceBinary(
        uint256 balanceYes,
        uint256 balanceNo,
        uint256 funding,
        uint8 decimals
    ) internal pure returns (uint256 price) {
        if (funding == 0) revert ZeroFunding();
        if (decimals == 0 || decimals > 18) revert InvalidDecimals();

        int256 scale = int256(10 ** uint256(decimals));
        int256 lnTwo = FixedPointMathLib.lnWad(2 * WAD);
        int256 bWad = int256(funding) * WAD / scale * WAD / lnTwo;

        // price_yes = exp(qY/b) / (exp(qY/b) + exp(qN/b))
        // With offset: subtract max(qY, qN)/b
        int256 diff = (int256(balanceNo) - int256(balanceYes)) * WAD / scale;
        int256 ratio = diff * WAD / bWad;

        // price = exp(ratio) / (exp(ratio) + exp(0)) when qY >= qN (ratio ≥ 0)
        // price = exp(0) / (exp(0) + exp(-ratio)) when qN > qY (ratio < 0)
        // Unified: price = 1 / (1 + exp(-ratio)) = exp(ratio) / (1 + exp(ratio))

        // Use offset trick for numerical stability
        if (ratio >= 0) {
            // exp(0) / (exp(0) + exp(-ratio)) = 1 / (1 + exp(-ratio))
            uint256 expNeg = uint256(FixedPointMathLib.expWad(-ratio));
            price = uint256(WAD).divWad(uint256(WAD) + expNeg);
        } else {
            // exp(ratio) / (exp(ratio) + exp(0)) = exp(ratio) / (exp(ratio) + 1)
            uint256 expPos = uint256(FixedPointMathLib.expWad(ratio));
            price = expPos.divWad(expPos + uint256(WAD));
        }
    }

    /// @notice Compute the net cost for a binary market trade
    /// @param balanceYes Current YES quantity
    /// @param balanceNo Current NO quantity
    /// @param deltaYes YES trade amount (positive=buy, negative=sell)
    /// @param deltaNo NO trade amount (positive=buy, negative=sell)
    /// @param funding Market funding amount
    /// @param decimals Token decimal places
    /// @param roundUp If true, round in favor of the protocol
    /// @return netCost Signed cost
    function calcNetCostBinary(
        uint256 balanceYes,
        uint256 balanceNo,
        int256 deltaYes,
        int256 deltaNo,
        uint256 funding,
        uint8 decimals,
        bool roundUp
    ) internal pure returns (int256 netCost) {
        uint256[] memory quantities = new uint256[](2);
        quantities[0] = balanceYes;
        quantities[1] = balanceNo;

        int256[] memory amounts = new int256[](2);
        amounts[0] = deltaYes;
        amounts[1] = deltaNo;

        netCost = calcNetCost(quantities, amounts, funding, decimals, roundUp);
    }

    /// @notice Compute the trade amount for a binary market given collateral
    /// @param balanceYes Current YES token balance
    /// @param balanceNo Current NO token balance
    /// @param amount Positive = collateral to spend (buy), negative = collateral to get back by selling (sell)
    /// @param outcomeIndex 0 = YES, 1 = NO
    /// @param funding Market funding amount
    /// @param decimals Token decimal places
    /// @return result Tokens received (buy) or tokens to sell (sell), rounded down
    function calcTradeAmountBinary(
        uint256 balanceYes,
        uint256 balanceNo,
        int256 amount,
        uint256 outcomeIndex,
        uint256 funding,
        uint8 decimals
    ) internal pure returns (uint256 result) {
        if (funding == 0) revert ZeroFunding();
        if (decimals == 0 || decimals > 18) revert InvalidDecimals();
        if (outcomeIndex > 1) revert InvalidOutcomeIndex();
        if (amount == 0) return 0;

        int256 scale = int256(10 ** uint256(decimals));
        int256 lnTwo = FixedPointMathLib.lnWad(2 * WAD);
        int256 bWad = int256(funding) * WAD / scale * WAD / lnTwo;

        (uint256 sPrime, uint256 ejPrime) =
            _computeSumAndOutcomeExpBinary(balanceYes, balanceNo, outcomeIndex, bWad, scale);

        if (amount > 0) {
            // Buy: δ = b·ln((S'·exp(c/b) - S' + E_j') / E_j')
            int256 cOverB = int256(uint256(amount)) * WAD / scale * WAD / bWad;
            uint256 expCB = uint256(FixedPointMathLib.expWad(cOverB));

            uint256 numerator = sPrime.mulWad(expCB) - sPrime + ejPrime;

            int256 lnRatio =
                FixedPointMathLib.lnWad(int256(numerator)) - FixedPointMathLib.lnWad(int256(ejPrime));

            int256 deltaWad = _sMulWad(bWad, lnRatio);
            result = uint256(deltaWad) * uint256(scale) / uint256(WAD);
        } else {
            // Sell inverse: given collateral c to get back, find tokens δ to sell
            // δ = -b·ln((S'·exp(-c/b) - S' + E_j') / E_j')
            int256 negCOverB = -int256(uint256(-amount)) * WAD / scale * WAD / bWad;
            uint256 expNCB = uint256(FixedPointMathLib.expWad(negCOverB));

            uint256 sPrimeScaled = sPrime.mulWad(expNCB);
            if (ejPrime + sPrimeScaled < sPrime) revert InsufficientLiquidity();
            uint256 numerator = ejPrime + sPrimeScaled - sPrime;

            int256 lnRatio =
                FixedPointMathLib.lnWad(int256(ejPrime)) - FixedPointMathLib.lnWad(int256(numerator));

            int256 deltaWad = _sMulWad(bWad, lnRatio);
            result = uint256(deltaWad) * uint256(scale) / uint256(WAD);
        }
    }

    // ─── Internal Helpers ───────────────────────────────────────────────

    function _validateInputs(uint256 n, uint256 funding, uint8 decimals) private pure {
        if (n < 2) revert InvalidNumOutcomes();
        if (funding == 0) revert ZeroFunding();
        if (decimals == 0 || decimals > 18) revert InvalidDecimals();
    }

    /// @dev Compute b = funding / ln(N) in WAD
    function _computeB(uint256 funding, uint256 n, uint8 decimals) private pure returns (int256) {
        int256 scale = int256(10 ** uint256(decimals));
        int256 fundingWad = int256(funding) * WAD / scale;
        int256 lnN = FixedPointMathLib.lnWad(int256(n) * WAD);
        return fundingWad * WAD / lnN;
    }

    /// @dev Find maximum value in array
    function _max(uint256[] memory arr) private pure returns (uint256 m) {
        for (uint256 i; i < arr.length; ++i) {
            if (arr[i] > m) m = arr[i];
        }
    }

    /// @dev Compute Σ exp((qᵢ - maxQ) / b) using offset trick for overflow safety
    function _sumExpShifted(
        uint256[] memory quantities,
        uint256 maxQ,
        int256 bWad,
        int256 scale
    ) private pure returns (uint256 sumExp) {
        for (uint256 i; i < quantities.length; ++i) {
            int256 diff = (int256(quantities[i]) - int256(maxQ)) * WAD / scale;
            int256 ratio = diff * WAD / bWad;
            int256 expVal = FixedPointMathLib.expWad(ratio);
            sumExp += uint256(expVal);
        }
    }

    /// @dev Signed mulWad: (x * y) / WAD for int256
    function _sMulWad(int256 x, int256 y) private pure returns (int256) {
        return FixedPointMathLib.sMulWad(x, y);
    }

    /// @dev Compute cost function returning WAD-precision result (for rounding)
    function _costFunctionWad(
        uint256[] memory quantities,
        int256 bWad,
        int256 scale
    ) private pure returns (int256) {
        uint256 maxQ = _max(quantities);
        int256 maxQWad = int256(maxQ) * WAD / scale;

        uint256 sumExp = _sumExpShifted(quantities, maxQ, bWad, scale);

        int256 lnSum = FixedPointMathLib.lnWad(int256(sumExp));
        return maxQWad + _sMulWad(bWad, lnSum);
    }

    /// @dev Find minimum value in array
    function _min(uint256[] memory arr) private pure returns (uint256 m) {
        m = arr[0];
        for (uint256 i = 1; i < arr.length; ++i) {
            if (arr[i] < m) m = arr[i];
        }
    }

    /// @dev Compute Σ exp((minQ - qᵢ) / b) — negated convention offset trick
    function _sumExpShiftedNeg(
        uint256[] memory quantities,
        uint256 minQ,
        int256 bWad,
        int256 scale
    ) private pure returns (uint256 sumExp) {
        for (uint256 i; i < quantities.length; ++i) {
            int256 diff = (int256(minQ) - int256(quantities[i])) * WAD / scale;
            int256 ratio = diff * WAD / bWad;
            int256 expVal = FixedPointMathLib.expWad(ratio);
            sumExp += uint256(expVal);
        }
    }

    /// @dev Find maximum value in signed array
    function _maxSigned(int256[] memory arr) private pure returns (int256 m) {
        m = arr[0];
        for (uint256 i = 1; i < arr.length; ++i) {
            if (arr[i] > m) m = arr[i];
        }
    }

    /// @dev Compute Σ exp((qᵢ - maxQ) / b) for signed inputs
    function _sumExpShiftedSigned(
        int256[] memory quantities,
        int256 maxQ,
        int256 bWad,
        int256 scale
    ) private pure returns (uint256 sumExp) {
        for (uint256 i; i < quantities.length; ++i) {
            int256 diff = (quantities[i] - maxQ) * WAD / scale;
            int256 ratio = diff * WAD / bWad;
            int256 expVal = FixedPointMathLib.expWad(ratio);
            sumExp += uint256(expVal);
        }
    }

    /// @dev Compute cost function C(q) for signed inputs, returning WAD precision
    function _costFunctionWadSigned(
        int256[] memory quantities,
        int256 bWad,
        int256 scale
    ) private pure returns (int256) {
        int256 maxQ = _maxSigned(quantities);
        int256 maxQWad = maxQ * WAD / scale;

        uint256 sumExp = _sumExpShiftedSigned(quantities, maxQ, bWad, scale);

        int256 lnSum = FixedPointMathLib.lnWad(int256(sumExp));
        return maxQWad + _sMulWad(bWad, lnSum);
    }

    /// @dev Compute shifted sum S' and outcome exp E_j' for binary market
    /// Uses offset trick: factor out exp(-minBal/b) so all exponents are ≤ 0
    function _computeSumAndOutcomeExpBinary(
        uint256 balanceYes,
        uint256 balanceNo,
        uint256 outcomeIndex,
        int256 bWad,
        int256 scale
    ) private pure returns (uint256 sPrime, uint256 ejPrime) {
        uint256 minBal = balanceYes < balanceNo ? balanceYes : balanceNo;

        int256 ratioYes = -int256(balanceYes - minBal) * WAD / scale * WAD / bWad;
        uint256 expYes = uint256(FixedPointMathLib.expWad(ratioYes));

        int256 ratioNo = -int256(balanceNo - minBal) * WAD / scale * WAD / bWad;
        uint256 expNo = uint256(FixedPointMathLib.expWad(ratioNo));

        sPrime = expYes + expNo;
        ejPrime = outcomeIndex == 0 ? expYes : expNo;
    }
}
