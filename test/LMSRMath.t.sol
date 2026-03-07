// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LMSRMath} from "../src/LMSRMath.sol";

/// @dev Wrapper contract to expose library functions for testing
contract LMSRMathHarness {
    function calcCostFunction(
        uint256[] memory quantities,
        uint256 funding,
        uint8 decimals
    ) external pure returns (uint256) {
        return LMSRMath.calcCostFunction(quantities, funding, decimals);
    }

    function calcMarginalPrice(
        uint256[] memory quantities,
        uint256 funding,
        uint256 outcomeIndex,
        uint8 decimals
    ) external pure returns (uint256) {
        return LMSRMath.calcMarginalPrice(quantities, funding, outcomeIndex, decimals);
    }

    function calcNetCost(
        uint256[] memory quantities,
        int256[] memory amounts,
        uint256 funding,
        uint8 decimals,
        bool roundUp
    ) external pure returns (int256) {
        return LMSRMath.calcNetCost(quantities, amounts, funding, decimals, roundUp);
    }

    function calcMarginalPriceBinary(
        uint256 balanceYes,
        uint256 balanceNo,
        uint256 funding,
        uint8 decimals
    ) external pure returns (uint256) {
        return LMSRMath.calcMarginalPriceBinary(balanceYes, balanceNo, funding, decimals);
    }

    function calcNetCostBinary(
        uint256 balanceYes,
        uint256 balanceNo,
        int256 deltaYes,
        int256 deltaNo,
        uint256 funding,
        uint8 decimals,
        bool roundUp
    ) external pure returns (int256) {
        return LMSRMath.calcNetCostBinary(balanceYes, balanceNo, deltaYes, deltaNo, funding, decimals, roundUp);
    }

    function calcTradeAmountBinary(
        uint256 balanceYes,
        uint256 balanceNo,
        int256 amount,
        uint256 outcomeIndex,
        uint256 funding,
        uint8 decimals
    ) external pure returns (uint256) {
        return LMSRMath.calcTradeAmountBinary(balanceYes, balanceNo, amount, outcomeIndex, funding, decimals);
    }
}

contract LMSRMathTest is Test {
    LMSRMathHarness h;

    uint256 constant FUNDING_100 = 100e6; // 100 USDC
    uint8 constant DEC6 = 6;

    function setUp() public {
        h = new LMSRMathHarness();
    }

    // ═══════════════════════════════════════════════════════════════════
    // Phase 1: calcCostFunction
    // ═══════════════════════════════════════════════════════════════════

    function test_costFunction_uniformZero() public view {
        // C([0,0]) = b·ln(2·exp(0)) = (funding/ln2)·ln2 = funding
        uint256[] memory q = _arr(0, 0);
        uint256 cost = h.calcCostFunction(q, FUNDING_100, DEC6);
        assertApproxEqAbs(cost, FUNDING_100, 1, "C([0,0]) should equal funding");
    }

    function test_costFunction_uniformNonzero() public view {
        // C([q,q]) = q + funding for any q
        uint256 q = 50e6;
        uint256[] memory quantities = _arr(q, q);
        uint256 cost = h.calcCostFunction(quantities, FUNDING_100, DEC6);
        assertApproxEqAbs(cost, q + FUNDING_100, 1, "C([q,q]) should equal q + funding");
    }

    function test_costFunction_monotonicity() public view {
        // C([100e6, 0]) > C([0, 0])
        uint256[] memory q0 = _arr(0, 0);
        uint256[] memory q1 = _arr(100e6, 0);
        uint256 cost0 = h.calcCostFunction(q0, FUNDING_100, DEC6);
        uint256 cost1 = h.calcCostFunction(q1, FUNDING_100, DEC6);
        assertGt(cost1, cost0, "cost should increase with quantity");
    }

    function test_costFunction_revert_InvalidNumOutcomes() public {
        uint256[] memory q = new uint256[](1);
        vm.expectRevert(LMSRMath.InvalidNumOutcomes.selector);
        h.calcCostFunction(q, FUNDING_100, DEC6);
    }

    function test_costFunction_revert_ZeroFunding() public {
        uint256[] memory q = _arr(0, 0);
        vm.expectRevert(LMSRMath.ZeroFunding.selector);
        h.calcCostFunction(q, 0, DEC6);
    }

    function test_costFunction_revert_InvalidDecimals_zero() public {
        uint256[] memory q = _arr(0, 0);
        vm.expectRevert(LMSRMath.InvalidDecimals.selector);
        h.calcCostFunction(q, FUNDING_100, 0);
    }

    function test_costFunction_revert_InvalidDecimals_tooLarge() public {
        uint256[] memory q = _arr(0, 0);
        vm.expectRevert(LMSRMath.InvalidDecimals.selector);
        h.calcCostFunction(q, FUNDING_100, 19);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Phase 2: calcMarginalPrice
    // ═══════════════════════════════════════════════════════════════════

    function test_marginalPrice_uniform() public view {
        // quantities=[0,0], N=2 → each price = 0.5e18
        uint256[] memory q = _arr(0, 0);
        uint256 price0 = h.calcMarginalPrice(q, FUNDING_100, 0, DEC6);
        uint256 price1 = h.calcMarginalPrice(q, FUNDING_100, 1, DEC6);
        assertApproxEqAbs(price0, 0.5e18, 2, "uniform price should be 0.5");
        assertApproxEqAbs(price1, 0.5e18, 2, "uniform price should be 0.5");
    }

    function test_marginalPrice_sumToOne() public view {
        uint256[] memory q = _arr(100e6, 0);
        uint256 price0 = h.calcMarginalPrice(q, FUNDING_100, 0, DEC6);
        uint256 price1 = h.calcMarginalPrice(q, FUNDING_100, 1, DEC6);
        assertApproxEqAbs(price0 + price1, 1e18, 2, "prices should sum to 1e18");
    }

    function test_marginalPrice_skew() public view {
        uint256[] memory q = _arr(100e6, 0);
        uint256 price0 = h.calcMarginalPrice(q, FUNDING_100, 0, DEC6);
        uint256 price1 = h.calcMarginalPrice(q, FUNDING_100, 1, DEC6);
        assertLt(price0, 0.5e18, "higher balance -> lower price");
        assertGt(price1, 0.5e18, "lower balance -> higher price");
    }

    function test_marginalPrice_threeOutcomes() public view {
        uint256[] memory q = _arr3(0, 0, 0);
        uint256 price0 = h.calcMarginalPrice(q, FUNDING_100, 0, DEC6);
        uint256 price1 = h.calcMarginalPrice(q, FUNDING_100, 1, DEC6);
        uint256 price2 = h.calcMarginalPrice(q, FUNDING_100, 2, DEC6);
        uint256 expected = 333333333333333333; // 1/3 in WAD
        assertApproxEqAbs(price0, expected, 2);
        assertApproxEqAbs(price1, expected, 2);
        assertApproxEqAbs(price2, expected, 2);
        assertApproxEqAbs(price0 + price1 + price2, 1e18, 3);
    }

    function test_marginalPrice_revert_InvalidOutcomeIndex() public {
        uint256[] memory q = _arr(0, 0);
        vm.expectRevert(LMSRMath.InvalidOutcomeIndex.selector);
        h.calcMarginalPrice(q, FUNDING_100, 2, DEC6);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Phase 3: calcNetCost
    // ═══════════════════════════════════════════════════════════════════

    function test_netCost_zeroDelta() public view {
        uint256[] memory q = _arr(50e6, 30e6);
        int256[] memory amounts = _iArr(0, 0);
        int256 cost = h.calcNetCost(q, amounts, FUNDING_100, DEC6, false);
        assertEq(cost, 0, "zero delta -> zero cost");
    }

    function test_netCost_buyYes() public view {
        // Buy 10e6 YES from [0,0], funding=100e6
        uint256[] memory q = _arr(0, 0);
        int256[] memory amounts = _iArr(10e6, 0);
        int256 cost = h.calcNetCost(q, amounts, FUNDING_100, DEC6, false);
        assertGt(cost, 0, "buying should cost positive");
    }

    function test_netCost_sell() public view {
        // Sell YES from [10e6, 0]
        uint256[] memory q = _arr(10e6, 0);
        int256[] memory amounts = _iArr(-5e6, 0);
        int256 cost = h.calcNetCost(q, amounts, FUNDING_100, DEC6, false);
        assertLt(cost, 0, "selling should return negative cost");
    }

    function test_netCost_consistency() public view {
        // Buying both outcomes equally should cost ~amount (like a split)
        uint256[] memory q = _arr(20e6, 10e6);
        int256[] memory amounts = _iArr(5e6, 5e6);
        int256 netCost = h.calcNetCost(q, amounts, FUNDING_100, DEC6, false);
        // Equal buy of both outcomes ≈ funding-neutral, cost ≈ amount
        assertApproxEqRel(netCost, 5e6, 0.01e18);
    }

    function test_netCost_roundUp() public view {
        uint256[] memory q = _arr(0, 0);
        int256[] memory amounts = _iArr(10e6, 0);
        int256 costDown = h.calcNetCost(q, amounts, FUNDING_100, DEC6, false);
        int256 costUp = h.calcNetCost(q, amounts, FUNDING_100, DEC6, true);
        assertGe(costUp, costDown, "roundUp >= roundDown");
        assertLe(costUp - costDown, 1, "differ by at most 1");
    }

    function test_netCost_revert_ArrayLengthMismatch() public {
        uint256[] memory q = _arr(0, 0);
        int256[] memory amounts = new int256[](3);
        vm.expectRevert(LMSRMath.ArrayLengthMismatch.selector);
        h.calcNetCost(q, amounts, FUNDING_100, DEC6, false);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Phase 4: calcMarginalPriceBinary
    // ═══════════════════════════════════════════════════════════════════

    function test_binaryPrice_uniform() public view {
        uint256 price = h.calcMarginalPriceBinary(0, 0, FUNDING_100, DEC6);
        assertApproxEqAbs(price, 0.5e18, 2, "uniform binary price should be 0.5");
    }

    function test_binaryPrice_matchesGeneral() public view {
        uint256 balY = 80e6;
        uint256 balN = 30e6;
        uint256[] memory q = _arr(balY, balN);
        uint256 generalPrice = h.calcMarginalPrice(q, FUNDING_100, 0, DEC6);
        uint256 binaryPrice = h.calcMarginalPriceBinary(balY, balN, FUNDING_100, DEC6);
        assertApproxEqAbs(binaryPrice, generalPrice, 2, "binary should match general N=2");
    }

    function test_binaryPrice_extremeYes() public view {
        // Large YES balance -> price near 0 (negated: more held = cheaper)
        uint256 price = h.calcMarginalPriceBinary(500e6, 0, FUNDING_100, DEC6);
        assertLt(price, 0.05e18, "extreme YES balance -> price near 0");
        uint256 price2 = h.calcMarginalPriceBinary(1000e6, 0, FUNDING_100, DEC6);
        assertLt(price2, 0.01e18, "very extreme YES balance -> price < 0.01");
    }

    function test_binaryPrice_extremeNo() public view {
        // Large NO balance -> YES price near 1 (negated: less NO held = YES expensive)
        uint256 price = h.calcMarginalPriceBinary(0, 500e6, FUNDING_100, DEC6);
        assertGt(price, 0.95e18, "extreme NO balance -> YES price near 1");
        uint256 price2 = h.calcMarginalPriceBinary(0, 1000e6, FUNDING_100, DEC6);
        assertGt(price2, 0.99e18, "very extreme NO balance -> YES price > 0.99");
    }

    function test_binaryPrice_complementsToOne() public view {
        uint256 priceYes = h.calcMarginalPriceBinary(40e6, 20e6, FUNDING_100, DEC6);
        // price_no = 1 - price_yes
        uint256 priceNo = 1e18 - priceYes;
        // Verify via general function
        uint256[] memory q = _arr(40e6, 20e6);
        uint256 generalNo = h.calcMarginalPrice(q, FUNDING_100, 1, DEC6);
        assertApproxEqAbs(priceNo, generalNo, 2);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Phase 5: calcNetCostBinary
    // ═══════════════════════════════════════════════════════════════════

    function test_binaryNetCost_zeroDelta() public view {
        int256 cost = h.calcNetCostBinary(50e6, 30e6, 0, 0, FUNDING_100, DEC6, false);
        assertEq(cost, 0, "zero delta -> zero cost");
    }

    function test_binaryNetCost_matchesGeneral() public view {
        uint256 balY = 20e6;
        uint256 balN = 10e6;
        int256 dY = 5e6;
        int256 dN = 0;

        int256 binaryCost = h.calcNetCostBinary(balY, balN, dY, dN, FUNDING_100, DEC6, false);

        uint256[] memory q = _arr(balY, balN);
        int256[] memory amounts = _iArr(dY, dN);
        int256 generalCost = h.calcNetCost(q, amounts, FUNDING_100, DEC6, false);

        assertEq(binaryCost, generalCost, "binary should match general N=2");
    }

    function test_binaryNetCost_rounding() public view {
        int256 costDown = h.calcNetCostBinary(0, 0, 10e6, 0, FUNDING_100, DEC6, false);
        int256 costUp = h.calcNetCostBinary(0, 0, 10e6, 0, FUNDING_100, DEC6, true);
        assertGe(costUp, costDown);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Phase 5b: calcTradeAmountBinary
    // ═══════════════════════════════════════════════════════════════════

    function test_tradeAmount_buyRoundTrip() public view {
        // Buy: given 10 USDC collateral, how many YES tokens?
        // Then verify: calcNetCostBinary with that delta ≈ 10 USDC
        uint256 collateral = 10e6;
        uint256 tokensOut = h.calcTradeAmountBinary(0, 0, int256(collateral), 0, FUNDING_100, DEC6);
        assertGt(tokensOut, 0, "should get tokens");

        // Round-trip: buying tokensOut YES should cost ~collateral
        int256 cost = h.calcNetCostBinary(0, 0, int256(tokensOut), 0, FUNDING_100, DEC6, false);
        assertApproxEqAbs(uint256(cost), collateral, 1, "round-trip buy should match");
    }

    function test_tradeAmount_sellRoundTrip() public view {
        // Starting from [50e6, 0], sell 10e6 YES tokens
        uint256 tokensToSell = 10e6;
        uint256 collateralOut = h.calcTradeAmountBinary(50e6, 0, -int256(tokensToSell), 0, FUNDING_100, DEC6);
        assertGt(collateralOut, 0, "should get collateral");

        // Round-trip: selling tokensToSell YES should yield ~collateralOut
        int256 cost = h.calcNetCostBinary(50e6, 0, -int256(tokensToSell), 0, FUNDING_100, DEC6, false);
        assertApproxEqAbs(uint256(-cost), collateralOut, 1, "round-trip sell should match");
    }

    function test_tradeAmount_buySymmetric() public view {
        // Equal balances → buying YES and NO with same collateral should give same tokens
        uint256 collateral = 20e6;
        uint256 tokensYes = h.calcTradeAmountBinary(0, 0, int256(collateral), 0, FUNDING_100, DEC6);
        uint256 tokensNo = h.calcTradeAmountBinary(0, 0, int256(collateral), 1, FUNDING_100, DEC6);
        assertEq(tokensYes, tokensNo, "symmetric balances -> symmetric tokens");
    }

    function test_tradeAmount_buyMoreThanCollateral() public view {
        // At 50/50 price, tokens received > collateral (LMSR property)
        uint256 collateral = 10e6;
        uint256 tokens = h.calcTradeAmountBinary(0, 0, int256(collateral), 0, FUNDING_100, DEC6);
        assertGt(tokens, collateral, "tokens > collateral at fair price");
    }

    function test_tradeAmount_zeroAmount() public view {
        uint256 result = h.calcTradeAmountBinary(0, 0, 0, 0, FUNDING_100, DEC6);
        assertEq(result, 0, "zero amount -> zero result");
    }

    function test_tradeAmount_buyNo() public view {
        // Buy NO tokens and round-trip verify
        uint256 collateral = 15e6;
        uint256 tokensOut = h.calcTradeAmountBinary(30e6, 10e6, int256(collateral), 1, FUNDING_100, DEC6);
        assertGt(tokensOut, 0);

        int256 cost = h.calcNetCostBinary(30e6, 10e6, 0, int256(tokensOut), FUNDING_100, DEC6, false);
        assertApproxEqAbs(uint256(cost), collateral, 1, "round-trip buy NO should match");
    }

    function test_tradeAmount_sellNo() public view {
        uint256 tokensToSell = 5e6;
        uint256 collateralOut = h.calcTradeAmountBinary(10e6, 50e6, -int256(tokensToSell), 1, FUNDING_100, DEC6);
        assertGt(collateralOut, 0);

        int256 cost = h.calcNetCostBinary(10e6, 50e6, 0, -int256(tokensToSell), FUNDING_100, DEC6, false);
        assertApproxEqAbs(uint256(-cost), collateralOut, 1, "round-trip sell NO should match");
    }

    function test_tradeAmount_revert_InvalidOutcomeIndex() public {
        vm.expectRevert(LMSRMath.InvalidOutcomeIndex.selector);
        h.calcTradeAmountBinary(0, 0, 10e6, 2, FUNDING_100, DEC6);
    }

    function test_tradeAmount_revert_ZeroFunding() public {
        vm.expectRevert(LMSRMath.ZeroFunding.selector);
        h.calcTradeAmountBinary(0, 0, 10e6, 0, 0, DEC6);
    }

    function test_tradeAmount_asymmetricBalances() public view {
        // With high YES balance (cheap YES), buying YES should give more tokens per collateral
        uint256 collateral = 10e6;
        uint256 tokensFair = h.calcTradeAmountBinary(0, 0, int256(collateral), 0, FUNDING_100, DEC6);
        uint256 tokensCheap = h.calcTradeAmountBinary(100e6, 0, int256(collateral), 0, FUNDING_100, DEC6);
        assertGt(tokensCheap, tokensFair, "cheaper outcome -> more tokens per collateral");
    }

    function testFuzz_tradeAmount_buyRoundTrip(uint256 balY, uint256 balN, uint256 collateral) public view {
        balY = bound(balY, 0, 500e6);
        balN = bound(balN, 0, 500e6);
        collateral = bound(collateral, 1e4, 200e6);

        uint256 tokensOut = h.calcTradeAmountBinary(balY, balN, int256(collateral), 0, FUNDING_100, DEC6);
        int256 cost = h.calcNetCostBinary(balY, balN, int256(tokensOut), 0, FUNDING_100, DEC6, false);
        assertApproxEqAbs(uint256(cost), collateral, 2, "fuzz: buy round-trip");
    }

    function testFuzz_tradeAmount_sellRoundTrip(uint256 balY, uint256 balN, uint256 tokensToSell) public view {
        balY = bound(balY, 10e6, 500e6);
        balN = bound(balN, 0, 500e6);
        tokensToSell = bound(tokensToSell, 1e4, balY / 2);

        uint256 collateralOut =
            h.calcTradeAmountBinary(balY, balN, -int256(tokensToSell), 0, FUNDING_100, DEC6);
        int256 cost = h.calcNetCostBinary(balY, balN, -int256(tokensToSell), 0, FUNDING_100, DEC6, false);
        assertApproxEqAbs(uint256(-cost), collateralOut, 2, "fuzz: sell round-trip");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Phase 6: Edge cases, large values, fuzz
    // ═══════════════════════════════════════════════════════════════════

    function test_largeQuantities_smallFunding() public view {
        // Large quantities with small funding — offset trick prevents overflow
        uint256[] memory q = _arr(1e12, 0);
        uint256 cost = h.calcCostFunction(q, 1e6, DEC6);
        // Cost should be at least max(q) since C ≥ max(q)
        assertGe(cost, 1e12);
    }

    function test_decimals8() public view {
        // 8 decimals (like WBTC)
        uint256 funding8 = 100e8;
        uint256[] memory q = _arr(0, 0);
        uint256 cost = h.calcCostFunction(q, funding8, 8);
        assertApproxEqAbs(cost, funding8, 1);
    }

    function test_decimals18() public view {
        // 18 decimals (like WETH)
        uint256 funding18 = 100e18;
        uint256[] memory q = _arr(0, 0);
        uint256 cost = h.calcCostFunction(q, funding18, 18);
        assertApproxEqAbs(cost, funding18, 1e6); // wider tolerance for 18 dec
    }

    function test_fourOutcomes() public view {
        uint256 funding = 100e6;
        uint256[] memory q = new uint256[](4);
        // All zeros
        uint256 cost = h.calcCostFunction(q, funding, DEC6);
        assertApproxEqAbs(cost, funding, 1);

        // Prices should all be 0.25
        for (uint256 i; i < 4; ++i) {
            uint256 price = h.calcMarginalPrice(q, funding, i, DEC6);
            assertApproxEqAbs(price, 0.25e18, 2);
        }
    }

    function test_convexity() public view {
        // Buying 10e6 from [100e6, 0] costs more than from [0, 0]
        uint256[] memory q0 = _arr(0, 0);
        uint256[] memory q1 = _arr(100e6, 0);
        int256[] memory buy = _iArr(10e6, 0);

        int256 cost0 = h.calcNetCost(q0, buy, FUNDING_100, DEC6, false);
        int256 cost1 = h.calcNetCost(q1, buy, FUNDING_100, DEC6, false);
        assertLt(cost1, cost0, "higher balance = more held = cheaper to buy more");
    }

    function testFuzz_pricesSumToOne(uint256 q0, uint256 q1) public view {
        q0 = bound(q0, 0, 1e12);
        q1 = bound(q1, 0, 1e12);
        uint256[] memory q = _arr(q0, q1);

        uint256 p0 = h.calcMarginalPrice(q, FUNDING_100, 0, DEC6);
        uint256 p1 = h.calcMarginalPrice(q, FUNDING_100, 1, DEC6);
        assertApproxEqAbs(p0 + p1, 1e18, 10, "prices should sum to ~1e18");
    }

    function testFuzz_zeroDeltaReturnsZero(uint256 q0, uint256 q1) public view {
        q0 = bound(q0, 0, 1e12);
        q1 = bound(q1, 0, 1e12);
        uint256[] memory q = _arr(q0, q1);
        int256[] memory amounts = _iArr(0, 0);
        int256 cost = h.calcNetCost(q, amounts, FUNDING_100, DEC6, false);
        assertEq(cost, 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════════════════════

    function _arr(uint256 a, uint256 b) internal pure returns (uint256[] memory) {
        uint256[] memory arr = new uint256[](2);
        arr[0] = a;
        arr[1] = b;
        return arr;
    }

    function _arr3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory) {
        uint256[] memory arr = new uint256[](3);
        arr[0] = a;
        arr[1] = b;
        arr[2] = c;
        return arr;
    }

    function _iArr(int256 a, int256 b) internal pure returns (int256[] memory) {
        int256[] memory arr = new int256[](2);
        arr[0] = a;
        arr[1] = b;
        return arr;
    }
}
