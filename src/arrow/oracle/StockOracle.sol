// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

interface IAggregatorV3 {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title StockOracle
/// @notice Stored US-equity prices for the Arrow lending pool on X Layer.
///
///         X Layer has no push price feed for stocks: Chainlink Data Streams
///         (live on X Layer, US equities 24/5) is pull-based and nothing
///         stores those prices on-chain. This contract is the on-chain store
///         a lending market can read. Two write paths:
///           - `push`: a keeper posts price + market status. Bounded by a
///             per-update deviation cap so a compromised or buggy keeper
///             cannot move a price arbitrarily in one step.
///           - `pushReport` (Data Streams): see `DataStreamsStockOracle`,
///             which verifies a signed Chainlink report on-chain and writes
///             through the same `_write` path.
///
///         Market-hours model:
///           - The feed carries `marketOpen`. While the market is closed
///             (nights between sessions are covered 24/5, weekends and
///             holidays are not), the last price is FROZEN and stays usable
///             for up to `maxClosedStaleness`. Adapters read `marketOpen` to
///             block new borrows and to tighten liquidation thresholds.
///           - On reopen, the first price may gap. The deviation cap for a
///             closed-to-open transition is `maxGapBps`, wider than the
///             intra-session `maxDeviationBps`.
///
///         L2 safety: if a Chainlink sequencer-uptime feed is configured,
///         reads revert while the sequencer is down and during a grace
///         period after it comes back (standard Chainlink L2 pattern).
///
/// @dev    Prices are USD per ONE share, 1e18-scaled. `getPrice` never
///         falls back to a default value: it returns a real stored price or
///         reverts.
contract StockOracle is AccessControl {
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    uint256 internal constant BPS = 10_000;

    struct Feed {
        uint128 price; // USD per share, 1e18
        uint64 observedAt; // timestamp of the observation (not of the tx)
        bool marketOpen;
        bool exists;
    }

    mapping(bytes32 ticker => Feed) internal _feeds;
    bytes32[] public tickers;

    /// @notice Max age of a price while the market is open.
    uint256 public maxOpenStaleness;
    /// @notice Max age of a frozen price while the market is closed
    ///         (a long weekend is Friday 20:00 UTC to Tuesday 13:30 UTC).
    uint256 public maxClosedStaleness;
    /// @notice Max move between two consecutive open-market prices.
    uint256 public maxDeviationBps;
    /// @notice Max move on a closed-to-open transition (weekend gap).
    uint256 public maxGapBps;

    IAggregatorV3 public sequencerUptimeFeed;
    uint256 public constant SEQUENCER_GRACE_PERIOD = 1 hours;

    event FeedAdded(bytes32 indexed ticker);
    event PriceWritten(
        bytes32 indexed ticker, uint256 price, uint64 observedAt, bool marketOpen, bool forced
    );
    event ParamsSet(
        uint256 maxOpenStaleness, uint256 maxClosedStaleness, uint256 maxDeviationBps, uint256 maxGapBps
    );
    event SequencerFeedSet(address feed);

    error UnknownTicker(bytes32 ticker);
    error TickerExists(bytes32 ticker);
    error ZeroPrice();
    error PriceOutOfRange(uint256 price);
    error ObservationInFuture();
    error ObservationNotNewer();
    error DeviationTooLarge(uint256 moveBps, uint256 capBps);
    error PriceStale(bytes32 ticker, uint256 age, uint256 maxAge);
    error SequencerDown();
    error SequencerGracePeriod();
    error InvalidParams();

    constructor(address admin, address keeper) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
        if (keeper != address(0)) _grantRole(KEEPER_ROLE, keeper);
        maxOpenStaleness = 1 hours;
        maxClosedStaleness = 4 days;
        maxDeviationBps = 1_500; // 15% per update inside a session
        maxGapBps = 5_000; // 50% on reopen
    }

    // ---- Writes ------------------------------------------------------------

    function addFeed(bytes32 ticker) external onlyRole(GOVERNOR_ROLE) {
        if (_feeds[ticker].exists) revert TickerExists(ticker);
        _feeds[ticker].exists = true;
        tickers.push(ticker);
        emit FeedAdded(ticker);
    }

    /// @notice Keeper write, bounded by the deviation caps.
    function push(bytes32 ticker, uint256 price, uint64 observedAt, bool marketOpen)
        external
        onlyRole(KEEPER_ROLE)
    {
        _write(ticker, price, observedAt, marketOpen, false);
    }

    /// @notice Batch variant for the keeper (one tx per tick).
    function pushMany(
        bytes32[] calldata tickers_,
        uint256[] calldata prices,
        uint64 observedAt,
        bool marketOpen
    ) external onlyRole(KEEPER_ROLE) {
        if (tickers_.length != prices.length) revert InvalidParams();
        for (uint256 i; i < tickers_.length; ++i) {
            _write(tickers_[i], prices[i], observedAt, marketOpen, false);
        }
    }

    /// @notice Governor override that skips the deviation cap (stock split,
    ///         corporate action, recovery after a halt). Still requires a
    ///         newer observation and a non-zero price.
    function forcePush(bytes32 ticker, uint256 price, uint64 observedAt, bool marketOpen)
        external
        onlyRole(GOVERNOR_ROLE)
    {
        _write(ticker, price, observedAt, marketOpen, true);
    }

    function _write(bytes32 ticker, uint256 price, uint64 observedAt, bool marketOpen, bool forced) internal {
        Feed storage f = _feeds[ticker];
        if (!f.exists) revert UnknownTicker(ticker);
        if (price == 0) revert ZeroPrice();
        // The feed stores a uint128 and Solidity truncates a downcast in
        // silence. The deviation cap would catch an absurd value on the keeper
        // path, but `forced` (signed data) skips it, so the bound goes here.
        if (price > type(uint128).max) revert PriceOutOfRange(price);
        if (observedAt > block.timestamp) revert ObservationInFuture();
        if (observedAt <= f.observedAt) revert ObservationNotNewer();

        if (!forced && f.price != 0) {
            uint256 prev = f.price;
            uint256 move = price > prev ? price - prev : prev - price;
            uint256 moveBps = (move * BPS) / prev;
            uint256 cap = f.marketOpen ? maxDeviationBps : maxGapBps;
            if (moveBps > cap) revert DeviationTooLarge(moveBps, cap);
        }

        f.price = uint128(price);
        f.observedAt = observedAt;
        f.marketOpen = marketOpen;
        emit PriceWritten(ticker, price, observedAt, marketOpen, forced);
    }

    // ---- Reads -------------------------------------------------------------

    /// @notice Price usable for valuation. Reverts if unknown, zero, stale
    ///         for the current market status, or if the L2 sequencer is down.
    function getPrice(bytes32 ticker)
        external
        view
        returns (uint256 price, uint256 observedAt, bool marketOpen)
    {
        _checkSequencer();
        Feed memory f = _feeds[ticker];
        if (!f.exists) revert UnknownTicker(ticker);
        if (f.price == 0) revert ZeroPrice();
        uint256 age = block.timestamp - f.observedAt;
        uint256 maxAge = f.marketOpen ? maxOpenStaleness : maxClosedStaleness;
        if (age > maxAge) revert PriceStale(ticker, age, maxAge);
        return (f.price, f.observedAt, f.marketOpen);
    }

    /// @notice Raw feed, never reverts. For UIs and for adapters that only
    ///         need the market status.
    function feed(bytes32 ticker) external view returns (Feed memory) {
        return _feeds[ticker];
    }

    function isMarketOpen(bytes32 ticker) external view returns (bool) {
        return _feeds[ticker].marketOpen;
    }

    function tickerCount() external view returns (uint256) {
        return tickers.length;
    }

    // ---- Admin -------------------------------------------------------------

    function setParams(
        uint256 maxOpenStaleness_,
        uint256 maxClosedStaleness_,
        uint256 maxDeviationBps_,
        uint256 maxGapBps_
    ) external onlyRole(GOVERNOR_ROLE) {
        if (maxOpenStaleness_ == 0 || maxClosedStaleness_ < maxOpenStaleness_) {
            revert InvalidParams();
        }
        if (maxDeviationBps_ == 0 || maxGapBps_ < maxDeviationBps_ || maxGapBps_ > BPS) {
            revert InvalidParams();
        }
        maxOpenStaleness = maxOpenStaleness_;
        maxClosedStaleness = maxClosedStaleness_;
        maxDeviationBps = maxDeviationBps_;
        maxGapBps = maxGapBps_;
        emit ParamsSet(maxOpenStaleness_, maxClosedStaleness_, maxDeviationBps_, maxGapBps_);
    }

    function setSequencerUptimeFeed(address feed_) external onlyRole(GOVERNOR_ROLE) {
        sequencerUptimeFeed = IAggregatorV3(feed_);
        emit SequencerFeedSet(feed_);
    }

    function _checkSequencer() internal view {
        IAggregatorV3 s = sequencerUptimeFeed;
        if (address(s) == address(0)) return;
        (, int256 answer, uint256 startedAt,,) = s.latestRoundData();
        // Chainlink convention: 0 = up, 1 = down.
        if (answer != 0) revert SequencerDown();
        if (block.timestamp - startedAt <= SEQUENCER_GRACE_PERIOD) revert SequencerGracePeriod();
    }
}
