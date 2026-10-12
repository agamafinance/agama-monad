// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice Chainlink CRE's receiver interface: the Keystone Forwarder calls
///         `onReport` once the DON has agreed on a report and signed it.
interface IReceiver is IERC165 {
    function onReport(bytes calldata metadata, bytes calldata report) external;
}

interface IDataStreamsOracle {
    function pushReport(bytes calldata fullReport) external;
}

interface IAgamaAccountAgent {
    function rebalance(address stockAdapter) external returns (int256 debtDelta);
}

/// @title AgamaCREReceiver
/// @notice Where the `agama-monad` Chainlink CRE workflow lands on Monad. Every
///         run, the DON agrees on two things and sends them in one report:
///
///           - the latest Chainlink Data Streams reports worth storing, each
///             still signed by the Data Streams DON. They go to the oracle,
///             which has Chainlink's VerifierProxy check those signatures, so a
///             price needs both DONs: one to agree it is the one to bring, the
///             other to have signed it;
///           - the positions off their target, which the agents' `rebalance`
///             brings back.
///
///         The receiver holds no role in the protocol: both calls are open to
///         anyone. What it adds is who decides when they run. Each item runs on
///         its own, so a report that lost a race to another keeper, or a
///         position that moved since the DON read it, is skipped rather than
///         taking the rest of the report down with it.
contract AgamaCREReceiver is IReceiver, AccessControl {
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

    IDataStreamsOracle public immutable ORACLE;

    /// @notice Keystone Forwarders allowed to deliver reports (the DON's, and
    ///         the mock one `cre workflow simulate --broadcast` writes through).
    mapping(address forwarder => bool) public isForwarder;
    /// @notice When set, only reports from this workflow owner are accepted.
    address public expectedOwner;

    event ForwarderSet(address indexed forwarder, bool allowed);
    event ExpectedOwnerSet(address indexed owner);
    event PriceStored(uint256 indexed index);
    event PriceSkipped(uint256 indexed index, bytes reason);
    event Rebalanced(address indexed account, address indexed adapter, int256 debtDelta);
    event RebalanceSkipped(address indexed account, address indexed adapter, bytes reason);
    event ReportHandled(bytes32 indexed workflowId, uint256 prices, uint256 stored, uint256 rebalanced);

    error NotForwarder(address sender);
    error WrongOwner(address owner);
    error LengthMismatch();

    constructor(IDataStreamsOracle oracle, address admin, address[] memory forwarders) {
        ORACLE = oracle;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
        for (uint256 i; i < forwarders.length; ++i) {
            isForwarder[forwarders[i]] = true;
            emit ForwarderSet(forwarders[i], true);
        }
    }

    /// @param metadata abi.encodePacked(workflowId, workflowName (bytes10), workflowOwner).
    /// @param report   abi.encode(bytes[] dataStreamsReports, address[] accounts, address[] adapters).
    function onReport(bytes calldata metadata, bytes calldata report) external override {
        if (!isForwarder[msg.sender]) revert NotForwarder(msg.sender);
        (bytes32 workflowId, address owner) = _metadata(metadata);
        if (expectedOwner != address(0) && owner != expectedOwner) revert WrongOwner(owner);

        (bytes[] memory prices, address[] memory accounts, address[] memory adapters) =
            abi.decode(report, (bytes[], address[], address[]));
        if (accounts.length != adapters.length) revert LengthMismatch();

        uint256 stored;
        for (uint256 i; i < prices.length; ++i) {
            try ORACLE.pushReport(prices[i]) {
                ++stored;
                emit PriceStored(i);
            } catch (bytes memory reason) {
                emit PriceSkipped(i, reason);
            }
        }
        uint256 rebalanced;
        for (uint256 i; i < accounts.length; ++i) {
            try IAgamaAccountAgent(accounts[i]).rebalance(adapters[i]) returns (int256 delta) {
                ++rebalanced;
                emit Rebalanced(accounts[i], adapters[i], delta);
            } catch (bytes memory reason) {
                emit RebalanceSkipped(accounts[i], adapters[i], reason);
            }
        }
        emit ReportHandled(workflowId, prices.length, stored, rebalanced);
    }

    function setForwarder(address forwarder, bool allowed) external onlyRole(GOVERNOR_ROLE) {
        isForwarder[forwarder] = allowed;
        emit ForwarderSet(forwarder, allowed);
    }

    function setExpectedOwner(address owner) external onlyRole(GOVERNOR_ROLE) {
        expectedOwner = owner;
        emit ExpectedOwnerSet(owner);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControl, IERC165)
        returns (bool)
    {
        return interfaceId == type(IReceiver).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @dev Same layout Chainlink's ReceiverTemplate reads: workflowId at 0,
    ///      the bytes10 name at 32, the owner at 42.
    function _metadata(bytes calldata metadata) internal pure returns (bytes32 workflowId, address owner) {
        if (metadata.length < 62) return (bytes32(0), address(0));
        workflowId = bytes32(metadata[0:32]);
        owner = address(bytes20(metadata[42:62]));
    }
}
