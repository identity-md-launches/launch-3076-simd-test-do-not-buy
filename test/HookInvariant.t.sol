// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {HookFixture} from "./helpers/HookFixture.sol";
import {PoolDriver} from "./helpers/PoolDriver.sol";
import {MockIMD} from "./helpers/MockIMD.sol";
import {TestHook} from "../src/TestHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract FeeHandler is Test {
    using StateLibrary for IPoolManager;

    TestHook public immutable hook;
    PoolDriver public immutable trader;
    PoolKey internal key;
    uint256 public accrued;
    uint256 public trades;
    bool public blocked;

    constructor(TestHook hook_, PoolDriver trader_, PoolKey memory key_) {
        hook = hook_;
        trader = trader_;
        key = key_;
    }

    /// @param prepaid Pay the input inside a sync window that brackets the swap instead of after it.
    function swap(bool buy, bool exactInput, uint96 raw, bool partialFill, bool prepaid) external {
        uint256 amount = bound(raw, 1, 100 ether);
        IPoolManager manager = hook.poolManager();
        (, int24 tick,,) = manager.getSlot0(key.toId());
        uint160 limit = partialFill
            ? TickMath.getSqrtPriceAtTick(tick + (buy ? int24(-1) : int24(1)))
            : (buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        uint256 imdBefore = IERC20(hook.IMD()).balanceOf(address(trader));
        SwapParams memory params = SwapParams(buy, exactInput ? -int256(amount) : int256(amount), limit);
        vm.recordLogs();
        if (prepaid) {
            // Deep liquidity keeps the price near 1:1, so twice the amount always covers the input.
            Currency input = buy ? key.currency0 : key.currency1;
            trader.swapPrepaid(key, params, input, exactInput ? amount : 2 * amount + 1);
        } else {
            trader.swap(key, params, hex"ff");
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 gross;
        if (buy) {
            gross = imdBefore - IERC20(hook.IMD()).balanceOf(address(trader));
        } else {
            bytes32 topic = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
            for (uint256 i; i < logs.length; ++i) {
                if (logs[i].emitter == address(manager) && logs[i].topics[0] == topic) {
                    (int128 imd,,,,,) =
                        abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                    gross = uint256(int256(imd));
                }
            }
        }
        accrued += gross * 75 / 10_000;
        ++trades;
    }

    function rejectPayout(bool reject) external {
        blocked = reject;
        MockIMD(hook.IMD()).rejectRecipient(reject ? hook.FEE_RECIPIENT() : address(0));
    }

    function redeem() external {
        if (!blocked) hook.redeemFees();
    }
}

contract HookInvariantTest is HookFixture {
    using TransientStateLibrary for IPoolManager;

    FeeHandler internal handler;
    uint256 internal imdTotal;
    uint256 internal tokenTotal;

    function setUp() public {
        _setUp(true, false);
        handler = new FeeHandler(hook, trader, key);
        imdTotal = _sum(IERC20(IMD));
        tokenTotal = _sum(IERC20(address(token)));
        targetContract(address(handler));
    }

    function invariant_feeConservationAndNoCustodiedLaunchTokens() public view {
        uint256 paid = IERC20(IMD).balanceOf(RECIPIENT) - initialRecipient;
        uint256 owed = manager.balanceOf(address(hook), uint160(IMD));
        assertEq(paid + owed, handler.accrued());
        assertEq(IERC20(IMD).balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(RECIPIENT), 0);
        assertEq(_sum(IERC20(IMD)), imdTotal);
        assertEq(_sum(IERC20(address(token))), tokenTotal);
        assertEq(token.totalSupply(), 1e27);
        assertEq(hook.FEE_BPS(), 75);
        assertEq(hook.FEE_RECIPIENT(), RECIPIENT);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
    }

    function _sum(IERC20 asset) private view returns (uint256) {
        return asset.balanceOf(address(this)) + asset.balanceOf(address(lp))
            + asset.balanceOf(address(trader)) + asset.balanceOf(address(manager))
            + asset.balanceOf(address(hook)) + asset.balanceOf(RECIPIENT);
    }
}
