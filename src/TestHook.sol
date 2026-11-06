// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

/// @notice Immutable 75-basis-point IMD fee on this launch's SIMDTEST/IMD pool.
/// @dev No owner, admin, setters, upgrade mechanism, time logic, or fee conversion.
contract TestHook is IUnlockCallback {
    address public constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address public constant FEE_RECIPIENT = 0xdFA1f1F6FEAA04F7874efF0b7754b7FFaEBd8BC0;
    uint256 public constant FEE_BPS = 75;
    uint256 public constant BPS = 10_000;
    uint24 public constant LP_FEE = 12_500;
    int24 public constant TICK_SPACING = 60;
    /// @notice Largest exact-output sell (net IMD requested) the hook accepts. v4 adds the hook's
    /// specified-side fee to the request with checked arithmetic; the fee is always below int128.
    uint256 public constant MAX_EXACT_OUTPUT_SELL =
        uint256(type(int256).max) - uint256(uint128(type(int128).max));

    IPoolManager public immutable poolManager;
    address public immutable token;
    PoolId public immutable poolId;
    bool private immutable imdIsCurrency0;

    error OnlyPoolManager();
    error OnlySelf();
    error InvalidDeployment();
    error WrongPool();
    error QuoteResult(int256 delta);
    error UnexpectedQuoteResult();
    error ExactOutputTooLarge();

    /// @param deferred True when the IMD is held as a redeemable PoolManager claim.
    event FeeCharged(uint256 amount, bool deferred);
    event FeesRedeemed(uint256 amount);

    constructor(IPoolManager poolManager_, address token_) {
        if (address(poolManager_) == address(0) || token_ == address(0) || token_ == IMD) {
            revert InvalidDeployment();
        }
        poolManager = poolManager_;
        token = token_;
        imdIsCurrency0 = IMD < token_;
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(IMD < token_ ? IMD : token_),
            currency1: Currency.wrap(IMD < token_ ? token_ : IMD),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(this))
        });
        poolId = key.toId();
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
        permissions.beforeSwap = true;
        permissions.afterSwap = true;
        permissions.beforeSwapReturnDelta = true;
        permissions.afterSwapReturnDelta = true;
    }

    /// @dev Required at initialization so a predicted hook address cannot be used before deployment.
    function beforeInitialize(address, PoolKey calldata key, uint160)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        _checkPool(key);
        return IHooks.beforeInitialize.selector;
    }

    /// @dev The specified IMD cases are exact-input buys and exact-output sells.
    /// A reverted subcall quotes the actual fill without changing pool state. This prevents charging
    /// the requested amount when a price limit or exhausted liquidity causes a partial fill.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key);
        if (!_imdSpecified(params)) return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);

        bool buy = params.amountSpecified < 0;
        uint256 requested = _abs(params.amountSpecified);
        uint256 maximumFee = buy ? _fraction(requested, BPS) : _fraction(requested, BPS - FEE_BPS);
        SwapParams memory quoted = params;
        // All realistic v4 token amounts fit in int128. Saturate an enormous exact-output quote;
        // its actual fill (and thus the returned fee) is still limited by v4's signed deltas.
        if (buy) {
            quoted.amountSpecified += int256(maximumFee);
        } else {
            // Above this bound v4's `amountSpecified + fee` would panic; no pool can fill such an
            // order anyway (an IMD fill never exceeds int128), so refuse it with a named error.
            if (requested > MAX_EXACT_OUTPUT_SELL) revert ExactOutputTooLarge();
            uint256 room = uint256(type(int256).max) - requested;
            quoted.amountSpecified += int256(maximumFee < room ? maximumFee : room);
        }
        BalanceDelta filled = _quote(key, quoted);
        uint256 imdAmount = _abs(int256(imdIsCurrency0 ? filled.amount0() : filled.amount1()));
        uint256 fee = buy ? _fraction(imdAmount, BPS - FEE_BPS) : _fraction(imdAmount, BPS);
        // The one-wei ambiguity of integer gross-up must never increase an exact-input budget.
        if (buy && fee > maximumFee) fee = maximumFee;
        _pay(fee);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }

    /// @dev The unspecified IMD cases are exact-output buys and exact-input sells.
    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        _checkPool(key);
        if (_imdSpecified(params)) return (IHooks.afterSwap.selector, 0);
        int128 imdDelta = imdIsCurrency0 ? delta.amount0() : delta.amount1();
        uint256 amount = _abs(int256(imdDelta));
        // Buys add the fee to the pool's IMD input. Sells deduct it from gross IMD output.
        uint256 fee = _fraction(amount, imdDelta < 0 ? BPS - FEE_BPS : BPS);
        _pay(fee);
        return (IHooks.afterSwap.selector, int128(int256(fee)));
    }

    /// @notice Internal quoting entry point. Always reverts, rolling back the simulated swap.
    /// @dev v4 skips this hook for its own swaps. Nobody else can call this to bypass the fee.
    function quoteSwap(PoolKey calldata key, SwapParams calldata params) external {
        if (msg.sender != address(this)) revert OnlySelf();
        BalanceDelta delta = poolManager.swap(key, params, "");
        revert QuoteResult(BalanceDelta.unwrap(delta));
    }

    /// @notice Anyone can redeem deferred IMD fees, always to FEE_RECIPIENT.
    /// @dev Call outside an existing manager unlock. A failed redemption leaves claims intact.
    function redeemFees() external returns (uint256 amount) {
        return abi.decode(poolManager.unlock(""), (uint256));
    }

    function unlockCallback(bytes calldata) external onlyPoolManager returns (bytes memory) {
        Currency imd = Currency.wrap(IMD);
        uint256 amount = poolManager.balanceOf(address(this), imd.toId());
        uint256 available = imd.balanceOf(address(poolManager));
        if (amount > available) amount = available;
        // A claim balance can accumulate beyond the per-operation signed delta limit.
        if (amount > uint256(uint128(type(int128).max))) amount = uint256(uint128(type(int128).max));
        if (amount != 0) {
            poolManager.burn(address(this), imd.toId(), amount);
            poolManager.take(imd, FEE_RECIPIENT, amount);
            emit FeesRedeemed(amount);
        }
        return abi.encode(amount);
    }

    function _pay(uint256 fee) private {
        if (fee == 0) return;
        Currency imd = Currency.wrap(IMD);
        // settle() credits a payer with balance minus the reserves recorded by its last sync().
        // A take of IMD while a caller has IMD synced (sync -> transfer -> swap -> settle) would
        // shrink that credit by the fee, so the fee is kept as a claim until the window is closed.
        if (TransientStateLibrary.getSyncedCurrency(poolManager) == imd) {
            poolManager.mint(address(this), imd.toId(), fee);
            emit FeeCharged(fee, true);
            return;
        }
        // A swap's input may not yet be settled, or the external pair token may refuse a payout.
        // Reverting take rolls back its delta too; minting the same claim then settles our fee.
        try poolManager.take(imd, FEE_RECIPIENT, fee) {
            emit FeeCharged(fee, false);
        } catch {
            poolManager.mint(address(this), imd.toId(), fee);
            emit FeeCharged(fee, true);
        }
    }

    function _quote(PoolKey calldata key, SwapParams memory params) private returns (BalanceDelta) {
        try this.quoteSwap(key, params) {
            revert UnexpectedQuoteResult();
        } catch (bytes memory reason) {
            if (reason.length == 36 && bytes4(reason) == QuoteResult.selector) {
                int256 delta;
                assembly ("memory-safe") {
                    delta := mload(add(reason, 36))
                }
                return BalanceDelta.wrap(delta);
            }
            // Invalid price limits and core failures retain the core's original error.
            assembly ("memory-safe") {
                revert(add(reason, 32), mload(reason))
            }
        }
    }

    function _imdSpecified(SwapParams calldata params) private view returns (bool) {
        return (params.amountSpecified < 0) == (params.zeroForOne == imdIsCurrency0);
    }

    function _checkPool(PoolKey calldata key) private view {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert WrongPool();
    }

    /// @dev Division first with the remainder preserved avoids multiplication overflow.
    function _fraction(uint256 amount, uint256 denominator) private pure returns (uint256) {
        return (amount / denominator) * FEE_BPS + ((amount % denominator) * FEE_BPS) / denominator;
    }

    function _abs(int256 value) private pure returns (uint256) {
        return value < 0 ? uint256(-(value + 1)) + 1 : uint256(value);
    }
}
