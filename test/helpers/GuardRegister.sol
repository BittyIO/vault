// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {IBittyV1Guard} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {LENDING_ID, STAKING_ID, AMM_ID, INTENT_ID} from "./CategoryIds.sol";

uint8 constant STABLE_COIN_CATEGORY = 1;
uint8 constant CRYPTO_CATEGORY = 2;

/**
 * @dev Registration helpers for tests.
 *
 * The guard stopped deriving a protocol's category and now takes it as an argument, which would mean
 * naming the right category at ~40 call sites. These keep the old shape by asking the protocol what
 * it is - the ERC-165 probe the guard used to do itself - so the tests describe the same setup as
 * before and a miscategorised protocol cannot creep in through a hand-written literal.
 */
function guardAddProtocols(address guard, address[] memory protocols) {
    uint8[] memory categories = new uint8[](protocols.length);
    for (uint256 i = 0; i < protocols.length; i++) {
        categories[i] = detectCategory(protocols[i]);
    }
    IBittyV1Guard(guard).addProtocols(protocols, categories);
}

function detectCategory(address protocol) view returns (uint8) {
    // Adapters no longer implement ERC-165 - the guard stopped probing for a category and now takes
    // one as an argument - so this looks for a function only that category has, by scanning the
    // runtime bytecode for its selector. Cruder than supportsInterface, but it needs no cooperation
    // from the adapter and cannot be fooled by a call that reverts for its own reasons.
    if (_hasSelector(protocol, bytes4(keccak256("removeLiquidity(bytes)")))) return AMM_ID;
    if (_hasSelector(protocol, bytes4(keccak256("isValidSignature(bytes32,bytes)")))) return INTENT_ID;

    // Fixtures built on MockCategoryProtocol carry no category function at all - they only answer the
    // ERC-165 id the guard used to probe for. Real adapters dropped ERC-165 with that scheme, so this
    // is the mock path, kept second so a real adapter is always classified by what it can actually do.
    if (_erc165(protocol, 0xb9f16a0c)) return LENDING_ID;
    if (_erc165(protocol, 0xc8ada217)) return STAKING_ID;
    if (_erc165(protocol, 0x932722bd)) return AMM_ID;
    if (_erc165(protocol, 0x1626ba7e)) return INTENT_ID;

    // Nothing above matched, so it is a plain depositable/withdrawable adapter. Lending and staking
    // are indistinguishable by interface now - both deposit, both report a balance, both withdraw -
    // and the vault treats them alike, so any yield id will do. LENDING_ID is the arbitrary pick.
    if (_hasSelector(protocol, bytes4(keccak256("getBalance(address)")))) return LENDING_ID;
    return 0;
}

function _erc165(address account, bytes4 interfaceId) view returns (bool) {
    (bool ok, bytes memory out) = account.staticcall(abi.encodeWithSelector(bytes4(0x01ffc9a7), interfaceId));
    return ok && out.length >= 32 && abi.decode(out, (bool));
}

function _hasSelector(address account, bytes4 selector) view returns (bool) {
    bytes memory code = account.code;
    for (uint256 i = 0; i + 4 <= code.length; i++) {
        if (
            code[i] == selector[0] && code[i + 1] == selector[1] && code[i + 2] == selector[2]
                && code[i + 3] == selector[3]
        ) {
            return true;
        }
    }
    return false;
}

function guardAddAssets(address guard, address[] memory assets) {
    IBittyV1Guard(guard).addAssets(assets, _fill(assets.length, CRYPTO_CATEGORY));
}

/**
 * @dev Stable coins are ordinary assets carrying the stable coin category now.
 */
function guardAddStableCoins(address guard, address[] memory coins) {
    IBittyV1Guard(guard).addAssets(coins, _fill(coins.length, STABLE_COIN_CATEGORY));
}

function _fill(uint256 n, uint8 category) pure returns (uint8[] memory out) {
    out = new uint8[](n);
    for (uint256 i = 0; i < n; i++) {
        out[i] = category;
    }
}
