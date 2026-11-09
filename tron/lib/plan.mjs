// The plan: every TRON address of the vault stack, and the exact init code that lands there, worked
// out before anything is sent. Mirrors the dependency order of script/Deploy.s.sol, but each address
// is derived with the TVM's CREATE2 (0x41) off the network's CREATE2 deployer instead of the EVM's
// canonical one.
//
// The guard comes first and from its own repo (guard's `tron/deploy.mjs`), which also deploys the
// CREATE2 deployer; both are read from the guard's deployments/<network>.json, never redeployed here.
// No protocol ships with the vault on TRON: nothing here builds or registers one. A protocol is the
// protocol-store's to deploy and the guard's to list, later, with no change to any address below.
//
//   guard (deployed) ─┐ its address is compiled into both vault bootstraps and Constants.sol
//   forwarder bootstrap → forwarder proxy, factory bootstrap → factory proxy, vault bootstrap
//                     └ all of them are compiled into Constants.sol, so the logic libraries →
//   facet → vault implementation, keeper, forwarder and factory builds come last.

import { AbiCoder, concat, keccak256 } from "ethers";
import { join } from "node:path";
import { create2Address, proxyInitCode, toEvm, ZERO_SALT } from "./address.mjs";
import { forgeBuild, link, librariesNeeded, readArtifact } from "./artifacts.mjs";
import { setAddressConstant, setBytes32Constant } from "./codegen.mjs";

const abi = AbiCoder.defaultAbiCoder();

/** The logic libraries the vault delegatecalls, as Deploy.s.sol deploys them. */
export const LIBRARIES = ["DeFiLogic", "MarketTradeLogic", "TokenAsGasLogic", "RiskLogic", "WhitelistLogic"].map(
  (name) => ({ name, key: `src/logic/${name}.sol:${name}`, file: `${name}.sol` }),
);

/**
 * What the guard's TRON deploy left for this one: the CREATE2 deployer and the guard proxy. Refuses a
 * guard deployment file that is missing either, so the vault is never planned against a guard that
 * does not exist yet.
 */
export function guardDeployment(file) {
  const d = file?.deployed ?? {};
  if (!d.CREATE2_DEPLOYER?.evm || !d.BITTY_GUARD?.evm) {
    throw new Error("the guard is not deployed on this network yet: run the guard repo's `tron/deploy.mjs` first");
  }
  return { deployer: toEvm(d.CREATE2_DEPLOYER.evm), guard: toEvm(d.BITTY_GUARD.evm) };
}

export function buildPlan({ repos, network, guardDeployment: g, build = true }) {
  const deployer = g.deployer;
  const at = (initCode) => create2Address(deployer, ZERO_SALT, initCode);
  const step = (name, initCode) => ({ name, address: at(initCode), initCode, initCodeHash: keccak256(initCode) });
  const vault = (p) => join(repos.vault, p);
  const guard = g.guard;

  // ── 2. what depends only on the guard and the fee collector ────────────────────────────────
  if (!network.feeCollector) throw new Error(`${network.name}: feeCollector is not set in the network config`);
  setAddressConstant(vault("src/BittyV1ForwarderBootstrap.sol"), "GUARD", guard);
  setAddressConstant(vault("src/BittyV1VaultFactoryBootstrap.sol"), "GUARD", guard);
  setAddressConstant(vault("src/logic/Constants.sol"), "BITTY_GUARD", guard);
  setAddressConstant(vault("src/logic/Constants.sol"), "BITTY_FEE_COLLECTOR", network.feeCollector);
  if (build) forgeBuild(repos.vault);

  const proxyCreation = readArtifact(repos.vault, "ERC1967Proxy.sol").bytecode;
  const forwarderBootstrap = step("BittyV1ForwarderBootstrap", readArtifact(repos.vault, "BittyV1ForwarderBootstrap.sol").bytecode);
  const forwarderProxy = step("BittyV1VaultForwarderProxy", proxyInitCode(proxyCreation, forwarderBootstrap.address));
  const factoryBootstrap = step("BittyV1VaultFactoryBootstrap", readArtifact(repos.vault, "BittyV1VaultFactoryBootstrap.sol").bytecode);
  const factoryProxy = step("BittyV1VaultFactoryProxy", proxyInitCode(proxyCreation, factoryBootstrap.address));
  const vaultBootstrap = step("BittyV1VaultBootstrap", readArtifact(repos.vault, "BittyV1VaultBootstrap.sol").bytecode);

  // ── 3. Constants.sol and the factory's proxy hash, then the build that ships ───────────────
  setAddressConstant(vault("src/logic/Constants.sol"), "BITTY_FORWARDER", forwarderProxy.address);
  setAddressConstant(vault("src/logic/Constants.sol"), "BITTY_VAULT_BOOTSTRAP", vaultBootstrap.address);
  setAddressConstant(vault("src/logic/Constants.sol"), "BITTY_VAULT_FACTORY_BOOTSTRAP", factoryBootstrap.address);
  setBytes32Constant(
    vault("src/BittyV1VaultFactory.sol"),
    "_VAULT_PROXY_INITCODE_HASH",
    keccak256(proxyInitCode(proxyCreation, vaultBootstrap.address)),
  );
  if (build) forgeBuild(repos.vault);

  // The bootstraps import nothing step 3 touched, so the second build must leave them byte-identical;
  // if it did not, every address above is already wrong.
  for (const [s, file] of [
    [forwarderBootstrap, "BittyV1ForwarderBootstrap.sol"],
    [factoryBootstrap, "BittyV1VaultFactoryBootstrap.sol"],
    [vaultBootstrap, "BittyV1VaultBootstrap.sol"],
  ]) {
    if (readArtifact(repos.vault, file).bytecode !== s.initCode) throw new Error(`${file} changed between builds`);
  }

  const libraries = LIBRARIES.map((l) => ({ ...step(l.name, readArtifact(repos.vault, l.file).bytecode), key: l.key }));
  const linked = Object.fromEntries(libraries.map((l) => [l.key, l.address]));
  const build_ = (file, contract, ctorTypes = [], ctorArgs = []) => {
    const artifact = readArtifact(repos.vault, file, contract);
    for (const key of librariesNeeded(artifact)) {
      if (!linked[key]) throw new Error(`${file} links ${key}, which the plan does not deploy`);
    }
    const code = link(artifact, linked);
    return ctorTypes.length ? concat([code, abi.encode(ctorTypes, ctorArgs)]) : code;
  };

  const defiFacet = step("BittyV1VaultDeFiFacet", build_("BittyV1VaultDeFiFacet.sol"));
  const vaultImplementation = step("BittyV1Vault", build_("BittyV1Vault.sol", "BittyV1Vault", ["address"], [defiFacet.address]));
  const forwarderImplementation = step("BittyV1VaultForwarder", build_("BittyV1VaultForwarder.sol"));
  const keeper = step("BittyV1AutoYieldKeeper", build_("BittyV1AutoYieldKeeper.sol"));
  const factoryImplementation = step("BittyV1VaultFactory", build_("BittyV1VaultFactory.sol"));

  return {
    network: network.name,
    chainId: network.chainId,
    deployer: toEvm(deployer),
    guard,
    vault: {
      libraries,
      defiFacet,
      vaultImplementation,
      vaultBootstrap,
      forwarder: { bootstrap: forwarderBootstrap, proxy: forwarderProxy, implementation: forwarderImplementation },
      keeper,
      factory: { bootstrap: factoryBootstrap, proxy: factoryProxy, implementation: factoryImplementation },
    },
  };
}

/** Every create2 step of a plan, in the order they must be deployed. */
export function createSteps(plan) {
  const v = plan.vault;
  return [
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
}
