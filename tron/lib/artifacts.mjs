// Reading what forge built, linking libraries, and running forge itself.

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { toEvm } from "./address.mjs";

/** The forge profile every TRON build uses, in all three repos. */
export const TRON_PROFILE = "tron";
export const TRON_OUT = "out-tron";

export function forgeBuild(repoDir) {
  execFileSync("forge", ["build"], {
    cwd: repoDir,
    stdio: ["ignore", "inherit", "inherit"],
    env: { ...process.env, FOUNDRY_PROFILE: TRON_PROFILE },
  });
}

/** `file` is the source's basename (BittyV1Vault.sol), as forge lays out its `out` directory. */
export function readArtifact(repoDir, file, contract = file.replace(/\.sol$/, "")) {
  const path = join(repoDir, TRON_OUT, file, `${contract}.json`);
  const json = JSON.parse(readFileSync(path, "utf8"));
  return {
    abi: json.abi,
    bytecode: json.bytecode.object,
    linkReferences: json.bytecode.linkReferences ?? {},
  };
}

/** The library references `bytecode` still has to have filled, as "path:Name" keys. */
export function librariesNeeded(artifact) {
  const out = [];
  for (const [path, libs] of Object.entries(artifact.linkReferences)) {
    for (const name of Object.keys(libs)) out.push(`${path}:${name}`);
  }
  return out;
}

/**
 * Fill every library placeholder with its address. Linking is a substitution in the finished
 * bytecode, not a compiler setting, so unlike a `libraries` pin in foundry.toml it changes no
 * contract's metadata — which is what keeps the library addresses from depending on themselves.
 */
export function link(artifact, addresses) {
  let code = artifact.bytecode.replace(/^0x/, "");
  for (const [path, libs] of Object.entries(artifact.linkReferences)) {
    for (const [name, refs] of Object.entries(libs)) {
      const key = `${path}:${name}`;
      const address = addresses[key];
      if (!address) throw new Error(`no address to link ${key}`);
      const hex = toEvm(address).slice(2).toLowerCase();
      for (const { start, length } of refs) {
        if (length !== 20) throw new Error(`unexpected link length ${length} for ${key}`);
        code = code.slice(0, start * 2) + hex + code.slice((start + length) * 2);
      }
    }
  }
  if (code.includes("__$")) throw new Error("bytecode still has an unlinked placeholder");
  return "0x" + code;
}

/** A `bytes constant NAME = hex"…";` pinned in a Solidity file (the guard's bootstrap pins). */
export function pinnedBytes(solFile, name) {
  const source = readFileSync(solFile, "utf8");
  const match = source.match(new RegExp(`bytes constant ${name}\\s*=\\s*hex"([0-9a-fA-F]*)"`));
  if (!match) throw new Error(`${name} not found in ${solFile}`);
  return "0x" + match[1];
}
