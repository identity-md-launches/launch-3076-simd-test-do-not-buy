// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TestHook} from "../../src/TestHook.sol";
import {TestToken} from "../../src/TestToken.sol";
import {PoolDriver} from "./PoolDriver.sol";
import {MockIMD} from "./MockIMD.sol";

abstract contract HookFixture is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    address internal constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address internal constant RECIPIENT = 0xdFA1f1F6FEAA04F7874efF0b7754b7FFaEBd8BC0;
    uint160 internal constant FLAGS = 0x20cc;
    uint160 internal constant PRICE = 79228162514264337593543950336;
    int24 internal constant LOWER = -600;
    int24 internal constant UPPER = 600;
    int256 internal constant LIQUIDITY = 10_000_000 ether;
    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    IPoolManager internal manager;
    TestHook internal hook;
    TestToken internal token;
    PoolDriver internal trader;
    PoolDriver internal lp;
    PoolKey internal key;
    bool internal imd0;
    uint256 internal initialRecipient;

    struct Trade {
        BalanceDelta userDelta;
        int128 coreImd;
        int128 coreToken;
        uint256 paid; // IMD delivered to the recipient's wallet during the swap
        uint256 deferred; // IMD kept as the hook's ERC-6909 claim during the swap
    }

    function _setUp(bool pairFirst, bool forked) internal {
        _setUpOn(pairFirst, forked, IPoolManager(address(0)));
    }

    /// @dev `existing` is a deployed PoolManager (the live one on a fork); zero deploys a fresh one.
    function _setUpOn(bool pairFirst, bool forked, IPoolManager existing) internal {
        if (!forked) vm.etch(IMD, address(new MockIMD()).code);
        assertGt(IMD.code.length, 0, "IMD must exist");
        manager = address(existing) == address(0)
            ? IPoolManager(address(new PoolManager(address(this))))
            : existing;
        do {
            token = new TestToken();
        } while ((IMD < address(token)) != pairFirst);
        imd0 = pairFirst;
        hook = _deployHook(manager, address(token));
        key = PoolKey({
            currency0: Currency.wrap(imd0 ? IMD : address(token)),
            currency1: Currency.wrap(imd0 ? address(token) : IMD),
            fee: 12_500,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, PRICE);
        trader = new PoolDriver(manager);
        lp = new PoolDriver(manager);
        deal(IMD, address(lp), 10_000_000 ether);
        deal(IMD, address(trader), 10_000_000 ether);
        token.transfer(address(lp), 10_000_000 ether);
        token.transfer(address(trader), 10_000_000 ether);
        lp.modify(key, ModifyLiquidityParams(LOWER, UPPER, LIQUIDITY, bytes32(0)));
        initialRecipient = IERC20(IMD).balanceOf(RECIPIENT);
    }

    function _deployHook(IPoolManager target, address launchToken) internal returns (TestHook built) {
        bytes32 codeHash =
            keccak256(abi.encodePacked(type(TestHook).creationCode, abi.encode(target, launchToken)));
        for (uint256 salt; salt < 200_000; ++salt) {
            address predicted = address(
                uint160(
                    uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(salt), codeHash)))
                )
            );
            if (uint160(predicted) & 0x3fff == FLAGS) {
                built = new TestHook{salt: bytes32(salt)}(target, launchToken);
                assertEq(address(built), predicted);
                return built;
            }
        }
        revert("salt search exhausted");
    }

    function _params(bool buy, bool exactInput, uint256 amount, bool partialFill)
        internal
        view
        returns (SwapParams memory)
    {
        bool zeroForOne = buy == imd0;
        (, int24 tick,,) = manager.getSlot0(key.toId());
        uint160 limit = partialFill
            ? TickMath.getSqrtPriceAtTick(tick + (zeroForOne ? int24(-1) : int24(1)))
            : (zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        return SwapParams(zeroForOne, exactInput ? -int256(amount) : int256(amount), limit);
    }

    /// @dev Swaps first, then settles (the V4Router order).
    function _trade(bool buy, bool exactInput, uint256 amount, bool partialFill, bytes memory hookData)
        internal
        returns (Trade memory)
    {
        return _execute(_params(buy, exactInput, amount, partialFill), hookData, 0);
    }

    /// @dev Pays `prepay` of the input currency before the swap, inside one sync window that brackets it.
    function _prepaidTrade(bool buy, bool exactInput, uint256 amount, uint256 prepay)
        internal
        returns (Trade memory)
    {
        return _execute(_params(buy, exactInput, amount, false), "", prepay);
    }

    function _execute(SwapParams memory params, bytes memory hookData, uint256 prepay)
        private
        returns (Trade memory result)
    {
        uint256 beforeFee = IERC20(IMD).balanceOf(RECIPIENT);
        uint256 beforeClaim = manager.balanceOf(address(hook), uint160(IMD));
        uint256 beforeImd = IERC20(IMD).balanceOf(address(trader));
        uint256 beforeToken = token.balanceOf(address(trader));
        vm.recordLogs();
        if (prepay == 0) {
            result.userDelta = trader.swap(key, params, hookData);
        } else {
            Currency input = Currency.wrap(params.zeroForOne == imd0 ? IMD : address(token));
            result.userDelta = trader.swapPrepaid(key, params, input, prepay);
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 coreEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (int128 a0, int128 a1,,,, uint24 fee) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                result.coreImd = imd0 ? a0 : a1;
                result.coreToken = imd0 ? a1 : a0;
                assertEq(fee, 12_500, "LP fee was overridden");
                ++coreEvents;
            }
        }
        // recordLogs can observe a reverted quote's log too. The final log is the actual swap.
        assertGe(coreEvents, 1);
        result.paid = IERC20(IMD).balanceOf(RECIPIENT) - beforeFee;
        result.deferred = manager.balanceOf(address(hook), uint160(IMD)) - beforeClaim;
        int128 userImd = imd0 ? result.userDelta.amount0() : result.userDelta.amount1();
        int128 userToken = imd0 ? result.userDelta.amount1() : result.userDelta.amount0();
        assertEq(int256(IERC20(IMD).balanceOf(address(trader))) - int256(beforeImd), userImd);
        assertEq(int256(token.balanceOf(address(trader))) - int256(beforeToken), userToken);
        assertEq(userToken, result.coreToken, "hook charged the launch token");
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0, "unsettled hook currency0");
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0, "unsettled hook currency1");
        assertFalse(manager.isUnlocked());
    }

    function _assertFee(Trade memory result, bool buy) internal view {
        int128 userImd = imd0 ? result.userDelta.amount0() : result.userDelta.amount1();
        uint256 gross = buy ? uint256(-int256(userImd)) : uint256(int256(result.coreImd));
        uint256 fee = result.paid + result.deferred;
        assertEq(fee, gross * 75 / 10_000, "fee must be 0.75% of filled gross IMD");
        assertEq(int256(result.coreImd) - int256(userImd), int256(fee), "fee conservation");
        assertEq(IERC20(IMD).balanceOf(address(hook)), 0, "IMD left in hook");
        assertEq(token.balanceOf(RECIPIENT), 0, "recipient received launch tokens");
        assertEq(address(hook).balance, 0);
    }
}
