# Bitty Vault Contracts

Solidity contracts for Bitty Vault: a factory deploys minimal proxy vaults per owner, each vault manages assets through guard-approved lending, staking, and AMM protocols.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Git with submodule support

## Setup

Clone the repository and initialize all dependencies as git submodules:

```shell
git clone --recurse-submodules https://github.com/bittyio/vault-contracts.git
cd vault-contracts
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

## Verify

```shell
forge verify-contract \
  --chain sepolia \
  <factory-address> \
  src/BittyVaultFactory.sol:Factory \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

## Formatting

```shell
forge fmt
forge fmt --check   # CI uses this
```

## License

AGPL-3.0-only
