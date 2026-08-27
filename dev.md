# Bitty Vault — Development

Build, test, deploy, and verify the Bitty Vault contracts. For what the vault is and how it works, see the [README](./README.md).

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Git with submodule support

## Setup

Clone the repository and initialize all dependencies as git submodules:

```shell
git clone --recurse-submodules https://github.com/bittyio/vault.git
cd vault
```

If you already cloned without submodules:

```shell
git submodule update --init --recursive
```

Copy the sample environment file and fill in your keys:

```shell
cp .env.sample .env
```

| Variable | Purpose |
| --- | --- |
| `ALCHEMY_KEY` | RPC access for fork tests and scripted deployments |
| `ETHERSCAN_API_KEY` | Contract verification on Etherscan |
| `SEPOLIA_PRIVATE_KEY` | Broadcasting key for Sepolia deployments |
| `MAINNET_PRIVATE_KEY` | Broadcasting key for mainnet deployments |

Foundry reads `.env` automatically for `${ALCHEMY_KEY}` and `${ETHERSCAN_API_KEY}` in `foundry.toml`.

## Build

```shell
forge build
```

## Test

Run all tests:

```shell
forge test -vvv
```

Local tests only (BittyV1VaultFactory and BittyV1Vault; no RPC required):

```shell
forge test -vvv --no-match-path 'test/fork/*'
```

Coverage report:

```shell
forge coverage --ir-minimum --no-match-coverage 'test|node_modules|script|src/libs'
```

## Deploy

`script/Deploy.s.sol` is the only deploy script. It brings up the whole stack in dependency order —
forwarder, DeFi facet, auto-yield keeper, implementation, factory — and wires the factory to them.

Chain-specific addresses live in `deployments/<chain>.toml`. The script reads them, and writes the ones
it creates back, through `forge-std`'s `Config`.

The guard, the fee collector and the forwarder are deliberately *not* in the TOML. All three are
compile-time constants in `src/logic/Constants.sol`, identical on every chain, so the TOML carries only
what genuinely varies per chain or is genuinely discovered by the run.

**Before you start**, the chain's TOML must already contain:

| Key | Notes |
| --- | --- |
| `WETH` | |
| `BITTY_FORWARDER_OWNER` | controls the relayer allowlist. A Safe is the right answer; the deployer EOA works but is a hot key sitting on every vault's fee path |
| `BITTY_RELAYER` | optional — approved for `executeWithFee` / `executeBatchWithFee` if present. Without it the forwarder still relays, it just cannot charge |

`BITTY_FORWARDER_OWNER` doubles as the owner of `BittyV1AutoYieldKeeper`, which the script deploys and
records as `BITTY_AUTO_YIELD_KEEPER`. Deploy order is forced by two immutables on the implementation —
the DeFi facet and the keeper — so both must exist before it: **forwarder → facet → keeper →
implementation → factory**.

The facet and keeper go through the canonical CREATE2 deployer at
`0x4e59b44847b379578588920cA78FbF26c0B4956C` with salt `0`, so each address is a function of its init
code — constructor arguments included. That is what makes re-running safe: code at the predicted address
is byte-for-byte this build, never a leftover from an older generation. Reusing whatever a TOML key
happens to name cannot promise that, and would silently pick up the previous generation on an upgrade.
It also means changing either moves its address, and the implementation moves whenever the facet or
keeper does.

The **implementation** goes through `ImmutableCreate2Factory` instead, with `IMPLEMENTATION_SALT`. Not
for a vanity address — its init code carries the facet and keeper, so the address moves on every upgrade
and no mined suffix would survive — but for `containsCaller`. It is the only deployment here with an
`initialize`, so on a fresh chain a squatter using the open salt-0 deployer could have front-run it and
claimed the singleton. A DEPLOYER-prefixed salt makes that impossible. The claim itself is gated on
`owner() == address(0)`, so a run that deployed and then failed before claiming still claims on retry.

After a *later* forwarder generation ships, add it to the existing keeper with
`setForwarder(newForwarder, true)` rather than deploying a new keeper. Vaults freeze their trigger, so a
new keeper address would strand every vault already live.

**The broadcasting key must be the DEPLOYER**, `0x12EE2de7BF086388B1D560eb95e7191Edfab9823`. Both
`BittyV1VaultForwarder.initialize` and `BittyV1VaultFactory.initialize` gate on `tx.origin` rather than
`msg.sender` — which stops another chain's squatter from claiming the address, and also means these two
calls cannot be relayed or sent from a multisig.

**Every deploy must use `FOUNDRY_PROFILE=deploy`** — see [Build profiles](#build-profiles) below. That
profile pins the logic library addresses and drops metadata, so the default profile builds the same
source to different bytecode and therefore different CREATE2 addresses.

```shell
source .env

FOUNDRY_PROFILE=deploy forge script script/Deploy.s.sol:Deploy \
  --rpc-url sepolia \
  --broadcast \
  --private-key $SEPOLIA_PRIVATE_KEY \
  -vvvv
```

Writes `BITTY_AUTO_YIELD_KEEPER`, `VAULT_IMPLEMENTATION`, `DEFI_FACET`, `VAULT_LOGIC`,
`ASSET_MANAGER_LOGIC` and `BITTY_VAULT_FACTORY`. The forwarder is not written: its address is already
`BITTY_FORWARDER` in `Constants.sol`, and the script hard-`require`s that the two agree before it
deploys anything, so a TOML copy could only ever restate a value the build already fixed.

No `--libraries` flag is needed. Under the `deploy` profile the two logic libraries are pinned in
`foundry.toml`, so the build is already linked and the script only has to put code at those two
addresses — `_deployLogicLibraries` does that, through the salt-0 deployer that the pins were derived
from, skipping either that already has code. (Under the default profile forge auto-deploys them as part
of the broadcast and the step is a no-op.) Either way the TOML ends up naming the libraries the
implementation is actually linked against, via `address(VaultLogic)` / `address(AssetManagerLogic)` —
which is what the verify step below needs.

The run is idempotent. Anything already at its expected address is skipped, and each `initialize` is
only called when it has not run yet, so a partial deployment can simply be re-run.

> **Simulating.** Drop `--broadcast` for a dry run — but note it still rewrites the TOML, because the
> implementation and facet really are deployed inside the fork, at addresses that will not exist
> afterwards. Back the file up if the current values matter.

### Build profiles

There are two, and they build the **same source to different bytecode**:

| | `default` | `deploy` |
| --- | --- | --- |
| out dir | `out/` | `out-deploy/` |
| logic libraries | auto-deployed by forge, linked at whatever address the run assigned | pinned in `foundry.toml` |
| metadata | appended | `bytecode_hash = "none"`, `cbor_metadata = false` |

Different bytecode means **different init code, and therefore different CREATE2 addresses** — the same
salt lands somewhere else. That is the single easiest way to mine a salt against bytecode nobody
deploys, so: `deploy` for every real deploy, every salt mine, every address prediction and every
verify. `default` for `forge test`, which needs the auto-deployed libraries — pinning them there would
link every test to two empty addresses and revert on the first library call.

The pin exists so an implementation address is reproducible at all: `BittyV1Vault` links `VaultLogic`
(48 sites) and `AssetManagerLogic` (13), the facet links both (19), and those addresses are baked into
creation code. `bytecode_hash = "none"` is what makes the pin a fixed point — solc records the
`libraries` setting in metadata, so with metadata appended, pinning an address changes the bytecode of
the library being pinned and moves its own address.

`ImplSalt.t.sol` and `LibAddr.t.sol` skip themselves outside the `deploy` profile rather than report
numbers no deploy will produce.

### Predicting addresses

> **No tooling for this right now.** Predicting the addresses has to resolve a chain — the pinned
> library addresses, then the facet, then the keeper, then the implementation whose constructor
> arguments are the facet and keeper *addresses* — and it cannot be a forge test, because `forge test`
> links libraries at ephemeral addresses rather than the pinned ones, so anything computed inside a
> test hashes to something no deploy will ever produce.
>
> It therefore has to read `out-deploy/` from outside Solidity. That script is not in the repo. Until
> it is, derive the addresses by hand from the artifacts: link each contract's `linkReferences` at the
> pinned library addresses, append the constructor arguments, and take
> `keccak256(0xff ‖ factory ‖ salt ‖ keccak256(initCode))[12:]`.
>
> The same gap covers the drift checks that used to live here: the two library pins in `foundry.toml`,
> `BITTY_FORWARDER` in `Constants.sol`, and `IMPLEMENTATION_SALT` differing between `Deploy.s.sol` and
> `ImplSalt.t.sol`. Each of those goes stale silently, so check them by eye before mining or deploying.

### Deterministic addresses and salt mining

The forwarder, the factory and the implementation all go through `ImmutableCreate2Factory` at
`0x0000000000FFe8B47B3e2130213B802212439497`, which requires the salt's leading 20 bytes to equal the
caller — so only the trailing 12 bytes are free to search, and no one but the DEPLOYER can use these
salts on any chain. All three are hardcoded in `script/Deploy.s.sol` as `FORWARDER_SALT`, `FACTORY_SALT`
and `IMPLEMENTATION_SALT`.

Only the first two are mined for vanity; `IMPLEMENTATION_SALT` is the DEPLOYER prefix followed by zeros,
because the implementation's address is not stable across releases anyway.

The script computes each target address itself rather than calling
`ImmutableCreate2Factory.findCreate2Address`, which returns `address(0)` once a salt has been used —
a sentinel that reads as "nothing deployed here" and would send every re-run into `safeCreate2` and
revert.

Neither contract takes constructor arguments, deliberately: constructor arguments are appended to the
init code, and init code is what CREATE2 hashes. With none, the same salt lands on the same address on
every chain even where each chain has a different owner.

The corollary is that **changing either contract's bytecode moves its address**, so the salt has to be
re-mined. For the forwarder that is more than an inconvenience: a vault stores its `trustedForwarder`
once at `initialize` and has no setter, so vaults already deployed cannot be pointed at a new forwarder
and must be re-activated under a new factory. Print what a miner needs with:

```shell
FOUNDRY_PROFILE=deploy forge test --match-test test_printInitCodeHashForSaltMining -vv
```

That prints the forwarder's init code hash, which is the input a miner wants. The forwarder can do
this from a test because it links no library and takes no constructor arguments — its creation code is
the same everywhere. The implementation and the facet cannot, for the reason in the note above.

Only the trailing 12 bytes of the salt are free; the leading 20 must stay the DEPLOYER address or
`ImmutableCreate2Factory` rejects it — so a miner has to be told the caller, not just the hash.

#### Mining order

The implementation is mined **last**, and the order ahead of it is forced rather than preferred:

| step | | depends on |
| --- | --- | --- |
| 1 | `VaultLogic` pin | nothing — links nothing, so its source alone fixes it |
| 2 | `AssetManagerLogic` pin | `VaultLogic`'s pin (it links `VaultLogic` at 4 sites) |
| 3 | `FORWARDER_SALT` → `BITTY_FORWARDER` | nothing — the forwarder imports nothing |
| — | `FACTORY_SALT` | nothing — links no library, imports no constant, so mine it whenever |
| 4 | `IMPLEMENTATION_SALT` | all of the above |

`BittyV1Vault` and `BittyV1VaultDeFiFacet` are the only two carrying inputs from elsewhere. They LINK
both logic libraries, so the pinned addresses are baked into their creation code, and they import
`Constants.sol`, so `BITTY_FORWARDER` is too. Move any of those three and the implementation's init
code changes — a salt mined earlier lands on an address the deploy can never reach.

Steps 1–2 are the two library pins in `foundry.toml` under `[profile.deploy]`. Re-pin them in that
order, rebuilding between them: `AssetManagerLogic`'s bytecode carries `VaultLogic`'s pinned address,
so it is only meaningful once that pin is final. `test/local/LibAddr.t.sol` derives both addresses
independently as a cross-check:

```shell
FOUNDRY_PROFILE=deploy forge test --match-path test/local/LibAddr.t.sol -vv
```

Step 3 re-derives `BITTY_FORWARDER` in `Constants.sol` from `FORWARDER_SALT` in `Deploy.s.sol` and the
forwarder's init code hash. There is no circularity: the forwarder imports nothing from
`Constants.sol`, so editing the constant cannot change the forwarder's bytecode, and the value
converges in one pass.

Step 4 is the implementation, mined last and only when the release is otherwise frozen.

**Nothing enforces this order.** A stale library pin or a stale `BITTY_FORWARDER` produces an
implementation salt that lands on an address the deploy can never reach, and the failure is silent —
the numbers all look fine. Re-check each input before mining the implementation.

The implementation is also the least durable of the three: ANY edit to `BittyV1Vault`, the facet, the
keeper, either logic library or `Constants.sol` moves it again. Mine it last, and mine it only when the
release is otherwise frozen.

## Verify

Requires `ETHERSCAN_API_KEY` in `.env`.

The `--libraries` addresses below must be the ones the deployed bytecode is **actually linked against**.
`VAULT_LOGIC` and `ASSET_MANAGER_LOGIC` in the chain TOML are written by the deploy script for exactly
this purpose, so they are the values to use. `{BITTY_FORWARDER}` below comes from `Constants.sol`, not
the TOML. If a deployment predates that and the two look suspect,
`broadcast/Deploy.s.sol/<chainid>/run-latest.json` is authoritative.

### Verify logic libraries

`VaultLogic` is standalone; `AssetManagerLogic` links against it:

```shell
forge verify-contract \
  --chain sepolia \
  {VAULT_LOGIC} \
  src/logic/VaultLogic.sol:VaultLogic \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --watch

forge verify-contract \
  --chain sepolia \
  {ASSET_MANAGER_LOGIC} \
  src/logic/AssetManagerLogic.sol:AssetManagerLogic \
  --libraries src/logic/VaultLogic.sol:VaultLogic:{VAULT_LOGIC} \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --watch
```

### Verify implementation and DeFi facet

Both link against `VaultLogic` + `AssetManagerLogic`:

```shell
forge verify-contract \
  --chain sepolia \
  {VAULT_IMPLEMENTATION} \
  src/BittyV1Vault.sol:BittyV1Vault \
  --libraries src/logic/VaultLogic.sol:VaultLogic:{VAULT_LOGIC} \
  --libraries src/logic/AssetManagerLogic.sol:AssetManagerLogic:{ASSET_MANAGER_LOGIC} \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --watch

forge verify-contract \
  --chain sepolia \
  {DEFI_FACET} \
  src/BittyV1VaultDeFiFacet.sol:BittyV1VaultDeFiFacet \
  --libraries src/logic/VaultLogic.sol:VaultLogic:{VAULT_LOGIC} \
  --libraries src/logic/AssetManagerLogic.sol:AssetManagerLogic:{ASSET_MANAGER_LOGIC} \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --watch
```

### Verify factory, forwarder and keeper

The factory and forwarder take no constructor arguments; the keeper does, so it needs
`--constructor-args`:

```shell
forge verify-contract \
  --chain sepolia \
  {BITTY_VAULT_FACTORY} \
  src/BittyV1VaultFactory.sol:BittyV1VaultFactory \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --watch

forge verify-contract \
  --chain sepolia \
  {BITTY_FORWARDER} \
  src/BittyV1VaultForwarder.sol:BittyV1VaultForwarder \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --watch

forge verify-contract \
  --chain sepolia \
  {BITTY_AUTO_YIELD_KEEPER} \
  src/BittyV1AutoYieldKeeper.sol:BittyV1AutoYieldKeeper \
  --constructor-args $(cast abi-encode "constructor(address)" {BITTY_FORWARDER_OWNER}) \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --watch
```

The implementation now takes constructor arguments too — the facet and the keeper — so it needs
`--constructor-args $(cast abi-encode "constructor(address,address)" {DEFI_FACET} {BITTY_AUTO_YIELD_KEEPER})`
alongside its `--libraries` flags.

Pass the flags literally — collapsing the two `--libraries` into one shell variable makes forge read
them as a single argument and fail.

## Formatting

```shell
forge fmt
forge fmt --check   # CI uses this
```
