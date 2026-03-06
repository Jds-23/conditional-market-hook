// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ConditionalMarkets} from "./ConditionalMarkets.sol";
import {LMSRMath} from "./LMSRMath.sol";

contract ConditionalLMSRMarketHook is BaseHook {
    error NotImplementedYet();
    error UnknownToken();
    error MarketResolved();
    error InsufficientLiquidity();
    error OnlyExactOutputSwaps();
    error CrossOutcomeSwapsNotSupportedYet();
    error TokenNotWinner();

    Currency public immutable collateralToken;
    Currency public immutable yesToken;
    Currency public immutable noToken;
    ConditionalMarkets public immutable conditionalTokens;
    bytes32 public immutable conditionId;

    mapping(Currency => uint256) public reserves;
    bool public initialized;
    uint256 public funding;

    constructor(
        IPoolManager _poolManager,
        Currency _collateralToken,
        Currency _yesToken,
        Currency _noToken,
        ConditionalMarkets _conditionalTokens,
        bytes32 _conditionId,
        uint256 _funding
    ) BaseHook(_poolManager) {
        collateralToken = _collateralToken;
        yesToken = _yesToken;
        noToken = _noToken;
        conditionalTokens = _conditionalTokens;
        conditionId = _conditionId;
        funding = _funding;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        Currency tokenIn = params.zeroForOne ? key.currency0 : key.currency1;
        Currency tokenOut = params.zeroForOne ? key.currency1 : key.currency0;

        bool isBuy = _currenciesEqual(tokenIn, collateralToken) && _isOutcomeToken(tokenOut);
        bool isSell = _isOutcomeToken(tokenIn) && _currenciesEqual(tokenOut, collateralToken);

        if (!isBuy && !isSell) {
            // here implementation of this condition will go
            revert CrossOutcomeSwapsNotSupportedYet();
        }

        if (isBuy) {
            if (conditionalTokens.resolved(conditionId) != address(0)) revert MarketResolved();
            if (calculateBuyAmount(uint256(-params.amountSpecified), tokenOut) == 0) revert InsufficientLiquidity();
            // here implementation of this condition will go
        } else {
            address winner = conditionalTokens.resolved(conditionId);
            if (winner == address(0)) {
                if (params.amountSpecified <= 0) revert OnlyExactOutputSwaps();
                if (calculateSellAmount(uint256(params.amountSpecified), tokenIn) == 0) revert InsufficientLiquidity();
                // here implementation of this condition will go
            } else {
                if (winner != Currency.unwrap(tokenIn)) revert TokenNotWinner();
                // here implementation of this condition will go
            }
        }
        revert NotImplementedYet();
    }

    function _isOutcomeToken(Currency token) internal view returns (bool) {
        return _currenciesEqual(token, yesToken) || _currenciesEqual(token, noToken);
    }

    function _currenciesEqual(Currency a, Currency b) internal pure returns (bool) {
        return Currency.unwrap(a) == Currency.unwrap(b);
    }

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert NotImplementedYet();
    }

    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert NotImplementedYet();
    }

    function initializeReserves(uint256 amount) external {
        SafeTransferLib.safeTransferFrom(
            Currency.unwrap(collateralToken), msg.sender, address(this), amount
        );
        SafeTransferLib.safeApprove(
            Currency.unwrap(collateralToken), address(conditionalTokens), amount
        );
        conditionalTokens.split(conditionId, amount);
        reserves[collateralToken] = amount;
        reserves[yesToken] = amount;
        reserves[noToken] = amount;
        initialized = true;
    }

    function calcMarginalPrice(Currency token) public view returns (uint256) {
        uint256 yesPrice = LMSRMath.calcMarginalPriceBinary(
            reserves[yesToken], reserves[noToken], funding, 6
        );
        if (Currency.unwrap(token) == Currency.unwrap(yesToken)) {
            return yesPrice;
        } else if (Currency.unwrap(token) == Currency.unwrap(noToken)) {
            return 1e18 - yesPrice;
        }
        revert UnknownToken();
    }

    function calculateBuyAmount(uint256, Currency) internal pure returns (uint256) {
        return 0;
    }

    function calculateSellAmount(uint256, Currency) internal pure returns (uint256) {
        return 0;
    }
}
