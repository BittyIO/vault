// Sends a plan to TRON, in dependency order. Every step checks the chain first and is skipped when
// already done, so an interrupted run is finished by running it again — the same contract as
// script/Deploy.s.sol, DeployGuard and protocol-store's DeployProtocols on the EVM.

import { id as keccakText } from "ethers";
import { toBase58, toEvm, ZERO_SALT } from "./address.mjs";
import { createSteps } from "./plan.mjs";

const ZERO = "0x0000000000000000000000000000000000000000";
const PROTOCOL_MARKET_TRADE = 3;
const IMPLEMENTATION_VAULT = 1;
// The guard's config keys, as IBittyV1Guard defines them.
const KEY_OWNER = keccakText("bitty.owner");
const KEY_GAS_WRAPPED = keccakText("bitty.gasWrapped");

const UPGRADE = "function upgradeToAndCall(address,bytes) payable";

export async function deploy({ chain, plan, network, deployerAddress }) {
  await preflight({ chain, plan, network, deployerAddress });

  // 1. every CREATE2 piece, idempotently
  for (const s of createSteps(plan)) {
    if (await chain.hasCode(s.address)) {
      console.log(`${s.name.padEnd(30)} already at ${toBase58(s.address)}`);
      continue;
    }
    await chain.send(deployerAddress, "function deploy(bytes32,bytes) payable returns (address)", [ZERO_SALT, s.initCode], {
      label: `deploy ${s.name}`,
    });
    if (!chain.dryRun && !(await chain.hasCode(s.address))) {
      throw new Error(`${s.name}: deployed, but nothing at the planned ${toBase58(s.address)} — the TVM CREATE2 math disagrees`);
    }
    console.log(`${s.name.padEnd(30)} deployed at ${toBase58(s.address)}`);
  }

  const guard = plan.guard.proxy.address;
  const v = plan.vault;
  const adapter = plan.protocols.sunswapAdapter.address;

  // 2. guard: off its bootstrap, initialized with the TRON registry, configured
  await upgradeIfStale(chain, "guard", guard, plan.guard.implementation.address);
  if ((await chain.read(guard, "function defaultAdmin() view returns (address)")) === ZERO) {
    const assets = network.guard.assets;
    await chain.send(
      guard,
      "function initialize(address[],uint8[],address[],uint8[])",
      [assets.map((a) => toEvm(network.tokens[a.token])), assets.map((a) => a.category), [adapter], [PROTOCOL_MARKET_TRADE]],
      { label: "guard.initialize" },
    );
  }
  await setConfigIfUnset(chain, guard, KEY_OWNER, "CFG_OWNER", toEvm(network.deployer));
  await setConfigIfUnset(chain, guard, KEY_GAS_WRAPPED, "CFG_GAS_WRAPPED", toEvm(network.tokens.WTRX));
  for (const f of network.guard.priceFeeds ?? []) {
    const asset = f.token === "native" ? ZERO : toEvm(network.tokens[f.token]);
    const live = await chain.read(
      guard,
      "function priceFeed(address) view returns ((address feed,uint32 maxAge,uint8 decimals,uint8 assetDecimals,bool hasQuote,address quote))",
      [asset],
    );
    const quote = f.quote ? toEvm(network.tokens[f.quote]) : ZERO;
    if (live.feed === toEvm(f.feed) && Number(live.maxAge) === f.maxAge && live.quote === quote) continue;
    await chain.send(guard, "function setPriceFeeds(address[],address[],uint32[],address[])", [[asset], [toEvm(f.feed)], [f.maxAge], [quote]], {
      label: `guard.setPriceFeeds(${f.token})`,
    });
  }

  // 3. forwarder: off its bootstrap, relayer approved
  const forwarder = v.forwarder.proxy.address;
  await upgradeIfStale(chain, "forwarder", forwarder, v.forwarder.implementation.address);
  if (network.relayer) {
    const approved = await chain.read(forwarder, "function approvedRelayers(address) view returns (bool)", [toEvm(network.relayer)]);
    if (!approved) await chain.send(forwarder, "function setRelayerApproval(address,bool)", [toEvm(network.relayer), true]);
  } else {
    console.log("WARNING: no relayer in the network config - the forwarder has no relayer");
  }

  // 4. keeper trusts the forwarder
  if (!(await chain.read(v.keeper.address, "function trustedForwarders(address) view returns (bool)", [forwarder]))) {
    await chain.send(v.keeper.address, "function setForwarder(address,bool)", [forwarder, true], { label: "keeper.setForwarder" });
  }

  // 5. the guard names the vault build
  const latest = await chain.read(guard, "function latestImplementation(uint8) view returns (address)", [IMPLEMENTATION_VAULT]);
  if (latest !== v.vaultImplementation.address) {
    await chain.send(guard, "function setImplementation(address,uint8)", [v.vaultImplementation.address, IMPLEMENTATION_VAULT], {
      label: "guard.setImplementation",
    });
  }

  // 6. factory: off its bootstrap
  await upgradeIfStale(chain, "factory", v.factory.proxy.address, v.factory.implementation.address);

  return summary(plan, deployerAddress);
}

async function preflight({ chain, plan, network, deployerAddress }) {
  const chainId = await chain.chainId();
  if (chainId !== network.chainId) throw new Error(`connected to chain ${chainId}, config says ${network.chainId}`);
  if (plan.chainId !== network.chainId) throw new Error(`plan was made for chain ${plan.chainId}`);
  if (toEvm(plan.deployer) !== toEvm(deployerAddress)) throw new Error("plan was made for a different CREATE2 deployer");
  if (!(await chain.hasCode(deployerAddress))) throw new Error(`no CREATE2 deployer at ${toBase58(deployerAddress)}`);
  // The bootstraps and guard.initialize gate on tx.origin, so nothing but the DEPLOYER key can finish this.
  if (!chain.dryRun && chain.sender !== toEvm(network.deployer)) {
    throw new Error(`broadcasting key is ${chain.sender}; it must be the DEPLOYER ${network.deployer}`);
  }
}

async function upgradeIfStale(chain, name, proxy, implementation) {
  const current = await chain.implementationOf(proxy).catch(() => null);
  if (current === implementation) return console.log(`${name} already on ${toBase58(implementation)}`);
  await chain.send(proxy, UPGRADE, [implementation, "0x"], { label: `${name}.upgradeToAndCall` });
}

async function setConfigIfUnset(chain, guard, key, name, value) {
  const live = await chain.read(guard, "function getAddress(bytes32) view returns (address)", [key]);
  if (live !== ZERO) return console.log(`${name} already set, kept: ${live}`);
  await chain.send(guard, "function setAddress(bytes32,address)", [key, value], { label: `guard ${name}` });
}

export function summary(plan, deployerAddress) {
  const both = (a) => ({ evm: toEvm(a), base58: toBase58(a) });
  const v = plan.vault;
  return {
    network: plan.network,
    chainId: plan.chainId,
    CREATE2_DEPLOYER: both(deployerAddress),
    BITTY_GUARD: both(plan.guard.proxy.address),
    GUARD_IMPLEMENTATION: both(plan.guard.implementation.address),
    SUNSWAP_TRADE_PROTOCOL: both(plan.protocols.sunswapAdapter.address),
    BITTY_FORWARDER: both(v.forwarder.proxy.address),
    FORWARDER_IMPLEMENTATION: both(v.forwarder.implementation.address),
    BITTY_AUTO_YIELD_KEEPER: both(v.keeper.address),
    ...Object.fromEntries(v.libraries.map((l) => [l.name, both(l.address)])),
    DEFI_FACET: both(v.defiFacet.address),
    VAULT_IMPLEMENTATION: both(v.vaultImplementation.address),
    BITTY_VAULT_BOOTSTRAP: both(v.vaultBootstrap.address),
    BITTY_VAULT_FACTORY: both(v.factory.proxy.address),
    FACTORY_IMPLEMENTATION: both(v.factory.implementation.address),
  };
}
