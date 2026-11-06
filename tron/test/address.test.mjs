import { test } from "node:test";
import assert from "node:assert/strict";
import { create2Address, toBase58, toEvm, toTronHex, EVM_CREATE2_PREFIX, TVM_CREATE2_PREFIX } from "../lib/address.mjs";

// EIP-1014's own examples, run through the same function with the EVM prefix: if these hold, the
// only difference on TRON is the prefix byte.
test("create2 matches the EIP-1014 vectors under the EVM prefix", () => {
  assert.equal(
    create2Address("0x0000000000000000000000000000000000000000", "0x" + "00".repeat(32), "0x00", EVM_CREATE2_PREFIX),
    "0x4D1A2e2bB4F88F0250f26Ffff098B0b30B26BF38",
  );
  assert.equal(
    create2Address(
      "0x00000000000000000000000000000000deadbeef",
      "0x00000000000000000000000000000000000000000000000000000000cafebabe",
      "0xdeadbeef",
      EVM_CREATE2_PREFIX,
    ),
    "0x60f3f640a8508fC6a86d45DF051962668E1e8AC7",
  );
});

test("the TVM prefix gives a different address from the same inputs", () => {
  const args = ["0x00000000000000000000000000000000deadbeef", "0x" + "00".repeat(32), "0xdeadbeef"];
  assert.notEqual(create2Address(...args, TVM_CREATE2_PREFIX), create2Address(...args, EVM_CREATE2_PREFIX));
});

// USDT on TRON mainnet, a widely published pair of forms of the same account.
test("base58check, TRON hex and EVM forms round-trip", () => {
  const base58 = "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t";
  const evm = "0xa614f803B6FD780986A42c78Ec9c7f77e6DeD13C";
  assert.equal(toEvm(base58), evm);
  assert.equal(toTronHex(evm), "41a614f803b6fd780986a42c78ec9c7f77e6ded13c");
  assert.equal(toBase58(evm), base58);
  assert.equal(toEvm("41a614f803b6fd780986a42c78ec9c7f77e6ded13c"), evm);
});

test("a corrupted base58 address is refused", () => {
  assert.throws(() => toEvm("TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6u"));
});
