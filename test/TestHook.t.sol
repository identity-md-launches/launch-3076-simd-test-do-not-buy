// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {MockIMD} from "./helpers/MockIMD.sol";
import {PoolDriver} from "./helpers/PoolDriver.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestHook} from "../src/TestHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

abstract contract HookScenarios is HookFixture {
    using StateLibrary for IPoolManager;

    function test_buyExactInputPaysIMD() public {
        Trade memory r = _trade(true, true, 100 ether, false, "");
        _assertFee(r, true);
        assertEq(r.paid, 0.75 ether);
        assertGt(r.coreToken, 0);
        assertEq(imd0 ? r.userDelta.amount0() : r.userDelta.amount1(), -100 ether);
    }

    function test_buyExactOutputPaysIMD() public {
        Trade memory r = _trade(true, false, 100 ether, false, "");
        _assertFee(r, true);
        assertEq(r.coreToken, 100 ether);
    }

    function test_sellExactInputPaysIMD() public {
        Trade memory r = _trade(false, true, 100 ether, false, "");
        _assertFee(r, false);
        assertEq(r.coreToken, -100 ether);
    }

    function test_sellExactOutputReceivesTheRequestedNetIMD() public {
        Trade memory r = _trade(false, false, 100 ether, false, "");
        _assertFee(r, false);
        assertEq(imd0 ? r.userDelta.amount0() : r.userDelta.amount1(), 100 ether);
    }

    function testFuzz_feeAndSettlementAllModes(bool buy, bool exactInput, uint96 amount) public {
        uint256 size = bound(amount, 1, 1000 ether);
        Trade memory r = _trade(buy, exactInput, size, false, hex"ffffffff");
        _assertFee(r, buy);
        if (!exactInput) {
            int128 specified = buy ? r.coreToken : (imd0 ? r.userDelta.amount0() : r.userDelta.amount1());
            assertEq(specified, int256(size));
        }
    }

    function testFuzz_partialFillChargesOnlyFilledIMD(bool buy, bool exactInput, uint96 amount) public {
        uint256 size = bound(amount, 10_000 ether, 100_000 ether);
        Trade memory r = _trade(buy, exactInput, size, true, "");
        _assertFee(r, buy);
        assertGt(r.paid, 0);
        int128 specified =
            buy == exactInput ? (imd0 ? r.userDelta.amount0() : r.userDelta.amount1()) : r.coreToken;
        uint256 used = specified < 0 ? uint256(-int256(specified)) : uint256(int256(specified));
        assertLt(used, size, "expected a partial fill");
    }

    /// A caller that syncs IMD, pays, swaps and settles once is credited everything it transferred:
    /// the hook must not take IMD out of the manager inside that caller's sync window.
    function test_prepaidExactInputBuyPaysOnlyItsBudget() public {
        Trade memory r = _prepaidTrade(true, true, 1000 ether, 1000 ether);
        _assertFee(r, true);
        assertEq(imd0 ? r.userDelta.amount0() : r.userDelta.amount1(), -1000 ether);
        assertGt(r.coreToken, 0);
        assertEq(r.paid, 0, "taking IMD inside the sync window would under-credit the buyer");
        assertEq(r.deferred, 7.5 ether);
        assertEq(hook.redeemFees(), 7.5 ether);
        assertEq(IERC20(IMD).balanceOf(RECIPIENT) - initialRecipient, 7.5 ether);
        assertEq(manager.balanceOf(address(hook), uint160(IMD)), 0);
    }

    /// Prepaying a maximum and taking the surplus back must cost exactly what settling after costs.
    function test_prepaidExactOutputBuyCostsTheSameAsSettlingAfter() public {
        uint256 snap = vm.snapshotState();
        Trade memory control = _trade(true, false, 500 ether, false, "");
        vm.revertToState(snap);
        Trade memory r = _prepaidTrade(true, false, 500 ether, 1000 ether);
        _assertFee(r, true);
        assertEq(r.coreToken, 500 ether);
        assertEq(BalanceDelta.unwrap(r.userDelta), BalanceDelta.unwrap(control.userDelta), "same cost");
        assertEq(r.deferred, control.paid, "same fee, deferred instead of delivered");
        assertEq(r.paid, 0);
    }

    /// With SIMDTEST synced, a sell's IMD fee still goes straight to the wallet.
    function test_prepaidSellsStillPayTheWalletDirectly() public {
        Trade memory r = _prepaidTrade(false, true, 100 ether, 100 ether);
        _assertFee(r, false);
        assertEq(r.coreToken, -100 ether);
        assertGt(r.paid, 0);
        assertEq(r.deferred, 0);
        r = _prepaidTrade(false, false, 100 ether, 200 ether);
        _assertFee(r, false);
        assertEq(imd0 ? r.userDelta.amount0() : r.userDelta.amount1(), 100 ether);
        assertGt(r.paid, 0);
        assertEq(r.deferred, 0);
    }

    /// A buyer that settles its input before the swap closes the sync window; direct delivery resumes.
    function test_buySettledBeforeSwapPaysTheWalletDirectly() public {
        Trade memory r = _trade(true, true, 100 ether, false, "");
        assertEq(r.paid, 0.75 ether);
        assertEq(r.deferred, 0);
    }

    /// v4 adds the hook's fee to an exact-output sell with checked arithmetic. The hook names the
    /// bound instead of letting the addition panic; every order at or below it fills.
    function test_exactOutputSellBoundIsNamedAndEveryOrderBelowItFills() public {
        SwapParams memory params = _params(false, false, 1, true);
        params.amountSpecified = type(int256).max;
        // v4 wraps a hook's revert with the hook address, callback selector and its own detail.
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(TestHook.ExactOutputTooLarge.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        trader.swap(key, params, "");
        uint256 snap = vm.snapshotState();
        Trade memory atBound = _trade(false, false, hook.MAX_EXACT_OUTPUT_SELL(), true, "");
        _assertFee(atBound, false);
        assertGt(atBound.paid, 0);
        vm.revertToState(snap);
        Trade memory int128Max = _trade(false, false, uint256(uint128(type(int128).max)), true, "");
        _assertFee(int128Max, false);
        assertEq(BalanceDelta.unwrap(int128Max.userDelta), BalanceDelta.unwrap(atBound.userDelta));
        assertEq(int128Max.paid, atBound.paid);
    }

    function test_tinyAmountsRoundDownWithoutBlocking() public {
        for (uint256 i = 1; i <= 4; ++i) {
            Trade memory r = _trade(i % 2 == 0, i < 3, 1, false, "");
            assertEq(r.paid, 0);
            _assertFee(r, i % 2 == 0);
        }
    }

    /// Settles the dust finding: the zero-fee range is exactly what floor(gross * 75 / 10000) gives,
    /// and it ends at 134 wei of gross IMD. The trader never pays more than the requested amount.
    function test_dustFeeBoundaryIsExactlyOneHundredThirtyFourWeiOfGrossIMD() public {
        Trade memory buyBelow = _trade(true, true, 133, false, "");
        _assertFee(buyBelow, true);
        assertEq(imd0 ? buyBelow.userDelta.amount0() : buyBelow.userDelta.amount1(), -133);
        assertEq(buyBelow.paid + buyBelow.deferred, 0);

        Trade memory buyAtBoundary = _trade(true, true, 134, false, "");
        _assertFee(buyAtBoundary, true);
        assertEq(imd0 ? buyAtBoundary.userDelta.amount0() : buyAtBoundary.userDelta.amount1(), -134);
        assertEq(buyAtBoundary.paid, 1);

        // An exact-output sell of N net IMD pulls N + floor(N * 75 / 9925) gross from the pool.
        Trade memory sellBelow = _trade(false, false, 132, false, "");
        _assertFee(sellBelow, false);
        assertEq(sellBelow.coreImd, 132);
        assertEq(sellBelow.paid + sellBelow.deferred, 0);

        Trade memory sellAtBoundary = _trade(false, false, 133, false, "");
        _assertFee(sellAtBoundary, false);
        assertEq(sellAtBoundary.coreImd, 134);
        assertEq(imd0 ? sellAtBoundary.userDelta.amount0() : sellAtBoundary.userDelta.amount1(), 133);
        assertEq(sellAtBoundary.paid, 1);
    }

    /// Settles the 2% finding: the rates the brief fixes are charged on different bases. A 1000 IMD
    /// buy pays 7.5 IMD to the wallet and 1.25% of the remaining 992.5 IMD to the pool, 19.90625 IMD.
    function test_hookAndPoolFeesOnABuyCompoundToTheDocumentedTotal() public {
        Trade memory r = _trade(true, true, 1000 ether, false, "");
        assertEq(imd0 ? r.userDelta.amount0() : r.userDelta.amount1(), -1000 ether);
        assertEq(r.paid, 7.5 ether);
        assertEq(r.coreImd, -992.5 ether);

        BalanceDelta collected = lp.modify(key, ModifyLiquidityParams(LOWER, UPPER, 0, bytes32(0)));
        int128 lpImd = imd0 ? collected.amount0() : collected.amount1();
        int128 lpToken = imd0 ? collected.amount1() : collected.amount0();
        assertEq(lpToken, 0, "a buy's pool fee is charged in IMD");
        // The pool's own wei rounding on price and fee growth is the only tolerance needed.
        assertApproxEqAbs(uint256(int256(lpImd)), 12.40625 ether, 1e6);
        assertApproxEqAbs(r.paid + uint256(int256(lpImd)), 19.90625 ether, 1e6);
    }

    function test_exhaustedLiquidityChargesNoPhantomFee() public {
        lp.modify(key, ModifyLiquidityParams(LOWER, UPPER, -LIQUIDITY, bytes32(0)));
        for (uint256 mode; mode < 4; ++mode) {
            uint256 snap = vm.snapshotState();
            Trade memory r = _trade(mode < 2, mode % 2 == 0, 1 ether, true, "");
            assertEq(BalanceDelta.unwrap(r.userDelta), 0);
            assertEq(r.paid, 0);
            vm.revertToState(snap);
        }
    }

    function test_rateUnaffectedByTimeBlocksCallerAndHookData() public {
        Trade memory early = _trade(true, true, 100 ether, false, "");
        vm.warp(block.timestamp + 1000 days);
        vm.roll(block.number + 10_000_000);
        vm.prank(makeAddr("untrusted caller"));
        // Driver ignores end-user identities just as this hook does.
        trader.swap(key, _params(false, true, 100 ether, false), abi.encode(makeAddr("redirect"), 9999));
        Trade memory late = _trade(true, true, 100 ether, false, hex"01");
        assertEq(early.paid, late.paid);
        _assertFee(late, true);
    }

    function test_callbacksAndQuoteRefuseUnauthorizedCallers() public {
        SwapParams memory params = _params(true, true, 1 ether, false);
        vm.expectRevert(TestHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(this), key, PRICE);
        vm.expectRevert(TestHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(TestHook.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(TestHook.OnlyPoolManager.selector);
        hook.unlockCallback("");
        vm.expectRevert(TestHook.OnlySelf.selector);
        hook.quoteSwap(key, params);
    }

    function test_permissionsMatchMinedAddressAndPool() public view {
        assertEq(uint160(address(hook)) & 0x3fff, FLAGS);
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize && p.beforeSwap && p.afterSwap);
        assertTrue(p.beforeSwapReturnDelta && p.afterSwapReturnDelta);
        assertFalse(p.afterInitialize || p.beforeAddLiquidity || p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity || p.afterRemoveLiquidity || p.beforeDonate || p.afterDonate);
        assertFalse(p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta);
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(key.toId()));
    }

    function test_deployedCodeHasNoUpgradeOrDestructionOpcodes() public view {
        _checkRuntime(address(hook).code);
        _checkRuntime(address(token).code);
    }

    function _checkRuntime(bytes memory code) private pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        bool reachable = true;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f; // Skip PUSH data, which is not executable bytecode.
                continue;
            }
            if (reachable) assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) {
                reachable = false;
            }
        }
    }

    function test_cannotInitializeOtherPools() public {
        PoolKey memory other = key;
        other.fee = 3000;
        vm.expectRevert();
        manager.initialize(other, PRICE);
        other = key;
        other.tickSpacing = 10;
        vm.expectRevert();
        manager.initialize(other, PRICE);
        other = key;
        other.currency1 = Currency.wrap(address(type(uint160).max));
        vm.expectRevert();
        manager.initialize(other, PRICE);
        vm.prank(address(manager));
        vm.expectRevert(TestHook.WrongPool.selector);
        hook.beforeInitialize(address(this), other, PRICE);
    }

    function test_zeroLiquidityCollectAndExitRemainAvailable() public {
        _trade(true, true, 100 ether, false, "");
        _trade(false, true, 100 ether, false, "");
        uint256 feeBefore = IERC20(IMD).balanceOf(RECIPIENT);
        BalanceDelta collected = lp.modify(key, ModifyLiquidityParams(LOWER, UPPER, 0, bytes32(0)));
        assertGt(collected.amount0(), 0);
        assertGt(collected.amount1(), 0);
        BalanceDelta removed = lp.modify(key, ModifyLiquidityParams(LOWER, UPPER, -LIQUIDITY, bytes32(0)));
        assertGt(removed.amount0(), 0);
        assertGt(removed.amount1(), 0);
        assertEq(IERC20(IMD).balanceOf(RECIPIENT), feeBefore);
    }

    function test_noAdminOrRedirectionEvenForRecipientOrDeployer() public {
        address attacker = makeAddr("attacker");
        bytes[] memory calls = new bytes[](9);
        calls[0] = abi.encodeWithSignature("setFee(uint256)", 0);
        calls[1] = abi.encodeWithSignature("setFeeRecipient(address)", attacker);
        calls[2] = abi.encodeWithSignature("transferOwnership(address)", attacker);
        calls[3] = abi.encodeWithSignature("upgradeTo(address)", attacker);
        calls[4] = abi.encodeWithSignature("pause()");
        calls[5] = abi.encodeWithSignature("setPoolManager(address)", attacker);
        calls[6] = abi.encodeWithSignature("initialize(address)", attacker);
        calls[7] = abi.encodeWithSignature("withdraw(address,uint256)", attacker, 1 ether);
        calls[8] = abi.encodeWithSignature("setBlacklist(address,bool)", address(trader), true);
        address[3] memory callers = [address(this), RECIPIENT, attacker];
        for (uint256 c; c < callers.length; ++c) {
            for (uint256 i; i < calls.length; ++i) {
                vm.prank(callers[c]);
                (bool ok,) = address(hook).call(calls[i]);
                assertFalse(ok);
            }
        }
        Trade memory r = _trade(true, true, 100 ether, false, abi.encode(attacker, uint256(0)));
        _assertFee(r, true);
        assertEq(r.paid, 0.75 ether);
        assertEq(IERC20(IMD).balanceOf(attacker), 0);
        assertEq(hook.FEE_RECIPIENT(), RECIPIENT);
    }

    function test_coreFailuresRollbackFeeAndPrice() public {
        uint256 beforeRecipient = IERC20(IMD).balanceOf(RECIPIENT);
        (uint160 priceBefore,,,) = manager.getSlot0(key.toId());
        SwapParams memory params = _params(true, true, 1 ether, false);
        params.sqrtPriceLimitX96 = PRICE;
        vm.expectRevert();
        trader.swap(key, params, "");
        params = _params(true, true, 1 ether, false);
        deal(IMD, address(trader), 0);
        vm.expectRevert();
        trader.swap(key, params, "");
        assertEq(IERC20(IMD).balanceOf(RECIPIENT), beforeRecipient);
        (uint160 priceAfter,,,) = manager.getSlot0(key.toId());
        assertEq(priceAfter, priceBefore);
        assertEq(manager.balanceOf(address(hook), uint160(IMD)), 0);
    }
}

contract HookIMDFirstTest is HookScenarios {
    function setUp() public {
        _setUp(true, false);
    }

    function test_recipientFailureDefersInIMDAndAnyoneCanRedeem() public {
        MockIMD(IMD).rejectRecipient(RECIPIENT);
        Trade memory r = _trade(true, true, 100 ether, false, "");
        assertEq(r.paid, 0);
        uint256 claim = manager.balanceOf(address(hook), uint160(IMD));
        assertEq(claim, 0.75 ether);
        vm.expectRevert();
        hook.redeemFees();
        assertEq(manager.balanceOf(address(hook), uint160(IMD)), claim, "failed redemption burned claims");
        MockIMD(IMD).rejectRecipient(address(0));
        address outsider = makeAddr("redeemer");
        vm.prank(outsider);
        assertEq(hook.redeemFees(), claim);
        assertEq(IERC20(IMD).balanceOf(RECIPIENT) - initialRecipient, claim);
        assertEq(IERC20(IMD).balanceOf(outsider), 0);
        assertEq(manager.balanceOf(address(hook), uint160(IMD)), 0);
        assertEq(hook.redeemFees(), 0);
    }

    function test_buyWithOnlyLaunchTokenLiquidityDefersUntilInputSettled() public {
        manager = new PoolManager(address(this));
        hook = _deployHook(manager, address(token));
        key.hooks = IHooks(address(hook));
        manager.initialize(key, PRICE);
        trader = new PoolDriver(manager);
        lp = new PoolDriver(manager);
        token.transfer(address(lp), 10_000 ether);
        deal(IMD, address(trader), 1000 ether);
        // IMD is currency0; a range below the current price contains only currency1 (SIMDTEST).
        lp.modify(key, ModifyLiquidityParams(-120, -60, 100_000 ether, bytes32(uint256(1))));
        assertEq(IERC20(IMD).balanceOf(address(manager)), 0);
        Trade memory r = _trade(true, true, 100 ether, false, "");
        assertGt(r.coreToken, 0);
        assertEq(r.paid, 0);
        uint256 claim = manager.balanceOf(address(hook), uint160(IMD));
        assertEq(claim, 0.75 ether);
        assertGt(IERC20(IMD).balanceOf(address(manager)), claim);
        assertEq(hook.redeemFees(), claim);
        assertEq(IERC20(IMD).balanceOf(RECIPIENT) - initialRecipient, claim);
    }
}

contract HookIMDSecondTest is HookScenarios {
    function setUp() public {
        _setUp(false, false);
    }
}
