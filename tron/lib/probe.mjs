// Checks, against a live TRON node and without signing anything, the VM facts this deployment rests
// on. Each probe is init code run through /wallet/triggerconstantcontract with no contract address,
// which executes it as a deployment and returns what it returns.
//
// First run, 2026-11-07: every probe passed on both Nile and mainnet.

import { create2Address, toEvm, TVM_CREATE2_PREFIX, ZERO_SALT } from "./address.mjs";

const OWNER = "4112ee2de7bf086388b1d560eb95e7191edfab9823";

async function simulate(fullHost, data, apiKey) {
  const res = await fetch(`${fullHost.replace(/\/$/, "")}/wallet/triggerconstantcontract`, {
    method: "POST",
    headers: { "content-type": "application/json", ...(apiKey ? { "TRON-PRO-API-KEY": apiKey } : {}) },
    body: JSON.stringify({ owner_address: OWNER, contract_address: "", data: data.replace(/^0x/, "") }),
  });
  const json = await res.json();
  const message = json.result?.message ? Buffer.from(json.result.message, "hex").toString() : "";
  return { ok: json.result?.result === true, out: json.constant_result?.[0] ?? "", energy: json.energy_used, message };
}

const word = (hex, i = 0) => BigInt("0x" + (hex.slice(i * 64, (i + 1) * 64) || "0"));

export async function probe({ fullHost, chainId, apiKey }) {
  const results = [];
  const check = (name, pass, detail) => results.push({ name, pass, detail });
  const pause = () => new Promise((r) => setTimeout(r, 1_200)); // TronGrid's anonymous rate limit

  const control = await simulate(fullHost, "0x602a60005260206000f3", apiKey);
  check("control returns 42", control.ok && word(control.out) === 42n, control.message);
  await pause();
  const invalid = await simulate(fullHost, "0xfe", apiKey);
  check("an invalid opcode is refused", !invalid.ok, invalid.message.slice(0, 60));

  for (const [name, code] of [
    ["PUSH0", "0x602a5f5260205ff3"],
    ["TSTORE/TLOAD", "0x602a60015d60015c60005260206000f3"],
    ["MCOPY", "0x602a6000526020600060205e60206020f3"],
  ]) {
    await pause();
    const r = await simulate(fullHost, code, apiKey);
    check(name, r.ok && word(r.out) === 42n, r.message);
  }

  await pause();
  const id = await simulate(fullHost, "0x4660005260206000f3", apiKey);
  check(`CHAINID is ${chainId}`, id.ok && word(id.out) === BigInt(chainId), `got ${word(id.out)}`);

  // CREATE2 of a contract returning empty code, then the creator's own ADDRESS: the TVM's answer
  // must be our 0x41 formula's.
  await pause();
  const inner = "0x60006000f3";
  const c2 = await simulate(fullHost, "0x6460006000f35f525f6005601b5ff5602052305f5260405ff3", apiKey);
  const self = toEvm("0x" + c2.out.slice(24, 64));
  const created = toEvm("0x" + c2.out.slice(64 + 24, 128));
  const predicted = create2Address(self, ZERO_SALT, inner, TVM_CREATE2_PREFIX);
  check("CREATE2 uses the 0x41 formula", c2.ok && created === predicted, `tvm ${created}, formula ${predicted}`);

  return results;
}

/** Runs real init code as a deployment simulation: does it execute on this TVM, and at what energy. */
export async function simulateDeployment({ fullHost, apiKey }, initCode) {
  return simulate(fullHost, initCode, apiKey);
}
