// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StockOracle} from "./StockOracle.sol";
import {IVerifierProxy} from "./DataStreamsStockOracle.sol";

/// @title DataStreamsGoldOracle
/// @notice StockOracle for gold: signed Chainlink Data Streams reports of
///         schema v3 (the crypto and FX schema, which carries XAU/USD),
///         verified on chain by Chainlink's VerifierProxy before the price is
///         stored. One XAUt0 is one troy ounce, so the XAU/USD benchmark is
///         its price.
///
///         `pushReport` is PERMISSIONLESS, as on the stock oracle. v3 has no
///         market status: the stream publishes around the clock and the
///         market is always open here. Freshness is enforced in the contract
///         (`expiresAt`, a report under five minutes old, newer than the last),
///         since the VerifierProxy on Monad testnet has no FeeManager.
contract DataStreamsGoldOracle is StockOracle {
    /// @dev Chainlink v3 report body (after the verifier strips the envelope).
    struct ReportV3 {
        bytes32 feedId;
        uint32 validFromTimestamp;
        uint32 observationsTimestamp;
        uint192 nativeFee;
        uint192 linkFee;
        uint32 expiresAt;
        int192 benchmarkPrice;
        int192 bid;
        int192 ask;
    }

    uint16 public constant SCHEMA_V3 = 0x0003;
    /// @notice A report must have been observed within this many seconds.
    uint256 public constant MAX_REPORT_AGE = 300;

    IVerifierProxy public immutable VERIFIER;
    /// @notice The ticker each accepted stream prices (18-decimal reports).
    mapping(bytes32 feedId => bytes32 ticker) public tickerOf;

    event StreamSet(bytes32 indexed feedId, bytes32 indexed ticker);
    event ReportAccepted(bytes32 indexed feedId, bytes32 indexed ticker, uint256 price);

    error UnsupportedSchema(uint16 version);
    error UnknownStream(bytes32 feedId);
    error ReportExpired();
    error ReportTooOld(uint256 age);
    error NegativePrice();

    constructor(address admin, address keeper, IVerifierProxy verifier) StockOracle(admin, keeper) {
        VERIFIER = verifier;
    }

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
        if (version != SCHEMA_V3) revert UnsupportedSchema(version);

        bytes memory verified = VERIFIER.verify(fullReport, "");
        ReportV3 memory r = abi.decode(verified, (ReportV3));

        bytes32 ticker = tickerOf[r.feedId];
        if (ticker == bytes32(0)) revert UnknownStream(r.feedId);
        if (r.expiresAt < block.timestamp) revert ReportExpired();
        uint256 age = block.timestamp - r.observationsTimestamp;
        if (age > MAX_REPORT_AGE) revert ReportTooOld(age);
        if (r.benchmarkPrice <= 0) revert NegativePrice();

        uint256 price = uint256(uint192(r.benchmarkPrice));
        // Signed Chainlink data is not subject to the keeper deviation cap.
        _write(ticker, price, r.observationsTimestamp, true, true);
        emit ReportAccepted(r.feedId, ticker, price);
    }

    function setStream(bytes32 feedId, bytes32 ticker) external onlyRole(GOVERNOR_ROLE) {
        if (ticker != bytes32(0) && !_feeds[ticker].exists) revert UnknownTicker(ticker);
        tickerOf[feedId] = ticker;
        emit StreamSet(feedId, ticker);
    }
}
