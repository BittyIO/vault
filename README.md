# Bitty Vault Contracts

Solidity contracts for Bitty Vault: a factory deploys minimal proxy vaults per owner, each vault manages assets through guard-approved lending, staking, and AMM protocols.

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

Local tests only (BittyVaultFactory and BittyVault; no RPC required):

```shell
forge test -vvv
```

Coverage report:

```shell
forge coverage --ir-minimum --no-match-coverage 'test|node_modules|script|src/libs'
```

## Deploy

Deployment scripts read chain-specific addresses from `deployments/<chain>.toml` via `forge-std` config. Example for Sepolia:

```shell
source .env
forge script script/BittyVaultFactory.s.sol:Deploy \
  --rpc-url sepolia \
  --broadcast \
  --private-key $SEPOLIA_PRIVATE_KEY \
  -vvvv
```

The factory script uses CREATE2 via the immutable factory at `0x0000000000FFe8B47B3e2130213B802212439497`. Deployed addresses are written back to the chain TOML under `deployments/`.

### Deploy logic libraries

`BittyVault` links against the `VaultLogic` and `AssetManagerLogic` libraries, deployed via the canonical CREATE2 deployer (`0x4e59b44847b379578588920cA78FbF26c0B4956C`, salt `0x0`) so they land at the same address on every chain. `forge script` normally deploys these automatically as part of `BittyVaultFactory.s.sol:Deploy`, but if a broadcast is interrupted before they confirm, the vault implementation ends up linked against addresses with no code. Use this script to (re)deploy any missing library to its expected address:

```shell
source .env
forge script script/DeployLogicLibraries.s.sol:DeployLogicLibraries \
  --rpc-url sepolia \
  --broadcast \
  --private-key $SEPOLIA_PRIVATE_KEY \
  -vvvv
```

It's idempotent — libraries already present at their expected address are skipped.

## Verify

```shell
forge verify-contract \
  --chain sepolia \
  <factory-address> \
  src/BittyVaultFactory.sol:Factory \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

### Verify logic libraries

`AssetManagerLogic` links against `VaultLogic`, so pass its deployed address via `--libraries`:

```shell
forge verify-contract \
  --chain sepolia \
  0x34B12C466A49Ebc0f77Ec4648dE63f1D1C18786B \
  src/logic/VaultLogic.sol:VaultLogic \
  --etherscan-api-key $ETHERSCAN_API_KEY

forge verify-contract \
  --chain sepolia \
  0x2325AE2429e3B43650c6D3f1D7bB13cAdC6d8dee \
  src/logic/AssetManagerLogic.sol:AssetManagerLogic \
  --libraries src/logic/VaultLogic.sol:VaultLogic:0x34B12C466A49Ebc0f77Ec4648dE63f1D1C18786B \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

### Verify vault implementation

`BittyVault` links against both logic libraries, so pass both deployed addresses via `--libraries`:

```shell
forge verify-contract \
  --chain sepolia \
  <vault-implementation-address> \
  src/BittyVault.sol:BittyVault \
  --libraries src/logic/VaultLogic.sol:VaultLogic:0x34B12C466A49Ebc0f77Ec4648dE63f1D1C18786B \
  --libraries src/logic/AssetManagerLogic.sol:AssetManagerLogic:0x2325AE2429e3B43650c6D3f1D7bB13cAdC6d8dee \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

`<vault-implementation-address>` is the `VAULT_IMPLEMENTATION` value recorded in `deployments/<chain>.toml`.

## Formatting

```shell
forge fmt
forge fmt --check   # CI uses this
```

## License

AGPL-3.0-only
