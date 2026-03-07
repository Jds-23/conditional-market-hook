// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {SimpleERC20} from "../src/SimpleERC20.sol";
import {ConditionalMarkets} from "../src/ConditionalMarkets.sol";
import {ConditionalLMSRMarketHook} from "../src/ConditionalLMSRMarketHook.sol";
import {console} from "forge-std/console.sol";


contract ConditionalLMSRMarketHookTest is BaseTest, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    uint256 constant FUNDING = 10_000e6;
    uint256 constant INITIAL_LIQUIDITY = 10_000e6;
    bytes32 constant CONDITION_ID = keccak256("test-condition");

    ConditionalLMSRMarketHook hook;
    SimpleERC20 collateral;
    ConditionalMarkets conditionalMarkets;

    Currency collateralCurrency;
    Currency yesCurrency;
    Currency noCurrency;

    PoolKey poolKeyColYes;
    PoolKey poolKeyColNo;
    PoolKey poolKeyYesNo;

    // Pending action routing state
    uint8 constant ACTION_SWAP = 3;
    uint8 constant ACTION_SWAP_EXACT_OUTPUT = 4;

    uint8 pendingAction;
    Currency pendingTokenIn;
    Currency pendingTokenOut;
    uint256 pendingAmountIn;
    uint256 pendingAmountOut;
    uint256 pendingMaxAmountIn;

    function setUp() public {
        // 1. Deploy infrastructure
        deployArtifactsAndLabel();

        // 2. Deploy collateral + ConditionalMarkets
        collateral = new SimpleERC20("Collateral", "COL");
        conditionalMarkets = new ConditionalMarkets();
        vm.label(address(collateral), "Collateral");
        vm.label(address(conditionalMarkets), "ConditionalMarkets");

        // 3. Create condition and read YES/NO tokens
        conditionalMarkets.createCondition(CONDITION_ID, address(collateral));
        (address colAddr, address yesAddr, address noAddr) = conditionalMarkets.conditions(CONDITION_ID);
        collateralCurrency = Currency.wrap(colAddr);
        yesCurrency = Currency.wrap(yesAddr);
        noCurrency = Currency.wrap(noAddr);
        vm.label(yesAddr, "YesToken");
        vm.label(noAddr, "NoToken");

        // 4. Compute flag address and deploy hook
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144)
        );
        bytes memory constructorArgs = abi.encode(
            poolManager,
            Currency.wrap(address(collateral)),
            yesCurrency,
            noCurrency,
            conditionalMarkets,
            CONDITION_ID,
            FUNDING
        );
        deployCodeTo("ConditionalLMSRMarketHook.sol:ConditionalLMSRMarketHook", constructorArgs, flags);
        hook = ConditionalLMSRMarketHook(flags);
        vm.label(flags, "Hook");

        // 5. Initialize 3 pools
        poolKeyColYes = _makePoolKey(Currency.wrap(address(collateral)), yesCurrency);
        poolKeyColNo = _makePoolKey(Currency.wrap(address(collateral)), noCurrency);
        poolKeyYesNo = _makePoolKey(yesCurrency, noCurrency);

        poolManager.initialize(poolKeyColYes, Constants.SQRT_PRICE_1_1);
        poolManager.initialize(poolKeyColNo, Constants.SQRT_PRICE_1_1);
        poolManager.initialize(poolKeyYesNo, Constants.SQRT_PRICE_1_1);

        // 6. Approvals
        collateral.approve(address(hook), type(uint256).max);
        collateral.approve(address(poolManager), type(uint256).max);
        collateral.approve(address(conditionalMarkets), type(uint256).max);

        IERC20(yesAddr).approve(address(hook), type(uint256).max);
        IERC20(yesAddr).approve(address(poolManager), type(uint256).max);
        IERC20(yesAddr).approve(address(conditionalMarkets), type(uint256).max);

        IERC20(noAddr).approve(address(hook), type(uint256).max);
        IERC20(noAddr).approve(address(poolManager), type(uint256).max);
        IERC20(noAddr).approve(address(conditionalMarkets), type(uint256).max);

        // 7. Mint collateral, split for outcome tokens
        collateral.mint(address(this), INITIAL_LIQUIDITY * 10);
        conditionalMarkets.split(CONDITION_ID, INITIAL_LIQUIDITY * 2);

        // 8. Initialize reserves (will revert in stub, but setUp only runs with test functions)
        hook.initializeReserves(INITIAL_LIQUIDITY);
    }

    function test_setUp() public view {
        assertEq(hook.reserves(collateralCurrency), INITIAL_LIQUIDITY);
        assertEq(hook.reserves(yesCurrency), INITIAL_LIQUIDITY);
        assertEq(hook.reserves(noCurrency), INITIAL_LIQUIDITY);
        assertTrue(hook.initialized());
        assertEq(hook.funding(), FUNDING);
    }

    function test_tokenImmutables() public view {
        assertEq(Currency.unwrap(hook.collateralToken()), address(collateral));
        assertEq(Currency.unwrap(hook.yesToken()), Currency.unwrap(yesCurrency));
        assertEq(Currency.unwrap(hook.noToken()), Currency.unwrap(noCurrency));
        assertEq(address(hook.conditionalTokens()), address(conditionalMarkets));
        assertEq(hook.conditionId(), CONDITION_ID);
    }

    // ── Phase 2: Pricing Invariants ───────────────────────────────────────

    function test_marginalPrice_equalReserves() public view {
        assertEq(hook.calcMarginalPrice(yesCurrency), 0.5e18);
        assertEq(hook.calcMarginalPrice(noCurrency), 0.5e18);
    }

    function test_marginalPrice_sumEqualsOne() public view {
        uint256 sum = hook.calcMarginalPrice(yesCurrency) + hook.calcMarginalPrice(noCurrency);
        assertApproxEqAbs(sum, 1e18, 1);
    }

    // ── Phase 3: Swap Validation ────────────────────────────────────────

    function test_swap_buy_reverts_when_resolved() public {
        conditionalMarkets.resolve(CONDITION_ID, Currency.unwrap(yesCurrency));

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(ConditionalLMSRMarketHook.MarketResolved.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(address(collateral), Currency.unwrap(yesCurrency), 100e6);
    }

    function test_swap_sell_preResolution_requiresExactOutput() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(ConditionalLMSRMarketHook.OnlyExactInputSells.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swapExactOutput(Currency.unwrap(yesCurrency), address(collateral), 100e6, type(uint256).max);
    }

    function test_swap_sell_postResolution_reverts_losingToken() public {
        conditionalMarkets.resolve(CONDITION_ID, Currency.unwrap(yesCurrency));

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(ConditionalLMSRMarketHook.TokenNotWinner.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(Currency.unwrap(noCurrency), address(collateral), 100e6);
    }

    function test_swap_crossOutcome_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(ConditionalLMSRMarketHook.CrossOutcomeSwapsNotSupportedYet.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(Currency.unwrap(yesCurrency), Currency.unwrap(noCurrency), 100e6);
    }

    // ── Phase 4: Buy ─────────────────────────────────────────────────────

    function test_buy_yes_success() public {
        collateral.mint(address(poolManager), INITIAL_LIQUIDITY * 10); // in given condition collateral will always be there in pool manager
        uint256 deltaYes = 100e6;
        uint256 yesBefore = IERC20(Currency.unwrap(yesCurrency)).balanceOf(address(this));
        uint256 colBefore = collateral.balanceOf(address(this));

        swapExactOutput(address(collateral), Currency.unwrap(yesCurrency), deltaYes, type(uint256).max);

        uint256 yesAfter = IERC20(Currency.unwrap(yesCurrency)).balanceOf(address(this));
        uint256 colAfter = collateral.balanceOf(address(this));

        assertEq(yesAfter - yesBefore, deltaYes);
        uint256 cost = colBefore - colAfter;
        assertGt(cost, 0);
        assertApproxEqRel(cost, deltaYes / 2, 0.1e18);
        assertEq(hook.reserves(yesCurrency), (INITIAL_LIQUIDITY+cost) - deltaYes);
    }

    function test_buy_no_success() public {
        collateral.mint(address(poolManager), INITIAL_LIQUIDITY * 10);
        uint256 deltaNO = 100e6;
        uint256 noBefore = IERC20(Currency.unwrap(noCurrency)).balanceOf(address(this));
        uint256 colBefore = collateral.balanceOf(address(this));

        swapExactOutput(address(collateral), Currency.unwrap(noCurrency), deltaNO, type(uint256).max);

        uint256 noAfter = IERC20(Currency.unwrap(noCurrency)).balanceOf(address(this));
        assertEq(noAfter - noBefore, deltaNO);
        uint256 cost = colBefore - collateral.balanceOf(address(this));
        assertGt(cost, 0);
        assertEq(hook.reserves(noCurrency), (INITIAL_LIQUIDITY+cost) - deltaNO);
    }

    function test_sell_yes_success() public {
        collateral.mint(address(poolManager), INITIAL_LIQUIDITY * 10);

        // Step 1: Buy YES tokens
        uint256 deltaYes = 100e6;
        uint256 yesBefore = IERC20(Currency.unwrap(yesCurrency)).balanceOf(address(this));
        uint256 colBefore = collateral.balanceOf(address(this));

        swapExactOutput(address(collateral), Currency.unwrap(yesCurrency), deltaYes, type(uint256).max);

        uint256 yesAfterBuy = IERC20(Currency.unwrap(yesCurrency)).balanceOf(address(this));
        uint256 colAfterBuy = collateral.balanceOf(address(this));

        assertEq(yesAfterBuy - yesBefore, deltaYes, "Buy: should receive YES tokens");
        assertGt(colBefore - colAfterBuy, 0, "Buy: should pay collateral");
        assertEq(hook.reserves(yesCurrency), INITIAL_LIQUIDITY + deltaYes, "Hook YES reserves after buy");

        // Step 2: Sell YES tokens back
        uint256 tokensToSell = 50e6;
        uint256 yesBeforeSell = IERC20(Currency.unwrap(yesCurrency)).balanceOf(address(this));
        uint256 colBeforeSell = collateral.balanceOf(address(this));

        // Manually provide YES tokens to poolManager by transferring them there
        // This simulates the pm already having tokens 
        IERC20(Currency.unwrap(yesCurrency)).transfer(address(poolManager), tokensToSell);

        // Execute the sell swap
        swap(Currency.unwrap(yesCurrency), address(collateral), tokensToSell);

        uint256 yesAfterSell = IERC20(Currency.unwrap(yesCurrency)).balanceOf(address(this));
        uint256 colAfterSell = collateral.balanceOf(address(this));

        // Verify sell results
        assertEq(yesBeforeSell - yesAfterSell, tokensToSell+tokensToSell , "Sell: YES decreased by tokens sold + transferred");
        assertGt(colAfterSell, colBeforeSell, "Sell: should receive collateral back");
        assertEq(hook.reserves(yesCurrency), INITIAL_LIQUIDITY + deltaYes - tokensToSell, "Hook YES reserves after sell");
        assertLt(hook.reserves(noCurrency), INITIAL_LIQUIDITY, "Hook NO reserves should decrease after merge");
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    function _makePoolKey(Currency a, Currency b) internal view returns (PoolKey memory) {
        (Currency c0, Currency c1) = a < b ? (a, b) : (b, a);
        return PoolKey(c0, c1, 0, 60, IHooks(hook));
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn) internal {
        pendingAction = ACTION_SWAP;
        pendingTokenIn = Currency.wrap(tokenIn);
        pendingTokenOut = Currency.wrap(tokenOut);
        pendingAmountIn = amountIn;
        poolManager.unlock("");
    }

    function swapExactOutput(address tokenIn, address tokenOut, uint256 amountOut, uint256 maxAmountIn) internal {
        pendingAction = ACTION_SWAP_EXACT_OUTPUT;
        pendingTokenIn = Currency.wrap(tokenIn);
        pendingTokenOut = Currency.wrap(tokenOut);
        pendingAmountOut = amountOut;
        pendingMaxAmountIn = maxAmountIn;
        poolManager.unlock("");
    }

    function unlockCallback(bytes calldata) external override returns (bytes memory) {
        if (pendingAction == ACTION_SWAP) {
            _executeSwap();
        } else if (pendingAction == ACTION_SWAP_EXACT_OUTPUT) {
            _executeSwapExactOutput();
        }
        return "";
    }

    function _executeSwap() internal {
        PoolKey memory key = _makePoolKey(pendingTokenIn, pendingTokenOut);
        bool zeroForOne = pendingTokenIn < pendingTokenOut;

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(pendingAmountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta = poolManager.swap(key, params, "");

        // Settle: pay tokenIn (negative delta = debt), take tokenOut (positive delta = credit)
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        if (delta0 < 0) {
            key.currency0.settle(poolManager, address(this), uint128(-delta0), false);
        } else if (delta0 > 0) {
            key.currency0.take(poolManager, address(this), uint128(delta0), false);
        }

        if (delta1 < 0) {
            key.currency1.settle(poolManager, address(this), uint128(-delta1), false);
        } else if (delta1 > 0) {
            key.currency1.take(poolManager, address(this), uint128(delta1), false);
        }
    }

    function _executeSwapExactOutput() internal {
        PoolKey memory key = _makePoolKey(pendingTokenIn, pendingTokenOut);
        bool zeroForOne = pendingTokenIn < pendingTokenOut;

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(pendingAmountOut),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta = poolManager.swap(key, params, "");

        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        if (delta0 < 0) {
            key.currency0.settle(poolManager, address(this), uint128(-delta0), false);
        } else if (delta0 > 0) {
            key.currency0.take(poolManager, address(this), uint128(delta0), false);
        }

        if (delta1 < 0) {
            key.currency1.settle(poolManager, address(this), uint128(-delta1), false);
        } else if (delta1 > 0) {
            key.currency1.take(poolManager, address(this), uint128(delta1), false);
        }
    }
}
