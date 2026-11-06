// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

/// @dev Test-only, prefunded integration driver. Not a production router.
contract PoolDriver is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    enum Action {
        Swap,
        Modify,
        PrepaidSwap
    }

    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    /// @dev Swaps, then settles each debt with sync -> transfer -> settle (the V4Router order).
    function swap(PoolKey memory key, SwapParams memory params, bytes memory hookData)
        external
        returns (BalanceDelta)
    {
        return abi.decode(
            manager.unlock(abi.encode(Action.Swap, key, abi.encode(params, hookData))), (BalanceDelta)
        );
    }

    /// @dev Pays `prepay` of `input` before the swap (sync -> transfer -> swap -> settle), then takes
    /// back any surplus. The swap runs inside the caller's sync window, as it does for a caller that
    /// settles once up front instead of after the swap.
    function swapPrepaid(PoolKey memory key, SwapParams memory params, Currency input, uint256 prepay)
        external
        returns (BalanceDelta)
    {
        return abi.decode(
            manager.unlock(abi.encode(Action.PrepaidSwap, key, abi.encode(params, input, prepay))),
            (BalanceDelta)
        );
    }

    function modify(PoolKey memory key, ModifyLiquidityParams memory params) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(Action.Modify, key, abi.encode(params))), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (Action action, PoolKey memory key, bytes memory args) = abi.decode(data, (Action, PoolKey, bytes));
        BalanceDelta delta;
        if (action == Action.PrepaidSwap) {
            (SwapParams memory params, Currency input, uint256 prepay) =
                abi.decode(args, (SwapParams, Currency, uint256));
            manager.sync(input);
            input.transfer(address(manager), prepay);
            delta = manager.swap(key, params, "");
            // The one settle() a prepaying caller performs. It must credit exactly what was paid in.
            require(manager.settle() == prepay, "settle credited less than transferred");
            _close(key.currency0);
            _close(key.currency1);
            return abi.encode(delta);
        }
        if (action == Action.Swap) {
            (SwapParams memory params, bytes memory hookData) = abi.decode(args, (SwapParams, bytes));
            delta = manager.swap(key, params, hookData);
        } else {
            (delta,) = manager.modifyLiquidity(key, abi.decode(args, (ModifyLiquidityParams)), "");
        }
        require(manager.currencyDelta(address(this), key.currency0) == delta.amount0(), "currency0 delta");
        require(manager.currencyDelta(address(this), key.currency1) == delta.amount1(), "currency1 delta");
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 delta) private {
        if (delta < 0) {
            manager.sync(currency);
            currency.transfer(address(manager), uint256(-int256(delta)));
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, address(this), uint256(int256(delta)));
        }
    }

    function _close(Currency currency) private {
        int256 remaining = manager.currencyDelta(address(this), currency);
        // A prepaying caller never pays twice: a debt still reported here is the defect under test.
        require(remaining >= 0, "manager still reports a debt after prepayment");
        if (remaining > 0) manager.take(currency, address(this), uint256(remaining));
    }
}
