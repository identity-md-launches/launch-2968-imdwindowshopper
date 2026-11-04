# IMDwindowshopper (WWW)

A fixed supply ERC-20 for the requested Ethereum custom token launch.

| Parameter | Value |
| --- | --- |
| Solidity contract | `src/IMDwindowshopper.sol:IMDwindowshopper` |
| Token name | `IMDwindowshopper` |
| Symbol | `WWW` |
| Decimals | `18` |
| Whole-token supply | `1,000,000,000` |
| Supply in smallest units | `1000000000000000000000000000` (`10^27`) |
| Constructor arguments | None |
| Deployment value | No native currency |
| Initial recipient | Immediate deployer (`msg.sender`) |
| Administrative roles | None |

## Behavior and assumptions

The constructor calls `_mint` exactly once, minting the full `INITIAL_SUPPLY` to
the immediate deployer. In the specified launch this is the factory, including
when it uses CREATE2. The wallet calling the factory does not receive the mint.
The token's constructor neither calls another contract nor distributes tokens.

Only a plain ERC-20 was requested, so there are no taxes, transfer limits,
rebases, burn entrypoints, subsequent minting, pause or blacklist controls,
ownership, upgrades, or application contracts. There is no setup transaction.
All transfers deliver the exact requested amount. Supply remains fixed forever.

The implementation inherits the vendored OpenZeppelin Contracts v5.4.0 `ERC20`
without changing its transfer or approval behavior:

- `transfer`, `approve`, and `transferFrom` return `true` on success and revert
  with ERC-6093 custom errors on failure.
- Transfers to the zero address and approvals to a zero spender revert. Zero
  value transfers between nonzero addresses are valid and emit `Transfer`.
- Transfers to oneself preserve the balance but still require sufficient funds.
- `transferFrom` requires the caller's allowance, even when the caller is the
  holder. Finite allowances decrease; `type(uint256).max` remains unlimited.
- `approve` replaces the current allowance, and setting it to zero revokes it.
  A failed delegated transfer rolls back any allowance change.
- `Approval` is emitted by `approve`; allowance consumption does not emit it.
  Integrations should read `allowance` for the current value.
- The token makes no external calls or recipient callbacks and has no payable
  functions, fallback, rescue mechanism, or permit/signature interface.

## Build and check

Use Foundry with Solidity **0.8.26** available. `foundry.toml` pins that compiler,
the Cancun EVM target, optimizer with 200 runs, and `bytecode_hash = "none"`.
All Solidity dependencies and their licenses are ordinary files under `lib/`;
no dependency installation, submodules, RPC, environment configuration, FFI, or
filesystem permission grants are needed. Offline verification requires Foundry
and the pinned compiler supplied by the verifier.

```sh
forge build
forge test
forge fmt --check
```

The fuzz seed is pinned to the assignment's
`0x915cad6886e278208e492b7a2dd43801bff7a0bc3064fd9d15310ebb029412d1`.
The configuration uses 1,024 runs per fuzz test and 128 invariant runs with 64
calls per sequence. Tests use isolated local fixtures and no environment reads,
forks, network access, or ordering dependencies.

Tests cover metadata, constructor mint/event and contract deployment, exact
transfers, zero/self/full-balance transfers, approvals/revocation, finite and
unlimited allowances, unauthorized spending, invalid addresses, insufficient
balances/allowances, revert atomicity, rejected mint/admin calls, and rejected
native-currency transfers. Stateful invariants track supply conservation and
allowances through randomized transfers, approvals, and delegated spending.

`test/LaunchFlow.t.sol` checks CREATE2 deployment and exact token movements for
the 10%/70%/20% distribution, claims, and transfers to and from a pool address.
It is a token-flow simulation, not a Uniswap integration or pricing test. The
provided protected tests require the separate launch harness, resolved manifest,
and Uniswap infrastructure; their full pool seeding and swaps are checked by the
independent launch verifier, not reproduced by this local fixture.

Dependency release URLs and downloaded archive hashes are recorded in each
dependency's `VENDORED.md`. OpenZeppelin supplies the production implementation;
forge-std v1.9.7 is used only by tests.

## Deployment and launch responsibilities

The deployment artifact is `out/IMDwindowshopper.sol/IMDwindowshopper.json`.
Its creation bytecode takes no appended constructor arguments, contains no
external library links, and needs no external addresses or initialization calls.
Deploy the token itself, without a proxy. Its Solidity identifier fits the
launch's 32-character limit.

The separate launch pipeline prepares `launch.json`, resolves the factory and
other launch contracts, performs independent review, deploys, and verifies the
source. This repository supplies the token, tests, and configuration; it does
not send transactions or supply a launch manifest.

The following values are supplied launch configuration, not settings enforced
or executed by the token:

| Launch parameter | Supplied value |
| --- | --- |
| Chain | Ethereum, chain ID `1` |
| Paired currency | IMD, `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` (18 decimals) |
| Pool fee | `12500` (1.25%) |
| Tick spacing | `60` |
| Initial price provenance | `79228162514264337593543950336` |
| `economics.poolBps` | `7000` |
| `economics.initialMarketCapWei` | `"2500000000000000000000"` |
| `economics.remainderTo` | `0xee2aaa315cf7ed169f93148d30d24af9318dbb66` |

The factory receives all tokens and is responsible for sending 10% (100 million
WWW) to its MerkleDistributor, allocating 70% (700 million WWW) to pool seeding,
and forwarding the remaining 20% (200 million WWW) to the supplied remainder
recipient. No allocation happens in this constructor. The deployer derives the
actual opening pool price from the market capitalization, supply, and currency
ordering; the provenance price above does not override that calculation.

After deployment, the launch operator should verify the deployed source and
metadata, exact supply, constructor mint recipient, and distribution receipts.
The token requires no oracle, keeper, backend, or owner-managed configuration.

## After launch

There are no setters, admin keys, or operational tasks inside the token. Holders
control their transfers and allowances. Prefer bounded approvals; when replacing
an existing nonzero allowance, revoke it and confirm that transaction before
granting the replacement to reduce the standard ERC-20 allowance race.

Transfers cannot be reversed by an administrator. Standard ERC-20 transfers do
not confirm recipient support: tokens sent to this token's own address or another
contract without withdrawal support can be permanently inaccessible. There is
no recovery function for mistaken token deposits or forcibly received ETH.

The supplied eth-security reference informed the source review: the deployed
token has no external calls, signatures, oracle inputs, upgrade path, or
privileged balance changes. Foundry checks are local validation, not an
independent security audit. Slither, Mythril, production deployment, explorer
verification, and the protected launch integration suite are outside the local
checks documented here; independent review remains the launch pipeline's
responsibility before release.
