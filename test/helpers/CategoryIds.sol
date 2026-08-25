// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

// The four protocol category ids, for tests that talk to the guard.
//
// The guard's protocol API is keyed by ERC-165 category id rather than by a function per category,
// so a test that registers or queries a protocol needs the id as a value. Declared once here so the
// literals are not copied into every test file that touches the guard.
//
// These must match AssetManagerLogic's copies and the guard's own; InterfaceIds.t.sol in
// protocol-store is what pins them, and a mismatch shows up there as a failing build.
bytes4 constant LENDING_ID = 0xb9f16a0c;
bytes4 constant STAKING_ID = 0xc8ada217;
bytes4 constant AMM_ID = 0x932722bd;
bytes4 constant INTENT_ID = 0x1626ba7e;
