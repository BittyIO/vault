// The only module that talks to a TRON node. Every call's arguments are ABI-encoded here with
// ethers (20-byte EVM addresses, exactly what the contracts expect) and handed to TronWeb as a raw
// parameter, so TronWeb's own address conversion never touches them.

import { AbiCoder, Interface } from "ethers";
import { TronWeb } from "tronweb";
import { toBase58, toEvm, toTronHex } from "./address.mjs";

const abi = AbiCoder.defaultAbiCoder();
const SUN_PER_TRX = 1_000_000;

export class Chain {
  constructor({ fullHost, privateKey, feeLimitTrx = 1_000, apiKey, dryRun = false }) {
    const headers = apiKey ? { "TRON-PRO-API-KEY": apiKey } : undefined;
    this.tronWeb = new TronWeb({ fullHost, headers, privateKey });
    this.fullHost = fullHost;
    this.headers = headers ?? {};
    this.feeLimit = feeLimitTrx * SUN_PER_TRX;
    this.dryRun = dryRun;
    this.sender = privateKey ? toEvm(this.tronWeb.defaultAddress.hex) : null;
  }

  /**
   * Whether `address` holds a contract, by eth_getCode. Not by /wallet/getcontract: for a contract
   * created by another contract (everything placed through the CREATE2 deployer) that returns the
   * contract's record without its `bytecode`, which reads as "no code" for code that is there.
   * A failed request is retried and then thrown, never read as "no code": the deploy would otherwise
   * try to create, and pay for, a contract already there.
   */
  async hasCode(address) {
    for (let attempt = 1; ; attempt++) {
      try {
        const code = await this._rpc("eth_getCode", [toEvm(address), "latest"]);
        if (typeof code !== "string" || !code.startsWith("0x")) throw new Error(`unexpected eth_getCode answer ${code}`);
        return code.length > 2;
      } catch (e) {
        if (attempt >= 4) throw new Error(`could not read the code at ${toBase58(address)}: ${e?.message ?? e}`);
        await new Promise((r) => setTimeout(r, 1_500 * attempt));
      }
    }
  }

  async chainId() {
    return Number(await this._rpc("eth_chainId", []));
  }

  /** ERC-1967 implementation slot, via the node's JSON-RPC. */
  async implementationOf(proxy) {
    const slot = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
    const word = await this._rpc("eth_getStorageAt", [toEvm(proxy), slot, "latest"]);
    return toEvm("0x" + word.slice(-40));
  }

  /** A view call. `signature` is a human-readable ABI fragment: "function f(address) view returns (bool)". */
  async read(to, signature, args = []) {
    const fn = new Interface([signature]).fragments[0];
    const { constant_result, result } = await this.tronWeb.transactionBuilder.triggerConstantContract(
      toTronHex(to),
      fn.format("sighash"),
      { rawParameter: abi.encode(fn.inputs, args) },
      [],
      this.sender ? toTronHex(this.sender) : toTronHex("0x0000000000000000000000000000000000000001"),
    );
    if (!result?.result || !constant_result?.length) throw new Error(`read ${fn.name} on ${to} failed: ${JSON.stringify(result)}`);
    const decoded = abi.decode(fn.outputs, "0x" + constant_result[0]);
    return fn.outputs.length === 1 ? decoded[0] : decoded;
  }

  /** A state-changing call; resolves once it is in a block and succeeded. */
  async send(to, signature, args = [], { callValue = 0, label } = {}) {
    const fn = new Interface([signature]).fragments[0];
    const name = label ?? `${fn.name} on ${toBase58(to)}`;
    if (this.dryRun) return console.log(`  [dry-run] would send ${name}`);
    const { transaction, result } = await this.tronWeb.transactionBuilder.triggerSmartContract(
      toTronHex(to),
      fn.format("sighash"),
      { feeLimit: this.feeLimit, callValue, rawParameter: abi.encode(fn.inputs, args) },
      [],
      toTronHex(this.sender),
    );
    if (!result?.result) throw new Error(`building ${name} failed: ${JSON.stringify(result)}`);
    return this._broadcast(transaction, name);
  }

  /** A plain (non-CREATE2) deployment; only the CREATE2 deployer itself is deployed this way. */
  async deployContract({ abi: contractAbi, bytecode, name }) {
    if (this.dryRun) return console.log(`  [dry-run] would deploy ${name}`);
    const tx = await this.tronWeb.transactionBuilder.createSmartContract(
      {
        abi: contractAbi,
        bytecode: bytecode.replace(/^0x/, ""),
        feeLimit: this.feeLimit,
        callValue: 0,
        userFeePercentage: 100,
        originEnergyLimit: 10_000_000,
        name,
      },
      toTronHex(this.sender),
    );
    await this._broadcast(tx, `deploy ${name}`);
    return toEvm(tx.contract_address);
  }

  async _broadcast(transaction, name) {
    const signed = await this.tronWeb.trx.sign(transaction);
    const sent = await this.tronWeb.trx.sendRawTransaction(signed);
    if (!sent.result) throw new Error(`${name} rejected: ${JSON.stringify(sent)}`);
    const txid = sent.txid ?? signed.txID;
    for (let i = 0; i < 40; i++) {
      await new Promise((r) => setTimeout(r, 3_000));
      const info = await this.tronWeb.trx.getTransactionInfo(txid);
      if (!info || !info.id) continue;
      const outcome = info.receipt?.result ?? "SUCCESS";
      if (outcome !== "SUCCESS") {
        throw new Error(`${name} failed (${outcome}) tx ${txid}: ${info.resMessage ? Buffer.from(info.resMessage, "hex") : ""}`);
      }
      console.log(`  ${name}: ${txid} (energy ${info.receipt?.energy_usage_total ?? 0})`);
      return txid;
    }
    throw new Error(`${name}: tx ${txid} not confirmed after 2 minutes`);
  }

  async _rpc(method, params) {
    const res = await fetch(`${this.fullHost.replace(/\/$/, "")}/jsonrpc`, {
      method: "POST",
      headers: { "content-type": "application/json", ...this.headers },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
    });
    const body = await res.json();
    if (body.error) throw new Error(`${method}: ${JSON.stringify(body.error)}`);
    return body.result;
  }
}
