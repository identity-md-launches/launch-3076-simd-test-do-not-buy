// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookScenarios} from "./TestHook.t.sol";
import {HookFixture} from "./helpers/HookFixture.sol";
import {PoolDriver} from "./helpers/PoolDriver.sol";
import {TestHook} from "../src/TestHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IProtocolFees} from "v4-core/src/interfaces/IProtocolFees.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice Shared fork setup: Robinhood Chain (4663) at the job's pinned block, the live IMD token and
/// the live Uniswap v4 PoolManager. The RPC comes only from ROBINHOOD_RPC_URL; the suite skips when unset.
abstract contract RobinhoodFork is HookFixture {
    uint256 internal constant FORK_BLOCK = 107_806_973;
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    /// Uniswap v4 PoolManager on Robinhood Chain (listed in Uniswap governance's Robinhood Chain
    /// fee-expansion temp check); its code and owner are checked on the fork below.
    IPoolManager internal constant LIVE_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);

    function _forkOrSkip() internal returns (bool) {
        string memory url = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(url, FORK_BLOCK);
        assertEq(block.chainid, ROBINHOOD_CHAIN_ID, "requires Robinhood Chain");
        // Robinhood Chain is an Arbitrum Orbit chain: `block.number` there reports the parent chain's
        // block, so the L2 block is pinned by createSelectFork alone and not re-asserted here.
        assertEq(IERC20Metadata(IMD).symbol(), "IMD");
        assertEq(IERC20Metadata(IMD).decimals(), 18);
        assertGt(address(LIVE_MANAGER).code.length, 0, "live PoolManager has code");
        assertGt(IERC20(IMD).balanceOf(address(LIVE_MANAGER)), 0, "live PoolManager holds IMD");
        return true;
    }
}

/// @notice Every offline hook scenario, re-run against live IMD and the live PoolManager, plus
/// fork-only checks of where the fee lands and that nobody on chain can move it.
abstract contract RobinhoodForkScenarios is RobinhoodFork, HookScenarios {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    function _forkSetUp(bool imdFirst) internal {
        if (!_forkOrSkip()) return;
        _setUpOn(imdFirst, true, LIVE_MANAGER);
        assertEq(address(hook.poolManager()), address(LIVE_MANAGER));
    }

    // ---------------------------------------------------------------- fee lands in the wallet as IMD

    function test_fork_buysAndSellsPaySeventyFiveBpsOfIMDToTheWallet() public {
        uint256 ethBefore = RECIPIENT.balance;
        uint256 total;
        for (uint256 mode; mode < 4; ++mode) {
            bool buy = mode < 2;
            bool exactInput = mode % 2 == 0;
            Trade memory r = _trade(buy, exactInput, 250 ether, false, "");
            _assertFee(r, buy);
            assertGt(r.paid, 0, "every buy and sell pays the hook fee");
            // Paid inside the swap, straight to the wallet: no claim was left behind.
            assertEq(manager.balanceOf(address(hook), uint160(IMD)), 0, "fee was not deferred");
            total += r.paid;
        }
        assertEq(IERC20(IMD).balanceOf(RECIPIENT) - initialRecipient, total, "wallet got every fee in IMD");
        assertEq(manager.balanceOf(address(hook), uint160(IMD)), 0, "nothing deferred on the live manager");
        assertEq(RECIPIENT.balance, ethBefore, "fee is never converted to ETH");
        assertEq(token.balanceOf(RECIPIENT), 0, "fee is never taken in SIMDTEST");
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function test_fork_exactAmountsOnRoundTrades() public {
        // Exact-input buy of 1000 IMD: 7.5 IMD to the wallet, the trader spends exactly 1000.
        Trade memory buy = _trade(true, true, 1000 ether, false, "");
        assertEq(buy.paid, 7.5 ether);
        assertEq(imd0 ? buy.userDelta.amount0() : buy.userDelta.amount1(), -1000 ether);
        // Exact-output sell of 1000 IMD net: the trader gets exactly 1000, the wallet floor(1000*75/9925).
        Trade memory sell = _trade(false, false, 1000 ether, false, "");
        assertEq(imd0 ? sell.userDelta.amount0() : sell.userDelta.amount1(), 1000 ether);
        assertEq(sell.paid, uint256(1000 ether) * 75 / 9925);
        assertEq(sell.paid, uint256(int256(sell.coreImd)) * 75 / 10_000);
    }

    // ---------------------------------------------------------------- the rate never changes

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_fork_rateIsConstantAcrossSizeTimeAndBlocks(
        bool buy,
        bool exactInput,
        uint96 rawAmount,
        uint32 dt,
        uint32 dBlocks,
        bytes calldata hookData
    ) public {
        uint256 amount = bound(rawAmount, 1, 5000 ether);
        vm.warp(block.timestamp + dt);
        vm.roll(block.number + dBlocks);
        Trade memory r = _trade(buy, exactInput, amount, false, hookData);
        _assertFee(r, buy);
        assertEq(hook.FEE_BPS(), 75);
    }

    function test_fork_firstAndLaterTradesUseTheSameRate() public {
        // No launch-window or anti-sniper surcharge: the first trade after initialization pays 0.75%.
        Trade memory first = _trade(true, true, 400 ether, false, "");
        assertEq(first.paid, 3 ether);
        for (uint256 i; i < 6; ++i) {
            vm.warp(block.timestamp + 1 hours + i);
            vm.roll(block.number + 1 + i * 7);
            _trade(i % 2 == 0, true, 50 ether, false, "");
        }
        vm.warp(block.timestamp + 3650 days);
        Trade memory later = _trade(true, true, 400 ether, false, "");
        assertEq(later.paid, first.paid);
    }

    // ---------------------------------------------------------------- nothing can redirect the fee

    function test_fork_managerOwnerAndProtocolFeeControllerCannotRedirectHookFee() public {
        address owner = _owner(address(manager));
        address controller = makeAddr("new protocol fee controller");
        vm.prank(owner);
        IProtocolFees(address(manager)).setProtocolFeeController(controller);
        // Highest allowed protocol fee in both directions.
        vm.prank(controller);
        IProtocolFees(address(manager)).setProtocolFee(key, uint24(1000) | (uint24(1000) << 12));

        uint256 before = IERC20(IMD).balanceOf(RECIPIENT);
        uint256 imdBefore = IERC20(IMD).balanceOf(address(trader));
        trader.swap(key, _params(true, true, 1000 ether, false), abi.encode(controller));
        assertEq(imdBefore - IERC20(IMD).balanceOf(address(trader)), 1000 ether);
        assertEq(IERC20(IMD).balanceOf(RECIPIENT) - before, 7.5 ether, "hook fee unchanged by protocol fee");

        before = IERC20(IMD).balanceOf(RECIPIENT);
        imdBefore = IERC20(IMD).balanceOf(address(trader));
        trader.swap(key, _params(false, false, 1000 ether, false), abi.encode(owner));
        assertEq(IERC20(IMD).balanceOf(address(trader)) - imdBefore, 1000 ether);
        assertEq(IERC20(IMD).balanceOf(RECIPIENT) - before, uint256(1000 ether) * 75 / 9925);

        // Collecting every protocol fee leaves the wallet's fee untouched.
        uint256 walletNow = IERC20(IMD).balanceOf(RECIPIENT);
        vm.startPrank(controller);
        IProtocolFees(address(manager)).collectProtocolFees(controller, Currency.wrap(IMD), 0);
        IProtocolFees(address(manager)).collectProtocolFees(controller, Currency.wrap(address(token)), 0);
        vm.stopPrank();
        assertEq(IERC20(IMD).balanceOf(RECIPIENT), walletNow);
        assertEq(hook.FEE_RECIPIENT(), RECIPIENT);
        assertEq(hook.FEE_BPS(), 75);
    }

    function test_fork_privilegedOnChainAccountsCannotCallHookCallbacks() public {
        address[4] memory callers =
            [_owner(address(manager)), _owner(IMD), RECIPIENT, address(uint160(uint256(keccak256("any"))))];
        SwapParams memory params = _params(true, true, 1 ether, false);
        for (uint256 i; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(TestHook.OnlyPoolManager.selector);
            hook.beforeSwap(callers[i], key, params, "");
            vm.expectRevert(TestHook.OnlyPoolManager.selector);
            hook.afterSwap(callers[i], key, params, BalanceDelta.wrap(0), "");
            vm.expectRevert(TestHook.OnlyPoolManager.selector);
            hook.unlockCallback("");
            vm.expectRevert(TestHook.OnlySelf.selector);
            hook.quoteSwap(key, params);
            vm.stopPrank();
        }
    }

    function test_fork_routingThroughAnotherDriverStillPays() public {
        // The fee does not depend on which router or sender drives the swap.
        PoolDriver other = new PoolDriver(manager);
        deal(IMD, address(other), 1000 ether);
        uint256 before = IERC20(IMD).balanceOf(RECIPIENT);
        vm.prank(makeAddr("some user"));
        other.swap(key, _params(true, true, 1000 ether, false), abi.encode(address(other), uint256(0)));
        assertEq(IERC20(IMD).balanceOf(RECIPIENT) - before, 7.5 ether);
        assertEq(IERC20(IMD).balanceOf(address(other)), 0);
    }

    // ---------------------------------------------------------------- failure paths on live IMD

    function test_fork_blockedPayoutDefersAsIMDClaimAndOnlyPaysTheWallet() public {
        vm.mockCallRevert(IMD, abi.encodeWithSelector(IERC20.transfer.selector, RECIPIENT), "payout blocked");
        Trade memory r = _trade(false, true, 1000 ether, false, "");
        uint256 fee = uint256(int256(r.coreImd)) * 75 / 10_000;
        assertGt(fee, 0);
        assertEq(r.paid, 0, "wallet payout blocked");
        assertEq(manager.balanceOf(address(hook), uint160(IMD)), fee, "fee held as an IMD claim");

        address outsider = makeAddr("outsider");
        vm.prank(outsider);
        vm.expectRevert();
        hook.redeemFees();
        assertEq(manager.balanceOf(address(hook), uint160(IMD)), fee, "failed redemption keeps the claim");

        vm.clearMockedCalls();
        vm.prank(outsider);
        assertEq(hook.redeemFees(), fee);
        assertEq(IERC20(IMD).balanceOf(RECIPIENT) - initialRecipient, fee);
        assertEq(IERC20(IMD).balanceOf(outsider), 0);
        assertEq(manager.balanceOf(address(hook), uint160(IMD)), 0);
        assertEq(hook.redeemFees(), 0, "second redemption pays nothing");
    }

    function test_fork_redeemInsideAnotherUnlockReverts() public {
        // redeemFees needs its own unlock; a nested call cannot hijack an open one.
        NestedRedeemer nested = new NestedRedeemer(manager, hook);
        vm.expectRevert();
        nested.run();
    }

    function test_fork_invalidSwapsRevertAndMoveNoFee() public {
        uint256 before = IERC20(IMD).balanceOf(RECIPIENT);
        // Zero amount is rejected by the PoolManager.
        SwapParams memory zero = _params(true, true, 1, false);
        zero.amountSpecified = 0;
        vm.expectRevert();
        trader.swap(key, zero, "");
        // A price limit on the wrong side of the current price is rejected.
        SwapParams memory badLimit = _params(true, true, 1 ether, false);
        badLimit.sqrtPriceLimitX96 =
            badLimit.zeroForOne ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1;
        vm.expectRevert();
        trader.swap(key, badLimit, "");
        // A trader who cannot pay is rejected and the wallet gets nothing for the failed trade.
        deal(IMD, address(trader), 0);
        SwapParams memory unfunded = _params(true, true, 1 ether, false);
        vm.expectRevert();
        trader.swap(key, unfunded, "");
        assertEq(IERC20(IMD).balanceOf(RECIPIENT), before);
        assertEq(manager.balanceOf(address(hook), uint160(IMD)), 0);
    }

    function _owner(address target) internal view returns (address) {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSignature("owner()"));
        assertTrue(ok && data.length == 32, "owner()");
        return abi.decode(data, (address));
    }
}

contract NestedRedeemer {
    IPoolManager internal immutable manager;
    TestHook internal immutable hook;

    constructor(IPoolManager manager_, TestHook hook_) {
        manager = manager_;
        hook = hook_;
    }

    function run() external {
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        hook.redeemFees();
        return "";
    }
}

contract RobinhoodForkIMDFirstTest is RobinhoodForkScenarios {
    function setUp() public {
        _forkSetUp(true);
    }
}

contract RobinhoodForkIMDSecondTest is RobinhoodForkScenarios {
    function setUp() public {
        _forkSetUp(false);
    }
}

/// @notice Random buy/sell sequences on live IMD and the live PoolManager, some with the wallet payout
/// blocked, interleaved with redemptions by anyone.
contract ForkFeeHandler is Test {
    address internal constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address internal constant RECIPIENT = 0xdFA1f1F6FEAA04F7874efF0b7754b7FFaEBd8BC0;

    TestHook public immutable hook;
    PoolDriver public immutable trader;
    IPoolManager public immutable manager;
    bool public immutable imd0;
    PoolKey internal key;
    uint256 public accrued;
    uint256 public deferredTrades;

    constructor(TestHook hook_, PoolDriver trader_, PoolKey memory key_) {
        hook = hook_;
        trader = trader_;
        key = key_;
        manager = hook_.poolManager();
        imd0 = Currency.unwrap(key_.currency0) == IMD;
    }

    function swap(bool buy, bool exactInput, uint96 raw, bool blockPayout) external {
        uint256 amount = bound(raw, 1, 50 ether);
        bool zeroForOne = buy == imd0;
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        uint256 imdBefore = IERC20(IMD).balanceOf(address(trader));
        uint256 walletBefore = IERC20(IMD).balanceOf(RECIPIENT);
        uint256 claimBefore = manager.balanceOf(address(hook), uint160(IMD));
        if (blockPayout) {
            vm.mockCallRevert(
                IMD, abi.encodeWithSelector(IERC20.transfer.selector, RECIPIENT), "payout blocked"
            );
        }
        trader.swap(
            key, SwapParams(zeroForOne, exactInput ? -int256(amount) : int256(amount), limit), hex"00"
        );
        if (blockPayout) vm.clearMockedCalls();
        uint256 imdAfter = IERC20(IMD).balanceOf(address(trader));
        uint256 toWallet = IERC20(IMD).balanceOf(RECIPIENT) - walletBefore;
        uint256 toClaim = manager.balanceOf(address(hook), uint160(IMD)) - claimBefore;
        uint256 charged = toWallet + toClaim;
        // Gross IMD: what a buyer spent, or what the pool released to a seller before the fee.
        uint256 gross = buy ? imdBefore - imdAfter : imdAfter - imdBefore + charged;
        assertEq(charged, gross * 75 / 10_000, "0.75% of gross IMD");
        if (blockPayout) {
            assertEq(toWallet, 0);
            if (charged != 0) ++deferredTrades;
        } else {
            assertEq(toClaim, 0);
        }
        accrued += charged;
    }

    function redeem(uint160 callerSeed) external {
        // A small fixed set of callers keeps the fork from fetching a fresh account per call.
        address[4] memory callers = [address(0xA11CE), RECIPIENT, address(trader), address(this)];
        address caller = callers[callerSeed % 4];
        uint256 owed = manager.balanceOf(address(hook), uint160(IMD));
        uint256 walletBefore = IERC20(IMD).balanceOf(RECIPIENT);
        vm.prank(caller);
        uint256 paid = hook.redeemFees();
        assertEq(paid, owed);
        assertEq(IERC20(IMD).balanceOf(RECIPIENT) - walletBefore, owed);
    }
}

contract RobinhoodForkInvariantTest is RobinhoodFork {
    using TransientStateLibrary for IPoolManager;

    ForkFeeHandler internal handler;
    uint256 internal imdSupply;
    uint256 internal recipientEth;

    function setUp() public {
        if (!_forkOrSkip()) return;
        _setUpOn(true, true, LIVE_MANAGER);
        handler = new ForkFeeHandler(hook, trader, key);
        imdSupply = IERC20(IMD).totalSupply();
        recipientEth = RECIPIENT.balance;
        targetContract(address(handler));
        // Fixed senders: each fresh random sender would be another account fetched over RPC.
        targetSender(address(0xB0B));
        targetSender(address(0xCA11));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 32
    function invariant_fork_everyFeeReachesTheWalletOrItsClaim() public view {
        uint256 paid = IERC20(IMD).balanceOf(RECIPIENT) - initialRecipient;
        uint256 owed = manager.balanceOf(address(hook), uint160(IMD));
        assertEq(paid + owed, handler.accrued(), "fees paid + pending == fees charged");
        assertEq(IERC20(IMD).balanceOf(address(hook)), 0, "hook holds no IMD");
        assertEq(token.balanceOf(address(hook)), 0, "hook holds no SIMDTEST");
        assertEq(token.balanceOf(RECIPIENT), 0, "fee never in SIMDTEST");
        assertEq(RECIPIENT.balance, recipientEth, "fee never in ETH");
        assertEq(token.totalSupply(), 1e27, "fixed SIMDTEST supply");
        assertEq(IERC20(IMD).totalSupply(), imdSupply, "no IMD minted or burnt by trading");
        assertEq(hook.FEE_BPS(), 75);
        assertEq(hook.FEE_RECIPIENT(), RECIPIENT);
        assertEq(address(hook.poolManager()), address(LIVE_MANAGER));
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
    }
}
