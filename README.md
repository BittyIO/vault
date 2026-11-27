# Bitty account (TRON)

A smart contract account for one user's USDT on TRON, with the protections a leaked key needs, made by
`BittyAccountFactory` as EIP-1167 clones at addresses known before they exist.

- **Payees**: addresses that become payable after the timelock, and can be paid any amount, even while locked.
- **A daily USDT limit** on sends to anyone else (UTC days).
- **A lock**, instant; unlocking waits out the timelock.
- **A timelock** on anything that loosens a protection, and on any call other than a USDT send.
- **TRX** goes to payees only.
- **Relayed sends**: the owner key signs (EIP-712), anyone sends, so the key needs no TRX. USDT to the
  factory's relayer skips the payee, lock and limit rules, capped at 1,000 USDT per account per UTC day.
- **Staking TRX for energy** in the account, delegated to the owner, a payee, or (after the timelock) anyone.
- **TRX ↔ USDT swaps** on SunSwap into the account, for a 0.2% fee in TRX to the relayer; value lost
  against the TRX/USD feed counts toward the daily limit.

The factory's owner (its deployer) can change the relayer, and nothing else; it has no upgrade.

```
forge test                         # src/account, test/local/account
FOUNDRY_PROFILE=tron forge build   # the TRON build tron/account.mjs deploys
```

Deploying and reading on TRON: see [tron/README.md](tron/README.md).
