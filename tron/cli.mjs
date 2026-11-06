#!/usr/bin/env node
// Bitty on TRON. forge builds and tests; this sends. See README.md for the order.
//
//   node cli.mjs probe    --network nile            check the TVM facts this deploy rests on (no key)
//   node cli.mjs deployer --network nile            deploy the CREATE2 deployer (once per network)
//   node cli.mjs plan     --network nile            write TRON constants into the sources, build, plan
//   node cli.mjs deploy   --network nile [--dry-run] send the plan
//
// Env: TRON_PRIVATE_KEY (the DEPLOYER key, hex), TRON_PRO_API_KEY (optional, TronGrid).

import { existsSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { toBase58, toEvm } from "./lib/address.mjs";
import { forgeBuild, readArtifact } from "./lib/artifacts.mjs";
import { Chain } from "./lib/chain.mjs";
import { deploy, summary } from "./lib/deploy.mjs";
import { buildPlan, createSteps } from "./lib/plan.mjs";
import { probe, simulateDeployment } from "./lib/probe.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const { positionals, values } = parseArgs({
  allowPositionals: true,
  options: {
    network: { type: "string", default: "nile" },
    "dry-run": { type: "boolean", default: false },
    guard: { type: "string", default: resolve(here, "../../guard") },
    "protocol-store": { type: "string", default: resolve(here, "../../protocol-store") },
  },
});
const command = positionals[0];
const network = JSON.parse(readFileSync(join(here, "networks", `${values.network}.json`), "utf8"));
const repos = { vault: resolve(here, ".."), guard: values.guard, protocolStore: values["protocol-store"] };
const statePath = join(here, "deployments", `${network.name}.json`);
const planPath = join(here, "deployments", `${network.name}.plan.json`);
const state = existsSync(statePath) ? JSON.parse(readFileSync(statePath, "utf8")) : {};

function save(path, data) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, JSON.stringify(data, null, 2) + "\n");
}

function chain() {
  return new Chain({
    fullHost: network.fullHost,
    privateKey: process.env.TRON_PRIVATE_KEY,
    apiKey: process.env.TRON_PRO_API_KEY,
    feeLimitTrx: network.feeLimitTrx,
    dryRun: values["dry-run"],
  });
}

switch (command) {
  case "probe": {
    const results = await probe({ fullHost: network.fullHost, chainId: network.chainId, apiKey: process.env.TRON_PRO_API_KEY });
    for (const r of results) console.log(`${r.pass ? "PASS" : "FAIL"}  ${r.name}${r.detail ? `  (${r.detail})` : ""}`);
    // With a plan, also run every piece's real init code as a deployment simulation.
    if (existsSync(planPath)) {
      const plan = JSON.parse(readFileSync(planPath, "utf8"));
      for (const s of createSteps(plan)) {
        await new Promise((r) => setTimeout(r, 1_200));
        const r = await simulateDeployment({ fullHost: network.fullHost, apiKey: process.env.TRON_PRO_API_KEY }, s.initCode);
        console.log(`${r.ok ? "PASS" : "FAIL"}  simulate ${s.name.padEnd(28)} energy ${r.energy ?? "-"}${r.message ? `  (${r.message.slice(0, 80)})` : ""}`);
        results.push({ pass: r.ok });
      }
    }
    if (results.some((r) => !r.pass)) process.exit(1);
    break;
  }
  case "deployer": {
    if (state.create2Deployer) {
      console.log(`CREATE2 deployer already recorded at ${toBase58(state.create2Deployer)}`);
      break;
    }
    forgeBuild(repos.vault);
    const artifact = readArtifact(repos.vault, "BittyTronCreate2Deployer.sol");
    const address = await chain().deployContract({ abi: artifact.abi, bytecode: artifact.bytecode, name: "BittyTronCreate2Deployer" });
    if (address) {
      save(statePath, { ...state, create2Deployer: toEvm(address) });
      console.log(`CREATE2 deployer at ${toBase58(address)} (${toEvm(address)})`);
    }
    break;
  }
  case "plan": {
    const plan = buildPlan({ repos, network, deployer: state.create2Deployer });
    save(planPath, plan);
    console.table(Object.fromEntries(Object.entries(summary(plan, state.create2Deployer)).filter(([, v]) => v.base58).map(([k, v]) => [k, v.base58])));
    console.log(`plan written to ${planPath}`);
    console.log("the TRON constants are now in the vault sources: review and commit them before deploying");
    break;
  }
  case "deploy": {
    if (!existsSync(planPath)) throw new Error(`no plan at ${planPath}: run plan first`);
    const plan = JSON.parse(readFileSync(planPath, "utf8"));
    const addresses = await deploy({ chain: chain(), plan, network, deployerAddress: state.create2Deployer });
    if (!values["dry-run"]) save(statePath, { ...state, ...addresses });
    console.table(Object.fromEntries(Object.entries(addresses).filter(([, v]) => v.base58).map(([k, v]) => [k, v.base58])));
    break;
  }
  default:
    console.error("usage: node cli.mjs <deployer|plan|deploy> --network <nile|mainnet> [--dry-run]");
    process.exit(1);
}
