// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {LMSRMath} from "../src/LMSRMath.sol";

contract LMSRBinaryCheck is Script {
    using LMSRMath for *;

    uint8 constant DECIMALS = 6;
    uint256 constant FUNDING = 100e6;

    function run() external pure {
        // ── NetCost comparisons ──────────────────────────────────

        // Scenario 1: Buy YES from zero balances
        {
            console.log("=== Scenario 1: NetCost - Buy YES from zero balances ===");
            uint256 balYes = 0;
            uint256 balNo = 0;
            int256 deltaYes = int256(10e6);
            int256 deltaNo = 0;
            bool roundUp = true;

            int256 generic = LMSRMath.calcNetCost(_arr(balYes, balNo), _iArr(deltaYes, deltaNo), FUNDING, DECIMALS, roundUp);
            int256 binary = LMSRMath.calcNetCostBinary(balYes, balNo, deltaYes, deltaNo, FUNDING, DECIMALS, roundUp);

            console.log("  generic  =");
            console.logInt(generic);
            console.log("  binary   =");
            console.logInt(binary);
            console.log("  match    =", generic == binary);
        }

        // Scenario 2: Buy YES from skewed balances
        {
            console.log("=== Scenario 2: NetCost - Buy YES from skewed balances ===");
            uint256 balYes = 80e6;
            uint256 balNo = 20e6;
            int256 deltaYes = int256(10e6);
            int256 deltaNo = 0;
            bool roundUp = true;

            int256 generic = LMSRMath.calcNetCost(_arr(balYes, balNo), _iArr(deltaYes, deltaNo), FUNDING, DECIMALS, roundUp);
            int256 binary = LMSRMath.calcNetCostBinary(balYes, balNo, deltaYes, deltaNo, FUNDING, DECIMALS, roundUp);

            console.log("  generic  =");
            console.logInt(generic);
            console.log("  binary   =");
            console.logInt(binary);
            console.log("  match    =", generic == binary);
        }

        // Scenario 3: Sell YES
        {
            console.log("=== Scenario 3: NetCost - Sell YES ===");
            uint256 balYes = 50e6;
            uint256 balNo = 10e6;
            int256 deltaYes = -int256(20e6);
            int256 deltaNo = 0;
            bool roundUp = false;

            int256 generic = LMSRMath.calcNetCost(_arr(balYes, balNo), _iArr(deltaYes, deltaNo), FUNDING, DECIMALS, roundUp);
            int256 binary = LMSRMath.calcNetCostBinary(balYes, balNo, deltaYes, deltaNo, FUNDING, DECIMALS, roundUp);

            console.log("  generic  =");
            console.logInt(generic);
            console.log("  binary   =");
            console.logInt(binary);
            console.log("  match    =", generic == binary);
        }

        // ── MarginalPrice comparisons ────────────────────────────

        // Scenario 4: Uniform zero - YES price
        {
            console.log("=== Scenario 4: MarginalPrice - Uniform zero, YES ===");
            uint256 balYes = 0;
            uint256 balNo = 0;

            uint256 generic = LMSRMath.calcMarginalPrice(_arr(balYes, balNo), FUNDING, 0, DECIMALS);
            uint256 binary = LMSRMath.calcMarginalPriceBinary(balYes, balNo, FUNDING, DECIMALS);

            console.log("  generic  =", generic);
            console.log("  binary   =", binary);
            console.log("  match    =", generic == binary);
        }

        // Scenario 5: Skewed - YES price
        {
            console.log("=== Scenario 5: MarginalPrice - Skewed, YES ===");
            uint256 balYes = 80e6;
            uint256 balNo = 20e6;

            uint256 generic = LMSRMath.calcMarginalPrice(_arr(balYes, balNo), FUNDING, 0, DECIMALS);
            uint256 binary = LMSRMath.calcMarginalPriceBinary(balYes, balNo, FUNDING, DECIMALS);

            console.log("  generic  =", generic);
            console.log("  binary   =", binary);
            console.log("  match    =", generic == binary);
        }

        // Scenario 6: Skewed - NO price
        {
            console.log("=== Scenario 6: MarginalPrice - Skewed, NO ===");
            uint256 balYes = 80e6;
            uint256 balNo = 20e6;

            uint256 generic = LMSRMath.calcMarginalPrice(_arr(balYes, balNo), FUNDING, 1, DECIMALS);
            // Binary returns YES price; NO = 1e18 - YES
            uint256 binaryYes = LMSRMath.calcMarginalPriceBinary(balYes, balNo, FUNDING, DECIMALS);
            uint256 binary = 1e18 - binaryYes;

            console.log("  generic  =", generic);
            console.log("  binary   =", binary);
            console.log("  match    =", generic == binary);
        }
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
