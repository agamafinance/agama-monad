// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {AgamaAccount} from "./AgamaAccount.sol";

/// @title AgamaAccountFactory
/// @notice Deploys one AgamaAccount clone per user (deterministic address,
///         salt = user) and keeps the registry of routers allowed to act for
///         an account owner.
contract AgamaAccountFactory is AccessControl {
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

    address public immutable IMPLEMENTATION;
    mapping(address user => address) public accountOf;
    mapping(address router => bool) public isRouter;
    /// @notice The zap router, whose swap allowlist the accounts reuse when the
    ///         agents compound vault yield back into stock.
    address public zapRouter;
    address[] public accounts;

    event AccountCreated(address indexed user, address indexed account);
    event RouterSet(address indexed router, bool allowed);
    event ZapRouterSet(address indexed zap);

    constructor(address implementation, address admin) {
        IMPLEMENTATION = implementation;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
    }

    function getOrCreate(address user) public returns (address account) {
        account = accountOf[user];
        if (account != address(0)) return account;
        account = Clones.cloneDeterministic(IMPLEMENTATION, bytes32(uint256(uint160(user))));
        AgamaAccount(account).initialize(user);
        accountOf[user] = account;
        accounts.push(account);
        emit AccountCreated(user, account);
    }

    function predict(address user) external view returns (address) {
        return Clones.predictDeterministicAddress(IMPLEMENTATION, bytes32(uint256(uint160(user))));
    }

    function accountCount() external view returns (uint256) {
        return accounts.length;
    }

    function setZapRouter(address zap) external onlyRole(GOVERNOR_ROLE) {
        zapRouter = zap;
        emit ZapRouterSet(zap);
    }

    function setRouter(address router, bool allowed) external onlyRole(GOVERNOR_ROLE) {
        isRouter[router] = allowed;
        emit RouterSet(router, allowed);
    }
}
