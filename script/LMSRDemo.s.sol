// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {LMSRMath} from "../src/LMSRMath.sol";

contract LMSRDemo is Script {
    using LMSRMath for *;

    uint8 constant DECIMALS = 6;
    uint256 constant FUNDING = 100e6;

    function run() external pure {
        uint256[] memory q;
        int256[] memory amounts;
        int256 netCost;

        // === Scenario 1: Buy YES from uniform zero balances ===
        console.log("=== Scenario 1: Buy YES from uniform zero balances ===");
        q = _arr(0, 0);
        amounts = _iArr(int256(10e6), 0);
        console.log("  balances = [0, 0], amounts = [10e6, 0]");
        console.log("  C([0,0]) =");
        console.logInt(int256(LMSRMath.calcCostFunction(q, FUNDING, DECIMALS)));
        netCost = LMSRMath.calcNetCost(q, amounts, FUNDING, DECIMALS, true);
        console.log("  netCost =");
        console.logInt(netCost);

        // === Scenario 2: Buy NO from uniform zero balances ===
        console.log("=== Scenario 2: Buy NO from uniform zero balances ===");
        q = _arr(0, 0);
        amounts = _iArr(0, int256(10e6));
        console.log("  balances = [0, 0], amounts = [0, 10e6]");
        netCost = LMSRMath.calcNetCost(q, amounts, FUNDING, DECIMALS, true);
        console.log("  netCost =");
        console.logInt(netCost);

        // === Scenario 3: Buy YES from skewed balances ===
        console.log("=== Scenario 3: Buy YES from skewed balances ===");
        q = _arr(80e6, 20e6);
        amounts = _iArr(int256(10e6), 0);
        console.log("  balances = [80e6, 20e6], amounts = [10e6, 0]");
        console.log("  C([80e6, 20e6]) =");
        console.logInt(int256(LMSRMath.calcCostFunction(q, FUNDING, DECIMALS)));
        netCost = LMSRMath.calcNetCost(q, amounts, FUNDING, DECIMALS, true);
        console.log("  netCost =");
        console.logInt(netCost);

        // === Scenario 4: Sell YES ===
        console.log("=== Scenario 4: Sell YES ===");
        q = _arr(50e6, 10e6);
        amounts = _iArr(-int256(20e6), 0);
        console.log("  balances = [50e6, 10e6], amounts = [-20e6, 0]");
        netCost = LMSRMath.calcNetCost(q, amounts, FUNDING, DECIMALS, false);
        console.log("  netCost =");
        console.logInt(netCost);

        // === Scenario 5: Buy both (split-like) ===
        console.log("=== Scenario 5: Buy both (split-like) ===");
        q = _arr(0, 0);
        amounts = _iArr(int256(10e6), int256(10e6));
        console.log("  balances = [0, 0], amounts = [10e6, 10e6]");
        netCost = LMSRMath.calcNetCost(q, amounts, FUNDING, DECIMALS, true);
        console.log("  netCost =");
        console.logInt(netCost);
    }

    function _arr(uint256 a, uint256 b) internal pure returns (uint256[] memory out) {
        out = new uint256[](2);
        out[0] = a;
        out[1] = b;
    }

    function _iArr(int256 a, int256 b) internal pure returns (int256[] memory out) {
        out = new int256[](2);
        out[0] = a;
        out[1] = b;
    }
}
