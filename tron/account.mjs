#!/usr/bin/env node
// The Bitty account on TRON (src/account): one factory, its TronStakeOps, and reads.
//
//   node account.mjs config  --network nile                     what the factory would be built with (no key)
//   node account.mjs deploy  --network nile [--dry-run]         build, deploy TronStakeOps + BittyAccountFactory
//   node account.mjs show    --network nile                     read back the deployed factory and implementation
//   node account.mjs predict --network nile <owner> [index]     an owner's account address (created or not)
//   node account.mjs set-relayer    --network nile <addr>       the factory owner changes the relayer
//   node account.mjs transfer-owner --network nile <addr>       hand the factory over (the new owner accepts)
//   node account.mjs accept-owner   --network nile              run by the new owner's key
//
//   --relayer <addr>   the first relayer: relayed batches pay it their USDT fee, and it collects the 0.2%
//                      swap fee in TRX (default: networks/<n>.json relayer). Changeable later (set-relayer).
//   --rpc <node url>   another node than the network's fullHost; never written to a file
//
// The deploying key becomes the factory's owner, the one key that can change the relayer. Everything else
// in the config is fixed into the implementation, and the implementation's address is part of every
// account address: another router, feed or USDT is a NEW factory and a new set of account addresses.
//
// Env: TRON_PRIVATE_KEY (hex; for deploy and the owner commands), TRON_PRO_API_KEY (optional, TronGrid).

import { existsSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { AbiCoder } from "ethers";
import { toBase58, toEvm } from "./lib/address.mjs";
import { Chain } from "./lib/chain.mjs";
import { forgeBuild, readArtifact } from "./lib/artifacts.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, "..");

// SunSwap's Universal Router and its Permit2 (the same addresses protocol-store's tron/sunswap.mjs uses).
const SUNSWAP = {
  nile: { router: "TLmHD2TJoGVEMkGiE1JzSwd6CEPa8jXumJ", permit2: "TYQuuhGbEMxF7nZxUHV3uHJxAVVAegNU9h" },
  mainnet: { router: "TQqgNg13s2DjvXhW1ky4v6TsR8wZGvb7Y4", permit2: "TTJxU3P8rHycAyFY4kVtGNfmnMH4ezcuM9" },
};
const CONFIG_TUPLE =
  "tuple(address usdt,address stakeOps,address router,address permit2,address trxUsdFeed,uint32 feedMaxAge,uint8 feedDecimals,bool usdtFalseIsSuccess)";

const { positionals, values } = parseArgs({
  allowPositionals: true,
  options: {
    network: { type: "string", default: "nile" },
    "dry-run": { type: "boolean", default: false },
    rpc: { type: "string" },
    relayer: { type: "string" },
  },
});
const command = positionals[0];
const network = JSON.parse(readFileSync(join(here, "networks", `${values.network}.json`), "utf8"));
const statePath = join(here, "deployments", `${network.name}.account.json`);
const state = existsSync(statePath) ? JSON.parse(readFileSync(statePath, "utf8")) : {};

function save() {
  mkdirSync(dirname(statePath), { recursive: true });
  writeFileSync(statePath, JSON.stringify(state, null, 2) + "\n");
}

const c = new Chain({
  fullHost: values.rpc || network.fullHost,
  privateKey: ["deploy", "set-relayer", "transfer-owner", "accept-owner"].includes(command) ? process.env.TRON_PRIVATE_KEY : undefined,
  apiKey: process.env.TRON_PRO_API_KEY,
  feeLimitTrx: network.feeLimitTrx,
  dryRun: values["dry-run"],
});

/** The factory's config, minus stakeOps (known only once it is deployed). */
async function config() {
  const sun = SUNSWAP[network.name];
  if (!sun) throw new Error(`no SunSwap addresses for ${network.name}`);
  const feed = network.guard?.priceFeeds?.find((f) => f.token === "native");
  if (!feed) throw new Error(`networks/${network.name}.json has no native (TRX/USD) price feed`);
  const decimals = Number(await c.read(toEvm(feed.feed), "function decimals() view returns (uint8)"));
  return {
    usdt: toEvm(network.tokens.USDT),
    stakeOps: state.TronStakeOps ? toEvm(state.TronStakeOps) : null,
    router: toEvm(sun.router),
    permit2: toEvm(sun.permit2),
    trxUsdFeed: toEvm(feed.feed),
    feedMaxAge: feed.maxAge,
    feedDecimals: decimals,
    // TRON USDT (mainnet and Nile alike) returns false from a transfer that worked and reverts on
    // every failure: only "did it revert" carries information.
    usdtFalseIsSuccess: true,
  };
}

function printConfig(cfg) {
  console.table(
    Object.fromEntries(Object.entries(cfg).map(([k, v]) => [k, typeof v === "string" && v.startsWith("0x") ? `${toBase58(v)}  ${v}` : String(v)])),
  );
}

function firstRelayer() {
  const r = values.relayer ?? network.relayer;
  if (!r) throw new Error("no relayer: pass --relayer");
  return r;
}

const FACTORY_OWNER_SENDS = {
  "set-relayer": "function setRelayer(address)",
  "transfer-owner": "function transferOwnership(address)",
  "accept-owner": "function acceptOwnership()",
};

async function requireAccount(address, label) {
  const a = await c.tronWeb.trx.getAccount(toBase58(address));
  if (!a?.address) throw new Error(`${label} ${toBase58(address)} is not an activated TRON account: send it some TRX first`);
}

switch (command) {
  case "config": {
    printConfig({ ...(await config()), relayer: toEvm(firstRelayer()) });
    break;
  }
  case "deploy": {
    if (!process.env.TRON_PRIVATE_KEY) throw new Error("TRON_PRIVATE_KEY is not set");
    console.log(`network ${network.name}, deploying from ${toBase58(c.sender)}`);
    const cfg = await config();
    const relayer = toEvm(firstRelayer());
    // The swap fee is a plain TRX transfer to the relayer: were it not an account yet, TRON would charge
    // the account-creation fee on top.
    await requireAccount(relayer, "relayer");
    forgeBuild(repo);

    if (state.TronStakeOps && (await c.hasCode(state.TronStakeOps))) {
      console.log(`TronStakeOps         already at ${toBase58(state.TronStakeOps)}`);
    } else {
      const ops = readArtifact(repo, "TronStakeOps.yul", "TronStakeOps");
      // Yul has no ABI of its own; this one is only the explorer's view of it (as in protocol-store's stake.mjs).
      const abi = [
        "freezeBalanceV2(uint256,uint256)",
        "unfreezeBalanceV2(uint256,uint256)",
        "withdrawExpireUnfreeze()",
        "delegateResource(address,uint256,uint256)",
        "unDelegateResource(address,uint256,uint256)",
      ].map((sig) => {
        const [name, list] = sig.split(/[()]/);
        return {
          type: "function",
          name,
          stateMutability: "nonpayable",
          inputs: list ? list.split(",").map((t, i) => ({ name: `a${i}`, type: t })) : [],
          outputs: [{ name: "", type: "uint256" }],
        };
      });
      const addr = await c.deployContract({ abi, bytecode: ops.bytecode, name: "TronStakeOps" });
      if (!values["dry-run"]) {
        state.TronStakeOps = addr;
        save();
        console.log(`TronStakeOps         deployed at ${toBase58(addr)}`);
      }
    }
    cfg.stakeOps = state.TronStakeOps ? toEvm(state.TronStakeOps) : "0x0000000000000000000000000000000000000001";

    printConfig({ ...cfg, relayer, owner: c.sender });
    const factory = readArtifact(repo, "BittyAccountFactory.sol");
    const args = AbiCoder.defaultAbiCoder().encode([CONFIG_TUPLE, "address"], [cfg, relayer]).slice(2);
    // The constructor arguments ride on the end of the bytecode, encoded here with ethers. TronWeb would
    // insist on encoding them itself from the ABI's constructor entry, so that entry is left out: the
    // ABI stored with the contract is only the explorer's view of it.
    const abi = factory.abi.filter((e) => e.type !== "constructor");
    const addr = await c.deployContract({ abi, bytecode: factory.bytecode + args, name: "BittyAccountFactory" });
    if (values["dry-run"]) break;
    state.BittyAccountFactory = addr;
    state.config = cfg;
    save();
    console.log(`BittyAccountFactory  deployed at ${toBase58(addr)}`);
    console.log(`state written to ${statePath}; check it with: node account.mjs show --network ${network.name}`);
    break;
  }
  case "show": {
    if (!state.BittyAccountFactory) throw new Error(`no factory recorded in ${statePath}`);
    const f = toEvm(state.BittyAccountFactory);
    const impl = await c.read(f, "function implementation() view returns (address)");
    const prefix = await c.read(f, "function create2Prefix() view returns (bytes1)");
    const read = (sig) => c.read(impl, `function ${sig}() view returns (address)`);
    const fread = (sig) => c.read(f, `function ${sig}() view returns (address)`);
    const onChain = {
      factory: f,
      owner: await fread("owner"),
      pendingOwner: await fread("pendingOwner"),
      relayer: await fread("relayer"),
      implementation: impl,
      create2Prefix: prefix,
      usdt: await read("usdt"),
      stakeOps: await read("stakeOps"),
      router: await read("router"),
      permit2: await read("permit2"),
      trxUsdFeed: await read("trxUsdFeed"),
      usdtFalseIsSuccess: String(await c.read(impl, "function usdtFalseIsSuccess() view returns (bool)")),
    };
    printConfig(onChain);
    if (prefix !== "0x41") console.log("WARNING: the factory did not detect TRON's 0x41 CREATE2 prefix");
    for (const k of ["usdt", "stakeOps", "router", "permit2", "trxUsdFeed"]) {
      if (state.config?.[k] && toEvm(state.config[k]) !== toEvm(onChain[k])) console.log(`MISMATCH ${k}: recorded ${state.config[k]}`);
    }
    break;
  }
  case "predict": {
    if (!state.BittyAccountFactory) throw new Error(`no factory recorded in ${statePath}`);
    const [owner, index = "0"] = positionals.slice(1);
    if (!owner) throw new Error("usage: predict <owner> [index]");
    const a = await c.read(toEvm(state.BittyAccountFactory), "function predictAccount(address,uint256) view returns (address)", [
      toEvm(owner),
      BigInt(index),
    ]);
    console.log(`${toBase58(a)}  ${a}  (${(await c.hasCode(a)) ? "created" : "not created yet"})`);
    break;
  }
  case "set-relayer":
  case "transfer-owner":
  case "accept-owner": {
    if (!process.env.TRON_PRIVATE_KEY) throw new Error("TRON_PRIVATE_KEY is not set");
    if (!state.BittyAccountFactory) throw new Error(`no factory recorded in ${statePath}`);
    const f = toEvm(state.BittyAccountFactory);
    const args = command === "accept-owner" ? [] : [toEvm(positionals[1] ?? "")];
    if (command === "set-relayer") await requireAccount(args[0], "relayer");
    await c.send(f, FACTORY_OWNER_SENDS[command], args);
    console.log(`owner ${toBase58(await c.read(f, "function owner() view returns (address)"))}, relayer ${toBase58(await c.read(f, "function relayer() view returns (address)"))}`);
    break;
  }
  default:
    console.error("usage: node account.mjs <config|deploy|show|predict|set-relayer|transfer-owner|accept-owner> --network nile|mainnet");
    process.exit(1);
}
