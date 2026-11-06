// Writes the TRON addresses into the Solidity sources that compile them in as constants.
//
// Each edit replaces exactly one existing declaration and fails if it cannot find it, so a renamed
// constant breaks the plan loudly instead of leaving an EVM address behind on TRON.

import { readFileSync, writeFileSync } from "node:fs";
import { toEvm } from "./address.mjs";

export function setAddressConstant(file, name, address) {
  return replaceOnce(
    file,
    new RegExp(`(address\\s+(?:private\\s+|internal\\s+|public\\s+)?constant\\s+${name}\\s*=\\s*)0x[0-9a-fA-F]{40}`),
    `$1${toEvm(address)}`,
    name,
  );
}

export function setBytes32Constant(file, name, value) {
  if (!/^0x[0-9a-fA-F]{64}$/.test(value)) throw new Error(`${name}: not a bytes32: ${value}`);
  return replaceOnce(
    file,
    new RegExp(`(bytes32\\s+(?:private\\s+|internal\\s+|public\\s+)?constant\\s+${name}\\s*=\\s*)0x[0-9a-fA-F]{64}`),
    `$1${value.toLowerCase()}`,
    name,
  );
}

/** @returns whether the file changed. */
function replaceOnce(file, pattern, replacement, name) {
  const source = readFileSync(file, "utf8");
  const matches = source.match(new RegExp(pattern.source, "g")) ?? [];
  if (matches.length !== 1) throw new Error(`${name}: expected one declaration in ${file}, found ${matches.length}`);
  const next = source.replace(pattern, replacement);
  if (next === source) return false;
  writeFileSync(file, next);
  return true;
}
