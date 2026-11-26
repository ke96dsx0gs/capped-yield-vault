# capped-yield-vault

Single-strategy ERC-4626 style vault with a hard deposit cap and a performance fee on
yield above a high-water mark.

## Why

Two problems show up in almost every small vault review:

1. A strategy can be scaled beyond what it can safely absorb. A cap that is enforced
   on-chain, not by a front end, puts a hard ceiling on TVL.
2. A performance fee needs a high-water mark, otherwise the manager charges on a
   recovery leg after a drawdown and gets paid twice for the same profit.

This repo is the smallest contract that does both and nothing else. No proxying, no
strategy hook, no rebalancing logic: the share price only moves when someone donates
yield to the vault and the owner harvests.

## Invariants

- `totalAssets() <= cap` for every non-zero cap; deposits and mints revert with
  `CapExceeded` once free capacity runs out.
- Fee shares are minted only when `totalAssets() > highWaterMark`. A loss leaves the
  mark untouched, so a recovery below the old peak is fee free.
- Rounding is always in favour of the vault where it must be: `mint` and `withdraw`
  round shares up, `deposit` and `redeem` round down.
- No owner function can move assets. The owner can only change `cap`, `feeBps`,
  `feeRecipient`, `owner`, and call `harvest`.
- `highWaterMark` never decreases during a cycle. It is seeded by the first deposit
  (post-deposit `totalAssets()`) and re-seeded only when the vault is fully exited,
  so a later cycle starts from a clean baseline. Fee shares are minted to
  `feeRecipient` only.

## Roles

| Role         | Holds                                     |
| ------------ | ----------------------------------------- |
| `owner`      | `setCap`, `setFee`, `setFeeRecipient`, `transferOwnership`, `harvest` |
| `feeRecipient` | receives minted fee shares              |
| depositors   | `deposit`, `mint`, `withdraw`, `redeem`   |

`MAX_FEE_BPS` is 2000 (20%) and is enforced at construction and on every fee change.
A cap of `0` means uncapped; `cap` is checked against `totalAssets()`.

## Install

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```sh
git clone https://github.com/ke96dsx0gs/capped-yield-vault
cd capped-yield-vault
forge install foundry-rs/forge-std   # tests only
forge build
forge test
```

## Usage

```solidity
CappedVault vault = new CappedVault(asset, owner, treasury, 5_000_000e18, 1_000);

asset.approve(address(vault), amount);
vault.deposit(amount, msg.sender);   // reverts past the cap

// after a strategy reports profit:
vault.harvest();                     // mints fee shares above the high-water mark
```

Fee math at harvest: `feeAssets = (totalAssets - highWaterMark) * feeBps / 10_000`,
converted to shares at the pre-fee price. Because `highWaterMark` is updated to the
current `totalAssets`, harvesting twice in a row charges the fee once. Deposits into an
empty vault set the baseline, so principal is never billed as profit.

## Layout

```
src/
  CappedVault.sol        vault: cap, fee, HWM, ERC-20 shares
  lib/ERC20.sol          minimal share token (no hooks, no permit)
  interfaces/IERC20.sol  three-method asset surface
  mocks/MockERC20.sol    test token
test/
  CappedVault.t.sol      cap, rounding, fee and drawdown coverage
```

## Upgrade path

The contract is immutable by design. To migrate: `setCap(0)`, let depositors redeem at
their own pace, then deploy a new vault and point the front end at it. There is no
admin sweep, so a migration cannot strand funds behind a paused contract.

## Caveats

- `maxWithdraw` / `maxRedeem` are not implemented yet, so integrators should call
  `previewWithdraw` / `previewRedeem` and treat the vault as always liquid.
- The vault assumes the asset does not take a transfer fee and does not rebase.
- Yield has to be pushed to the vault by an external strategy; there is no internal
  accounting for off-contract positions.

MIT licensed. Not audited; do not point real money at it without a review.
