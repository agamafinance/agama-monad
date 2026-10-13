// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title AgamaJournal
/// @notice Each wallet's private journal, kept on Monad as ciphertext only.
///
///         The app seals the journal with a key the user's passkey derives
///         under its own PRF salt (Mera's secret vault: HKDF to AES-256-GCM),
///         not the salt the account key comes from. This contract never sees a
///         key or a plaintext: it stores the sealed vault, one per writer, and
///         the latest write replaces the previous one. Any device the passkey
///         syncs to can read it back and open it; nobody else can.
contract AgamaJournal {
    /// A sealed journal is a few kilobytes of JSON at most.
    uint256 public constant MAX_BYTES = 8192;

    mapping(address => bytes) internal vaults;
    mapping(address => uint256) public writes;

    event JournalWritten(address indexed writer, uint256 indexed version, bytes32 digest, uint256 size);

    error TooLarge(uint256 size);

    /// @notice Store `vault` as the caller's journal. An empty `vault` clears it.
    function write(bytes calldata vault) external {
        if (vault.length > MAX_BYTES) revert TooLarge(vault.length);
        vaults[msg.sender] = vault;
        uint256 version = ++writes[msg.sender];
        emit JournalWritten(msg.sender, version, keccak256(vault), vault.length);
    }

    /// @notice The sealed journal of `writer`, as written. Readable by anyone,
    ///         useful to no one without the passkey.
    function journalOf(address writer) external view returns (bytes memory) {
        return vaults[writer];
    }
}
