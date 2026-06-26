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

Deployment scripts read chain-specific addresses from `deployments/<chain>.toml` via `forge-std` config. Deploy in order — each step writes addresses the next step needs.

### Step 1 — logic libraries

Deploy `VaultLogic` and `AssetManagerLogic` via the canonical CREATE2 deployer (`0x4e59b44847b379578588920cA78FbF26c0B4956C`, salt `0x0`). Both live in `script/DeployLogicLibraries.s.sol` and must be broadcast separately.

**1a — VaultLogic** (no `--libraries` flag):

```shell
source .env
forge script script/DeployLogicLibraries.s.sol:DeployVaultLogic \
  --rpc-url sepolia \
  --broadcast \
  --private-key $SEPOLIA_PRIVATE_KEY \
  -vvvv
```

**1b — AssetManagerLogic** (links against VaultLogic at `0xc65daA9e6a35A6a25E08492b962DA927864B9F9e`):

```shell
forge script script/DeployLogicLibraries.s.sol:DeployAssetManagerLogic \
  --rpc-url sepolia \
  --broadcast \
  --private-key $SEPOLIA_PRIVATE_KEY \
  --libraries src/logic/VaultLogic.sol:VaultLogic:0xc65daA9e6a35A6a25E08492b962DA927864B9F9e \
  -vvvv
```

Writes `VAULT_LOGIC` and `ASSET_MANAGER_LOGIC` to `deployments/<chain>.toml`.

### Step 2 — vault implementation

Deploy `BittyVault` via CREATE2. Pass both library addresses from step 1:

```shell
forge script script/DeployBittyVault.s.sol:Deploy \
  --rpc-url sepolia \
  --broadcast \
  --private-key $SEPOLIA_PRIVATE_KEY \
  --libraries src/logic/VaultLogic.sol:VaultLogic:0xc65daA9e6a35A6a25E08492b962DA927864B9F9e \
  --libraries src/logic/AssetManagerLogic.sol:AssetManagerLogic:0x3bcE6098B426613bA86d4d23e9E5eE4a9A54968E \
  -vvvv
```

Writes `VAULT_IMPLEMENTATION` to `deployments/<chain>.toml`.

### Step 3 — factory

Deploy `BittyVaultFactory` via the immutable factory at `0x0000000000FFe8B47B3e2130213B802212439497`, initialized with `VAULT_IMPLEMENTATION`, `BITTY_GUARD`, and `WETH` from the chain TOML:

```shell
forge script script/DeployBittyVaultFactory.s.sol:Deploy \
  --rpc-url sepolia \
  --broadcast \
  --private-key $SEPOLIA_PRIVATE_KEY \
  -vvvv
```

Writes `BITTY_VAULT_FACTORY` to `deployments/<chain>.toml`.

Each script is idempotent — contracts already present at their expected address are skipped.

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
  0xFb20542A2FeA887578D598e102e14D0E86db8291 \
  src/logic/VaultLogic.sol:VaultLogic \
  --etherscan-api-key $ETHERSCAN_API_KEY

forge verify-contract \
  --chain sepolia \
  0x93cc0FcF2D8EddB6a9Be480b7A7BaAFa07D9Af4F \
  src/logic/AssetManagerLogic.sol:AssetManagerLogic \
  --libraries src/logic/VaultLogic.sol:VaultLogic:0xFb20542A2FeA887578D598e102e14D0E86db8291 \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

### Verify vault implementation

`BittyVault` links against both logic libraries, so pass both deployed addresses via `--libraries`:

```shell
forge verify-contract \
  --chain sepolia \
  <vault-implementation-address> \
  src/BittyVault.sol:BittyVault \
  --libraries src/logic/VaultLogic.sol:VaultLogic:0xFb20542A2FeA887578D598e102e14D0E86db8291 \
  --libraries src/logic/AssetManagerLogic.sol:AssetManagerLogic:0x93cc0FcF2D8EddB6a9Be480b7A7BaAFa07D9Af4F \
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
