#!/usr/bin/env node
// Bitty on TRON. forge builds and tests; this sends. See README.md for the order.
//
//   node cli.mjs probe    --network nile            check the TVM facts this deploy rests on (no key)
//   node cli.mjs plan     --network nile            write TRON constants into the sources, build, plan
//   node cli.mjs deploy   --network nile [--dry-run] send the plan
//
// The guard and the CREATE2 deployer come first, from the guard repo (`tron/deploy.mjs` there); this
// reads them from the guard's deployments/<network>.json and deploys everything after them.
//
// Env: TRON_PRIVATE_KEY (the DEPLOYER key, hex), TRON_PRO_API_KEY (optional, TronGrid).

import { existsSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { toBase58, toEvm } from "./lib/address.mjs";
import { Chain } from "./lib/chain.mjs";
import { deploy, summary } from "./lib/deploy.mjs";
import { buildPlan, createSteps, guardDeployment } from "./lib/plan.mjs";
import { probe, simulateDeployment } from "./lib/probe.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const { positionals, values } = parseArgs({
  allowPositionals: true,
  options: {
    network: { type: "string", default: "nile" },
    "dry-run": { type: "boolean", default: false },
    guard: { type: "string", default: resolve(here, "../../guard") },
  },
});
const command = positionals[0];
const network = JSON.parse(readFileSync(join(here, "networks", `${values.network}.json`), "utf8"));
const repos = { vault: resolve(here, ".."), guard: values.guard };
const statePath = join(here, "deployments", `${network.name}.json`);
const planPath = join(here, "deployments", `${network.name}.plan.json`);
const state = existsSync(statePath) ? JSON.parse(readFileSync(statePath, "utf8")) : {};
const guardFile = join(repos.guard, "deployments", `${network.guardDeployment}.json`);
const guardDeployed = () => guardDeployment(existsSync(guardFile) ? JSON.parse(readFileSync(guardFile, "utf8")) : null);

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

/**
 * The DEPLOYER must be a funded TRON account: an address is not an account until it has received
 * TRX, and the node refuses every transaction from one that is not. Checked before anything is sent,
 * so an unfunded run stops with the address to fund rather than failing on its first transaction.
 */
const STACK_DEPLOY_ENERGY = 25_000_000; // the vault stack after the guard: ~24M simulated (README)
const BANDWIDTH_TRX = 100;
async function requireFunded(c, fresh) {
  const deployerBase58 = toBase58(network.deployer);
  const account = await c.tronWeb.trx.getAccount(deployerBase58);
  const balanceTrx = (account?.balance ?? 0) / 1_000_000;
  const params = await c.tronWeb.trx.getChainParameters();
  const energyFeeSun = params.find((p) => p.key === "getEnergyFee")?.value ?? 100;
  const neededTrx = Math.ceil((STACK_DEPLOY_ENERGY * energyFeeSun) / 1_000_000 + BANDWIDTH_TRX);
  const exists = Boolean(account?.address);
  console.log(`DEPLOYER ${deployerBase58} (${toEvm(network.deployer)}): ${exists ? `${balanceTrx} TRX` : "no account yet"}`);
  if (exists && balanceTrx >= neededTrx) return;
  // Finishing an earlier run costs only what is left, which is unknown here: warn, and let it try.
  if (exists && !fresh) return console.log(`WARNING: ${balanceTrx} TRX is below the ~${neededTrx} TRX of a deploy from nothing`);
  const message = [
    "",
    `Fund the DEPLOYER on TRON ${network.name} before deploying:`,
    "",
    `    ${deployerBase58}`,
    "",
    `  balance now: ${exists ? `${balanceTrx} TRX` : "none (the account does not exist until it receives TRX)"}`,
    `  needed:      about ${neededTrx} TRX for a deploy from nothing (${STACK_DEPLOY_ENERGY / 1e6}M energy at ${energyFeeSun} sun,`,
    "               plus bandwidth); less if the account has staked energy or the run is finishing an earlier one",
    ...(network.name === "nile" ? ["  Nile test TRX: https://nileex.io/join/getJoinPage"] : []),
    "",
  ].join("\n");
  if (!values["dry-run"]) {
    console.error(message);
    process.exit(1);
  }
  console.log(message + "  [dry-run] continuing anyway, to show what would be sent\n");
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
  case "plan": {
    const g = guardDeployed();
    const plan = buildPlan({ repos, network, guardDeployment: g });
    save(planPath, plan);
    console.table(Object.fromEntries(Object.entries(summary(plan, g.deployer)).filter(([, v]) => v.base58).map(([k, v]) => [k, v.base58])));
    console.log(`plan written to ${planPath}`);
    console.log("the TRON constants are now in the vault sources: review and commit them before deploying");
    break;
  }
  case "deploy": {
    if (!existsSync(planPath)) throw new Error(`no plan at ${planPath}: run plan first`);
    const plan = JSON.parse(readFileSync(planPath, "utf8"));
    const g = guardDeployed();
    if (plan.guard !== g.guard || plan.deployer !== g.deployer) {
      throw new Error("the plan was made against a different guard or CREATE2 deployer than the guard repo records: run plan again");
    }
    const c = chain();
    await requireFunded(c, !(await c.hasCode(createSteps(plan)[0].address)));
    const addresses = await deploy({ chain: c, plan, network, deployerAddress: g.deployer });
    if (!values["dry-run"]) save(statePath, { ...state, ...addresses });
    console.table(Object.fromEntries(Object.entries(addresses).filter(([, v]) => v.base58).map(([k, v]) => [k, v.base58])));
    break;
  }
  default:
    console.error("usage: node cli.mjs <probe|plan|deploy> --network <nile|mainnet> [--dry-run]");
    process.exit(1);
}
