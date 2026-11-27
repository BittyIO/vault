# Bitty account on TRON

forge builds and tests (`FOUNDRY_PROFILE=tron forge build`); `account.mjs` sends. It deploys
`TronStakeOps` and `BittyAccountFactory` (`src/account`) and reads them back.

```
npm install
node account.mjs config  --network nile                 # what the factory is built with (no key)
read -s TRON_PRIVATE_KEY; export TRON_PRIVATE_KEY
node account.mjs deploy  --network nile [--relayer <addr>]
node account.mjs show    --network nile
node account.mjs predict --network nile <owner> [index]
node account.mjs set-relayer    --network nile <addr>   # factory owner only
node account.mjs transfer-owner --network nile <addr>
node account.mjs accept-owner   --network nile          # the new owner's key
```

The deploying key becomes the factory owner, the one key that can change the relayer (who is paid the
relayed USDT fee and the 0.2% swap fee in TRX). USDT, the SunSwap router and Permit2, the TRX/USD feed
and TronStakeOps are fixed into the implementation, and so into every account address.

Network settings are in `networks/<network>.json` (USDT, relayer, the TRX/USD feed under
`guard.priceFeeds`); the deployed addresses are written to `deployments/<network>.account.json`.
