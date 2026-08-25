// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

/**
 * @notice A stand-in that declares exactly one protocol category and nothing else.
 * @dev The guard verifies a protocol's category via ERC-165 before registering it, so a fixture can
 *      no longer be a bare `makeAddr` — an address with no code declares nothing and is rejected.
 *
 *      Beyond that it implements only {initialize} — not because registration is generic, but
 *      because registering an INTENT protocol clones it and initializes the clone on the spot, so a
 *      mock without it cannot be registered at all. Every other function of every category is
 *      deliberately absent: these fixtures exist for tests about REGISTRATION and allow-listing,
 *      which never call through. A test that does call through needs a real behavioural mock, and
 *      will fail loudly against this one rather than quietly pass.
 */
contract MockCategoryProtocol {
    /// @dev ERC-165's own id: `bytes4(keccak256("supportsInterface(bytes4)"))`.
    bytes4 private constant ERC165_ID = 0x01ffc9a7;

    bytes4 private immutable _categoryId;

    constructor(bytes4 categoryId) {
        _categoryId = categoryId;
    }

    /// @dev No-op: the clone has no state worth setting, and registration only needs the call to pass.
    function initialize(address) external {}

    /// @dev Answers false for 0xffffffff, as ERC-165 requires — {ERC165Checker} checks exactly that.
    function supportsInterface(bytes4 interfaceId) external view returns (bool) {
        return interfaceId == _categoryId || interfaceId == ERC165_ID;
    }
}
