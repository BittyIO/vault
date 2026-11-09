// The vault stack's deploy against an in-memory chain: what is sent, in what order, that a re-run
// sends nothing, and that it refuses to start without the guard repo's deploy. No node, no key; the
// contracts' own behaviour is forge's to test.

import { test } from "node:test";
import assert from "node:assert/strict";
import { id as keccakText } from "ethers";
import { toEvm } from "../lib/address.mjs";
import { deploy } from "../lib/deploy.mjs";
import { guardDeployment } from "../lib/plan.mjs";

const ZERO = "0x0000000000000000000000000000000000000000";
const addr = (n) => toEvm("0x" + n.toString(16).padStart(40, "0"));
let codes = 0;
const step = (name, n) => ({ name, address: addr(n), initCode: "0x" + (++codes).toString(16).padStart(4, "0"), initCodeHash: "0x00" });

const DEPLOYER_KEY = addr(0x12ee);
const CREATE2 = addr(0xc2);
const GUARD = addr(0x6a);
const KEY_OWNER = keccakText("bitty.owner");
const KEY_GAS_WRAPPED = keccakText("bitty.gasWrapped");

const network = { name: "nile", chainId: 3448148188, deployer: DEPLOYER_KEY, relayer: addr(0x77) };

const plan = {
  network: "nile",
  chainId: network.chainId,
  deployer: CREATE2,
  guard: GUARD,
  vault: {
    libraries: [step("DeFiLogic", 0x301), step("RiskLogic", 0x30c)],
    defiFacet: step("BittyV1VaultDeFiFacet", 0x302),
    vaultImplementation: step("BittyV1Vault", 0x303),
    vaultBootstrap: step("BittyV1VaultBootstrap", 0x304),
    forwarder: { bootstrap: step("FwdBootstrap", 0x305), proxy: step("FwdProxy", 0x306), implementation: step("Fwd", 0x307) },
    keeper: step("Keeper", 0x308),
    factory: { bootstrap: step("FacBootstrap", 0x309), proxy: step("FacProxy", 0x30a), implementation: step("Fac", 0x30b) },
  },
};
const v = plan.vault;
const allSteps = [
  v.forwarder.bootstrap,
  v.forwarder.proxy,
  v.forwarder.implementation,
  v.keeper,
  ...v.libraries,
  v.defiFacet,
  v.vaultImplementation,
  v.vaultBootstrap,
  v.factory.bootstrap,
  v.factory.proxy,
  v.factory.implementation,
];

/** The guard as the guard repo leaves it, plus just enough of the vault stack to answer deploy's reads. */
class FakeChain {
  constructor({ guardReady = true } = {}) {
    this.dryRun = false;
    this.sender = DEPLOYER_KEY;
    this.code = new Set([CREATE2, GUARD]);
    this.impl = {};
    this.admin = guardReady ? DEPLOYER_KEY : ZERO;
    this.config = guardReady ? { [KEY_OWNER]: DEPLOYER_KEY, [KEY_GAS_WRAPPED]: addr(0xa1) } : {};
    this.protocols = new Map();
    this.relayers = new Set();
    this.forwarders = new Set();
    this.latest = ZERO;
    this.sent = [];
  }
  async chainId() {
    return network.chainId;
  }
  async hasCode(a) {
    return this.code.has(a);
  }
  async implementationOf(p) {
    return this.impl[p] ?? ZERO;
  }
  async read(to, sig, args = []) {
    const name = sig.match(/function (\w+)/)[1];
    if (name === "defaultAdmin") return this.admin;
    if (name === "getAddress") return this.config[args[0]] ?? ZERO;
    if (name === "isProtocolRegistered") return this.protocols.has(args[0]);
    if (name === "approvedRelayers") return this.relayers.has(args[0]);
    if (name === "trustedForwarders") return this.forwarders.has(args[0]);
    if (name === "latestImplementation") return this.latest;
    throw new Error(`unexpected read ${name}`);
  }
  async send(to, sig, args = [], { label } = {}) {
    const name = sig.match(/function (\w+)/)[1];
    this.sent.push(label ?? name);
    if (this.dryRun) return;
    if (name === "deploy") return this.code.add(allSteps.find((s) => s.initCode === args[1]).address);
    if (name === "upgradeToAndCall") return (this.impl[to] = args[0]);
    if (name === "addProtocols") return args[0].forEach((p, i) => this.protocols.set(p, args[1][i]));
    if (name === "setRelayerApproval") return this.relayers.add(args[0]);
    if (name === "setForwarder") return this.forwarders.add(args[0]);
    if (name === "setImplementation") return (this.latest = args[0]);
    throw new Error(`unexpected send ${name}`);
  }
}

const quiet = async (fn) => {
  const log = console.log;
  console.log = () => {};
  try {
    return await fn();
  } finally {
    console.log = log;
  }
};
const run = (chain) => quiet(() => deploy({ chain, plan, network, deployerAddress: CREATE2 }));

test("a deploy from nothing: every piece, then the build registered, relayer, keeper, upgrades", async () => {
  const chain = new FakeChain();
  await run(chain);
  assert.deepEqual(chain.sent, [
    ...allSteps.map((s) => `deploy ${s.name}`),
    "forwarder.upgradeToAndCall",
    "setRelayerApproval",
    "keeper.setForwarder",
    "guard.setImplementation",
    "factory.upgradeToAndCall",
  ]);
  assert.equal(chain.latest, v.vaultImplementation.address);
});

test("a re-run sends nothing", async () => {
  const chain = new FakeChain();
  await run(chain);
  chain.sent = [];
  await run(chain);
  assert.deepEqual(chain.sent, []);
});

test("no protocol ships with the vault on TRON: the guard's protocol list is never touched", async () => {
  const chain = new FakeChain();
  await run(chain);
  assert.ok(!chain.sent.some((s) => /Protocol/i.test(s)));
  assert.equal(chain.protocols.size, 0);
});

test("a guard the guard repo has not initialized is refused before anything is sent", async () => {
  const chain = new FakeChain({ guardReady: false });
  await assert.rejects(() => run(chain), /is it initialized/);
  assert.deepEqual(chain.sent, []);
});

test("a guard without its owner or gas token set is refused", async () => {
  const chain = new FakeChain();
  delete chain.config[KEY_GAS_WRAPPED];
  await assert.rejects(() => run(chain), /CFG_GAS_WRAPPED is not set/);
  assert.deepEqual(chain.sent, []);
});

test("no guard at all is refused", async () => {
  const chain = new FakeChain();
  chain.code.delete(GUARD);
  await assert.rejects(() => run(chain), /no guard at/);
});

test("a dry run from nothing lists the pieces and stops before reading contracts that are not there", async () => {
  const chain = new FakeChain();
  chain.dryRun = true;
  await run(chain);
  assert.deepEqual(chain.sent, allSteps.map((s) => `deploy ${s.name}`));
});

test("the vault is never planned against a guard the guard repo has not recorded", () => {
  assert.throws(() => guardDeployment(null), /guard is not deployed/);
  assert.throws(() => guardDeployment({ deployed: { CREATE2_DEPLOYER: { evm: CREATE2 } } }), /guard is not deployed/);
  assert.deepEqual(guardDeployment({ deployed: { CREATE2_DEPLOYER: { evm: CREATE2 }, BITTY_GUARD: { evm: GUARD } } }), {
    deployer: CREATE2,
    guard: GUARD,
  });
});
