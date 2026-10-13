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
    function softDeleverage(address stockAdapter) external returns (uint256 repaid);
    function compoundIntoStock(
        address stockAdapter,
        uint256 usdcIn,
        address swapTarget,
        address swapSpender,
        bytes calldata swapData,
        uint256 minStockOut
    ) external returns (uint256 stockAdded);
}

interface IStabilityPoolLiquidate {
    function liquidate(address adapter, address user) external returns (uint256 absorbed);
}

interface IVaultSnapshot {
    function snapshot() external;
}

/// @title AgamaCREReceiver
/// @notice Where the `agama-monad` Chainlink CRE workflow lands on Monad: the
///         whole keeper of the protocol, run by the DON. Every run it agrees on
///         one report that carries
///
///           - the Chainlink Data Streams reports worth storing, for the stock
///             oracle and the gold oracle, each still signed by the Data
///             Streams DON. The oracle has Chainlink's VerifierProxy check
///             those signatures, so a price needs both DONs: one to agree it
///             is the one to bring, the other to have signed it;
///           - the jobs the agents owe the positions: liquidate under HF 1,
///             soft-deleverage under HF 1.15, bring a position back to the LTV
///             its owner picked, turn the vault's yield into more stock through
///             Kuru, and the vault's daily NAV snapshot.
///
///         The receiver holds no role in the protocol and no funds: every call
///         it makes is open to anyone. What it adds is who decides when they
///         run. Each item runs on its own, so a price that lost a race to
///         another keeper, or a position that moved since the DON read it, is
///         skipped rather than taking the rest of the report down with it.
contract AgamaCREReceiver is IReceiver, AccessControl {
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

    enum Kind {
        Liquidate,
        SoftDeleverage,
        Rebalance,
        Compound,
        Snapshot
    }

    /// @notice Data Streams reports for one oracle.
    struct Prices {
        address oracle;
        bytes[] reports;
    }

    /// @notice One agent job. `data` is only read by Compound:
    ///         abi.encode(usdcIn, swapTarget, swapSpender, swapData, minStockOut).
    ///         Snapshot calls `adapter` (the vault adapter).
    struct Job {
        Kind kind;
        address account;
        address adapter;
        bytes data;
    }

    IStabilityPoolLiquidate public immutable STABILITY_POOL;

    /// @notice Keystone Forwarders allowed to deliver reports (the DON's, and
    ///         the mock one `cre workflow simulate --broadcast` writes through).
    mapping(address forwarder => bool) public isForwarder;
    /// @notice The oracles prices may be handed to: the stocks' and gold's.
    mapping(address oracle => bool) public isOracle;
    /// @notice When set, only reports from this workflow owner are accepted.
    address public expectedOwner;

    event ForwarderSet(address indexed forwarder, bool allowed);
    event OracleSet(address indexed oracle, bool allowed);
    event ExpectedOwnerSet(address indexed owner);
    event PriceStored(address indexed oracle, uint256 index);
    event PriceSkipped(address indexed oracle, uint256 index, bytes reason);
    event JobDone(Kind indexed kind, address indexed account, address indexed adapter);
    event JobSkipped(Kind indexed kind, address indexed account, address indexed adapter, bytes reason);
    event ReportHandled(
        bytes32 indexed workflowId, uint256 prices, uint256 stored, uint256 jobs, uint256 done
    );

    error NotForwarder(address sender);
    error WrongOwner(address owner);
    error UnknownOracle(address oracle);

    constructor(
        IStabilityPoolLiquidate stabilityPool,
        address admin,
        address[] memory forwarders,
        address[] memory oracles
    ) {
        STABILITY_POOL = stabilityPool;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
        for (uint256 i; i < forwarders.length; ++i) {
            isForwarder[forwarders[i]] = true;
            emit ForwarderSet(forwarders[i], true);
        }
        for (uint256 i; i < oracles.length; ++i) {
            isOracle[oracles[i]] = true;
            emit OracleSet(oracles[i], true);
        }
    }

    /// @param metadata abi.encodePacked(workflowId, workflowName (bytes10), workflowOwner).
    /// @param report   abi.encode(Prices[] prices, Job[] jobs).
    function onReport(bytes calldata metadata, bytes calldata report) external override {
        if (!isForwarder[msg.sender]) revert NotForwarder(msg.sender);
        (bytes32 workflowId, address owner) = _metadata(metadata);
        if (expectedOwner != address(0) && owner != expectedOwner) revert WrongOwner(owner);

        (Prices[] memory prices, Job[] memory jobs) = abi.decode(report, (Prices[], Job[]));

        uint256 sent;
        uint256 stored;
        for (uint256 i; i < prices.length; ++i) {
            address oracle = prices[i].oracle;
            if (!isOracle[oracle]) revert UnknownOracle(oracle);
            bytes[] memory reports = prices[i].reports;
            for (uint256 j; j < reports.length; ++j) {
                try IDataStreamsOracle(oracle).pushReport(reports[j]) {
                    ++stored;
                    emit PriceStored(oracle, sent + j);
                } catch (bytes memory reason) {
                    emit PriceSkipped(oracle, sent + j, reason);
                }
            }
            sent += reports.length;
        }

        uint256 done;
        for (uint256 i; i < jobs.length; ++i) {
            Job memory job = jobs[i];
            try this.run(job) {
                ++done;
                emit JobDone(job.kind, job.account, job.adapter);
            } catch (bytes memory reason) {
                emit JobSkipped(job.kind, job.account, job.adapter, reason);
            }
        }
        emit ReportHandled(workflowId, sent, stored, jobs.length, done);
    }

    /// @notice One job. External so `onReport` can try it and move on; only
    ///         this contract may call it, though every call it makes is
    ///         permissionless anyway.
    function run(Job calldata job) external {
        if (msg.sender != address(this)) revert NotForwarder(msg.sender);
        if (job.kind == Kind.Liquidate) {
            STABILITY_POOL.liquidate(job.adapter, job.account);
        } else if (job.kind == Kind.SoftDeleverage) {
            IAgamaAccountAgent(job.account).softDeleverage(job.adapter);
        } else if (job.kind == Kind.Rebalance) {
            IAgamaAccountAgent(job.account).rebalance(job.adapter);
        } else if (job.kind == Kind.Compound) {
            (uint256 usdcIn, address target, address spender, bytes memory swapData, uint256 minOut) =
                abi.decode(job.data, (uint256, address, address, bytes, uint256));
            IAgamaAccountAgent(job.account)
                .compoundIntoStock(job.adapter, usdcIn, target, spender, swapData, minOut);
        } else {
            IVaultSnapshot(job.adapter).snapshot();
        }
    }

    function setForwarder(address forwarder, bool allowed) external onlyRole(GOVERNOR_ROLE) {
        isForwarder[forwarder] = allowed;
        emit ForwarderSet(forwarder, allowed);
    }

    function setOracle(address oracle, bool allowed) external onlyRole(GOVERNOR_ROLE) {
        isOracle[oracle] = allowed;
        emit OracleSet(oracle, allowed);
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
