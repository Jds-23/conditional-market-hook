// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
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
    error OnlyExactInputSells();
    error CrossOutcomeSwapsNotSupportedYet();
    error TokenNotWinner();

    uint8 internal constant DECIMALS = 6;

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
            return _executeBuy(tokenIn, tokenOut, params);
        } else {
            address winner = conditionalTokens.resolved(conditionId);
            if (winner == address(0)) {
                return _executeSell(tokenIn, tokenOut, params);
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

    function _executeBuy(Currency tokenIn, Currency tokenOut, SwapParams calldata params)
        private
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (params.amountSpecified <= 0) revert OnlyExactOutputSwaps();
        uint256 delta = uint256(params.amountSpecified);

        uint256[] memory quantities = new uint256[](2);
        quantities[0] = reserves[yesToken];
        quantities[1] = reserves[noToken];

        int256[] memory amounts = new int256[](2);
        if (_currenciesEqual(tokenOut, yesToken)) {
            amounts[0] = int256(delta);
            amounts[1] = 0;
        } else {
            amounts[0] = 0;
            amounts[1] = int256(delta);
        }

        uint256 cost = uint256(LMSRMath.calcNetCost(quantities, amounts, funding, DECIMALS, true));
        if (cost == 0) revert InsufficientLiquidity();
        poolManager.take(tokenIn, address(this), cost);
        SafeTransferLib.safeApprove(
            Currency.unwrap(collateralToken), address(conditionalTokens), cost
        );
        conditionalTokens.split(conditionId, cost);

        // Provide outcome tokens to poolManager for the swapper
        poolManager.sync(tokenOut);
        SafeTransferLib.safeTransfer(Currency.unwrap(tokenOut), address(poolManager), delta);
        poolManager.settle();

        // Update reserves (track cumulative positions)
        reserves[tokenOut] += cost;
        reserves[tokenOut] -= delta;
        reserves[collateralToken] += cost;
        reserves[_currenciesEqual(tokenOut, yesToken) ? noToken : yesToken]+= cost;

        return (this.beforeSwap.selector, toBeforeSwapDelta(-int128(int256(delta)), int128(int256(cost))), 0);
    }

    function _executeSell(Currency tokenIn, Currency tokenOut, SwapParams calldata params)
        private
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (params.amountSpecified >= 0) revert OnlyExactInputSells();
        uint256 tokensIn = uint256(-params.amountSpecified);

        uint256[] memory quantities = new uint256[](2);
        quantities[0] = reserves[yesToken];
        quantities[1] = reserves[noToken];

        int256[] memory amounts = new int256[](2);
        if (_currenciesEqual(tokenIn, yesToken)) {
            amounts[0] = -int256(tokensIn);
            amounts[1] = 0;
        } else {
            amounts[0] = 0;
            amounts[1] = -int256(tokensIn);
        }

        int256 netCost = LMSRMath.calcNetCost(quantities, amounts, funding, DECIMALS, false);
        if (netCost >= 0) revert InsufficientLiquidity();
        uint256 collateralOut = uint256(-netCost);

        // Take outcome tokens from PM (user settles to PM in unlockCallback)
        poolManager.take(tokenIn, address(this), tokensIn);

        // Merge YES+NO → collateral (burns from hook, no approval needed — OutcomeToken.burn is onlyOwner)
        // Note: merge burns collateralOut amount of BOTH YES and NO tokens, regardless of which is tokenIn
        conditionalTokens.merge(conditionId, collateralOut);

        // Send collateral to PM for the swapper to take
        poolManager.sync(tokenOut);
        SafeTransferLib.safeTransfer(Currency.unwrap(tokenOut), address(poolManager), collateralOut);
        poolManager.settle();

        // Update reserves: collateralOut was burned from both YES and NO (the burn amount is collateralOut)
        reserves[tokenIn] += tokensIn;
        reserves[tokenIn] -= collateralOut;
        reserves[_currenciesEqual(tokenIn, yesToken) ? noToken : yesToken] -= collateralOut;
        reserves[collateralToken] -= collateralOut;

        return (this.beforeSwap.selector, toBeforeSwapDelta(int128(int256(tokensIn)), -int128(int256(collateralOut))), 0);
    }
}

