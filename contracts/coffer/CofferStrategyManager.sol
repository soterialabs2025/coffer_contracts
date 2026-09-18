// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./libraries/TrailingFloorLib.sol";
import "./libraries/AutoBandLib.sol";

/// @title CofferStrategyManager
/// @notice Owner-settable params for AutoStrategyV2 (dual-bucket reserve + Auto bands).
contract CofferStrategyManager is Ownable {
    constructor() Ownable(msg.sender) {}

    uint256 public constant DIVISOR = 10_000;
    // No inventory target lives here. The mix a mint needs is fixed by the band's ticks at the current price, and
    // the strategy derives it from them (`LiquidityLibraryV2.mintShare`); a hand-set target could only agree with
    // that by coincidence, and when it did not the difference sat idle for the keeper to chase.

    int24 public tickSpacing = 200;
    uint256 public rangeBelowTicks = 1000;
    uint256 public rangeAboveTicks = 1000;
    uint256 public innerBelowTicks = 800;
    uint256 public innerAboveTicks = 800;

    uint16 public slippageBps = 100;
    uint256 public minHarvestDelay = 2 hours;
    uint256 public withdrawalFeeBps = 100;
    /// @notice Share of collected LP fees sent to `feeManager` (default 300 = 3%). rh-v3 took 6% and paid half of
    ///         it to staking; Coffer has no staking, so that half stays in the position and compounds instead.
    uint256 public protocolFeeBps = 300;
    /// @notice When false, `_collectAllFees` skips the protocol peel; `protocolFeeBps` is left as-is.
    bool public protocolFeeOn = true;
    /// @notice Share of post-protocol deposit/fee capital kept idle as reserve (default 3000 = 30%).
    uint256 public reserveBps = 3000;
    /// @notice What the reserve is made of. `PAIRED` peels both legs pro-rata and can fund either short leg at a
    ///         remint (the rh-v3 behaviour). `QUOTE_ONLY` peels the quote token alone, before any balancing swap,
    ///         so the reserve never holds the volatile asset and a rotation never has to sell it; it can then only
    ///         fund a short quote leg.
    enum ReserveMode {
        PAIRED,
        QUOTE_ONLY
    }
    ReserveMode public reserveMode;
    /// @notice Uniswap V3 oracle window for rebalance TWAP (default 30 minutes). `0` disables TWAP gate.
    uint32 public twapSeconds = 30 minutes;
    /// @notice Max |spot − TWAP| / TWAP in bps before `_balanceTokens` / reserve deficit pulls skip (default 3%).
    uint256 public maxTwapDeviationBps = 300;
    /// @notice Withdrawals price against this multiple of `maxTwapDeviationBps` so ordinary volatility cannot
    ///         trap users. Rebalances keep the tighter band because skipping one costs nothing.
    uint256 internal constant WITHDRAW_DEVIATION_MULTIPLE = 3;
    /// @notice Haircut applied to the TWAP-derived swap floor passed to the router (default 2%; at 1% the pool fee
    ///         alone ate most of the tolerance on thin pools).
    /// @dev Distinct from `slippageBps`, which bounds LP mint amounts.
    uint16 public swapSlippageBps = 200;
    /// @notice Withdrawals widen the floor haircut by this multiple, for the same reason they widen the deviation
    ///         band: a skipped rebalance retries, a blocked exit strands a user.
    /// @dev Safe to loosen only on the exit path. That swap sells the withdrawer's own pro-rata tokens and credits
    ///      the proceeds straight back to them, so a worse fill is charged to the caller who asked for it rather
    ///      than to the remaining holders. Pool movement — the part that does touch everyone — stays bounded by
    ///      the router's TWAP gate, which this does not relax.
    uint256 internal constant WITHDRAW_SLIPPAGE_MULTIPLE = 3;
    /// @dev Ceiling on the widened haircut. `setSwapSlippageBps` allows up to 1_000, and an unclamped multiple
    ///      would reach 30% — past which a floor no longer bounds execution in any useful way.
    uint256 internal constant MAX_WITHDRAW_SLIPPAGE_BPS = 1_000;

    function setProtocolFeeOn(bool on) external onlyOwner {
        protocolFeeOn = on;
    }

    function _protocolFeeBps() internal view returns (uint256) {
        return protocolFeeOn ? protocolFeeBps : 0;
    }

    /// @notice Set reserve peel bps. No cap — `> DIVISOR` peels all deployable (no LP mint).
    function setReserveBps(uint256 bps) external {
        if (!_isOperator()) revert NotOperator();
        reserveBps = bps;
    }

    /// @notice Switch reserve composition. Takes effect on the next peel; what is already reserved stays reserved
    ///         until a remint draws it or a withdrawal consumes it.
    function setReserveMode(ReserveMode mode) external {
        if (!_isOperator()) revert NotOperator();
        reserveMode = mode;
    }

    /// @notice Set TWAP window for rebalance pricing. `0` disables TWAP (falls back to skipping gated rebalances).
    function setTwapSeconds(uint32 seconds_) external onlyOwner {
        if (seconds_ != 0 && (seconds_ < 60 || seconds_ > 1 days)) revert TwapConfig();
        twapSeconds = seconds_;
    }

    /// @notice Set max spot vs TWAP deviation for rebalance. Cap `DIVISOR` (100%).
    function setMaxTwapDeviationBps(uint256 bps) external onlyOwner {
        if (bps > DIVISOR) revert TwapConfig();
        maxTwapDeviationBps = bps;
    }

    /// @notice Set the haircut on TWAP-derived swap floors. Capped so a floor can never be driven to zero.
    function setSwapSlippageBps(uint16 bps) external onlyOwner {
        if (bps > 1_000) revert TwapConfig();
        swapSlippageBps = bps;
    }

    function _isOperator() internal view virtual returns (bool) {
        return false;
    }

    error NotOperator();
    error TwapConfig();

    function _spacing() internal view returns (int24) {
        int24 sp = tickSpacing;
        return sp > 0 ? sp : int24(200);
    }

    /// @dev `> DIVISOR` means 100%. Cap before `mulDiv` so a huge stored value cannot overflow.
    function _bps(uint256 bps) internal pure returns (uint256) {
        return bps > DIVISOR ? DIVISOR : bps;
    }

    /// @dev Floor band widths to a positive multiple of `spacing` after the pool's step replaces the default.
    function _alignBandOffsets(int24 spacing) internal {
        if (spacing <= 0) spacing = _spacing();
        tickSpacing = spacing;
        rangeBelowTicks = TrailingFloorLib.alignTicksDownToSpacing(rangeBelowTicks, spacing);
        rangeAboveTicks = TrailingFloorLib.alignTicksDownToSpacing(rangeAboveTicks, spacing);
        innerBelowTicks = TrailingFloorLib.alignTicksDownToSpacing(innerBelowTicks, spacing);
        innerAboveTicks = TrailingFloorLib.alignTicksDownToSpacing(innerAboveTicks, spacing);
    }

    /// @notice Set the outer mint band and the inner comfort band together.
    /// @dev One call rather than two because the four values are only meaningful relative to each other. Setting
    ///      them separately required every intermediate state to be valid as well, so widening had to be applied
    ///      outer-first and tightening inner-first or the second call reverted. Validating all four at once
    ///      removes that ordering constraint, and lets an operator move a band atomically.
    /// @dev Alignment is enforced here too. `asymmetricSpacedTicks` is otherwise the first code to reject an
    ///      unaligned value and it runs on the mint path, so a bad write would be accepted by the setter and then
    ///      revert every subsequent remint instead — stopping rebalancing with nothing to point at.
    function setBandParams(
        uint256 _rangeBelowTicks,
        uint256 _rangeAboveTicks,
        uint256 _innerBelowTicks,
        uint256 _innerAboveTicks
    ) external {
        if (!_isOperator()) revert NotOperator();
        if (tickSpacing == 0) tickSpacing = _spacing();
        TrailingFloorLib.requireSpacedTicks(_rangeBelowTicks, tickSpacing);
        TrailingFloorLib.requireSpacedTicks(_rangeAboveTicks, tickSpacing);
        TrailingFloorLib.requireSpacedTicks(_innerBelowTicks, tickSpacing);
        TrailingFloorLib.requireSpacedTicks(_innerAboveTicks, tickSpacing);
        AutoBandLib.requireInnerWithinOuter(
            _rangeBelowTicks, _rangeAboveTicks, _innerBelowTicks, _innerAboveTicks
        );
        rangeBelowTicks = _rangeBelowTicks;
        rangeAboveTicks = _rangeAboveTicks;
        innerBelowTicks = _innerBelowTicks;
        innerAboveTicks = _innerAboveTicks;
    }


}
