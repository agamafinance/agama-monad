// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StockOracle} from "./StockOracle.sol";

interface IVerifierProxy {
    function verify(bytes calldata payload, bytes calldata parameterPayload)
        external
        payable
        returns (bytes memory verifierResponse);
}

/// @title DataStreamsStockOracle
/// @notice StockOracle that also accepts signed Chainlink Data Streams
///         reports (schema v11, "RWA Advanced", the US-equities 24/5
///         schema) and verifies them on-chain against the X Layer
///         VerifierProxy.
///
///         `pushReport` is PERMISSIONLESS: a verified Chainlink report is
///         the source of truth, whoever carries it (keeper, liquidator, or
///         the user attaching it to their own transaction).
///
///         On X Layer the VerifierProxy has no FeeManager (verification is
///         free, `parameterPayload` is empty). The FeeManager is also where
///         Chainlink enforces report expiry, so this contract enforces
///         freshness itself: `expiresAt`, observation age and monotonicity.
///
///         Market status (v11 `marketStatus`): 0 Unknown, 1 Pre-market,
///         2 Regular, 3 Post-market, 4 Overnight, 5 Closed. Which statuses
///         count as "open" is a governance bitmask; default = 1|2|3|4
///         (xStocks trade 24/5), Closed and Unknown freeze the price.
contract DataStreamsStockOracle is StockOracle {
    /// @dev Chainlink v11 report body (after the verifier strips the envelope).
    struct ReportV11 {
        bytes32 feedId;
        uint32 validFromTimestamp;
        uint32 observationsTimestamp;
        uint192 nativeFee;
        uint192 linkFee;
        uint32 expiresAt;
        int192 mid;
        uint64 lastSeenTimestampNs;
        int192 bid;
        int192 bidVolume;
        int192 ask;
        int192 askVolume;
        int192 lastTradedPrice;
        uint32 marketStatus;
    }

    struct StreamConfig {
        bytes32 ticker;
        uint8 decimals; // decimals of `mid` in the report (8 or 18)
        bool enabled;
        /// Bit i set = this stream may report marketStatus i. Chainlink runs
        /// one stream per session (regular, extended, overnight): each is
        /// only believed for its own session, so a stale regular-hours price
        /// cannot be brought in while the overnight session trades.
        uint32 sessions;
    }

    uint16 public constant SCHEMA_V11 = 0x000b;
    /// @notice A report must have been observed within this many seconds.
    uint256 public constant MAX_REPORT_AGE = 300;

    IVerifierProxy public immutable VERIFIER;
    mapping(bytes32 feedId => StreamConfig) public streams;
    /// @notice Bit i set = marketStatus i counts as open.
    uint32 public openStatusMask = (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4);

    event StreamSet(bytes32 indexed feedId, bytes32 indexed ticker, uint8 decimals, bool enabled, uint32 sessions);
    event OpenStatusMaskSet(uint32 mask);
    event ReportAccepted(bytes32 indexed feedId, bytes32 indexed ticker, uint256 price, uint32 marketStatus);

    error UnsupportedSchema(uint16 version);
    error UnknownStream(bytes32 feedId);
    error ReportExpired();
    error ReportTooOld(uint256 age);
    error NegativePrice();
    error WrongSession(bytes32 feedId, uint32 marketStatus);

    constructor(address admin, address keeper, IVerifierProxy verifier) StockOracle(admin, keeper) {
        VERIFIER = verifier;
    }

    /// @notice Verify one signed report and store its price.
    /// @param fullReport The `fullReport` blob returned by the Data Streams API.
    function pushReport(bytes calldata fullReport) external {
        _pushReport(fullReport);
    }

    function pushReports(bytes[] calldata fullReports) external {
        for (uint256 i; i < fullReports.length; ++i) {
            _pushReport(fullReports[i]);
        }
    }

    function _pushReport(bytes calldata fullReport) internal {
        (, bytes memory reportData) = abi.decode(fullReport, (bytes32[3], bytes));
        uint16 version = (uint16(uint8(reportData[0])) << 8) | uint16(uint8(reportData[1]));
        if (version != SCHEMA_V11) revert UnsupportedSchema(version);

        bytes memory verified = VERIFIER.verify(fullReport, "");
        ReportV11 memory r = abi.decode(verified, (ReportV11));

        StreamConfig memory cfg = streams[r.feedId];
        if (!cfg.enabled) revert UnknownStream(r.feedId);
        if (r.expiresAt < block.timestamp) revert ReportExpired();
        uint256 age = block.timestamp - r.observationsTimestamp;
        if (age > MAX_REPORT_AGE) revert ReportTooOld(age);
        if ((cfg.sessions >> r.marketStatus) & 1 == 0) revert WrongSession(r.feedId, r.marketStatus);
        if (r.mid <= 0) revert NegativePrice();

        uint256 price = uint256(uint192(r.mid));
        if (cfg.decimals < 18) price *= 10 ** (18 - cfg.decimals);
        else if (cfg.decimals > 18) price /= 10 ** (cfg.decimals - 18);

        bool open = (openStatusMask >> r.marketStatus) & 1 == 1;
        // Signed Chainlink data is not subject to the keeper deviation cap:
        // a real 30% gap must be accepted, not rejected.
        _write(cfg.ticker, price, r.observationsTimestamp, open, true);
        emit ReportAccepted(r.feedId, cfg.ticker, price, r.marketStatus);
    }

    // ---- Admin -------------------------------------------------------------

    function setStream(bytes32 feedId, bytes32 ticker, uint8 decimals, bool enabled, uint32 sessions)
        external
        onlyRole(GOVERNOR_ROLE)
    {
        if (!_feeds[ticker].exists) revert UnknownTicker(ticker);
        streams[feedId] = StreamConfig({ticker: ticker, decimals: decimals, enabled: enabled, sessions: sessions});
        emit StreamSet(feedId, ticker, decimals, enabled, sessions);
    }

    function setOpenStatusMask(uint32 mask) external onlyRole(GOVERNOR_ROLE) {
        openStatusMask = mask;
        emit OpenStatusMaskSet(mask);
    }
}
