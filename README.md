# Swarm Cities contracts

Swarm Cities is a 16 × 16 city registry on Sepolia (chain ID 11155111), using the
fixed-supply **Swarm Cities (GRID)** ERC-20. This contribution delivers contracts,
local tests, ABI exports and integration/deployment documentation. It does not
deploy contracts, publish a website, or create the separately assigned `launch.json`.

> Buy a city, the fee fills the pots, a heartbeat grows the top cities, higher level earns more of the fee.

## Build and test

```sh
forge build
forge test
forge fmt --check
```

The project pins Solidity **0.8.26**, Cancun, optimizer 200 runs and
`bytecode_hash = "none"`. FFI and filesystem cheatcode access are disabled.
Production contracts have no external source dependencies. Test dependency
forge-std v1.16.2 is vendored in `lib/forge-std/` with its licenses; no submodules
or network fetches are needed once the pinned compiler is installed by the runner.
Tests use no environment variables, fork, RPC, wallet keys or broadcasting.

## Contracts and deployment parameters

All constructors are nonpayable. There are no initializers, proxies, upgrades,
post-deployment configuration calls or administrator withdrawals.

| Deployment order | Artifact | Constructor arguments |
| --- | --- | --- |
| Token | `src/LaunchToken.sol:LaunchToken` | None |
| Application 1 | `src/GrantExecutor.sol:GrantExecutor` | `address operator_` |
| Application 2 | `src/CityRegistry.sol:CityRegistry` | `address token_`, `address grantExecutor_`, `address treasury_` |

The approved workflow requires **both `operator_` and `treasury_`** to be
`0x5b95A971B4583A5f011E9DA082acdD679b870D06`. These are explicit immutable parameters,
not privileges derived from constructor `msg.sender`. The registry's `token_`
must be the launch's `LaunchToken`; `grantExecutor_` must be the preceding
`GrantExecutor`. Constructors reject empty dependency addresses/code, zero roles,
and non-18-decimal tokens. They do not authenticate arbitrary substitute bytecode;
the source/manifest review must verify these bindings.

For the separate manifest author: list the two applications in the order above,
using `$token` and `$contract:GrantExecutor` for the registry's dependency addresses.
Use `$owner` for the operator only if the pinned policy owner equals the exact
approved workflow address. A different owner is a concrete authorization conflict
for independent review; do not silently replace the workflow's operator. The
treasury argument must likewise match the approved address. Policy, signed
artifact linkage, attestation, admission and deployment belong to services.

The token mints exactly `10^27` minor units (1 billion GRID, 18 decimals) to its
constructor caller, including when that caller is ProjectFactory. Neither
application constructor moves this supply. Launch liquidity and the protocol's
80% / 10% / 10% pool/swarm/IMD-treasury split are performed by the launch service
under its pinned policy, not by these contracts. The city's treasury fee is a
separate application payment. Pool settings are native ETH, no hook, fee 3000,
tick spacing 60; services apply the pinned opening-price policy.

## Purchasing and ownership

City IDs are `0..255`, with `x = id % 16`, `y = id / 16`. `buyCity(cityId)`
requires an empty plot, no city already owned by the caller, and at least 1000
GRID held before payment. The caller also needs sufficient GRID and allowance
for the full purchase. A wallet may own only one city, including plot zero;
`cityOf(wallet)` encodes `id + 1`, with zero meaning no city. Cities are
permanent and soulbound: no transfers, abandonment, resale or ownership recovery.
New cities have level 1 and zero resources. Multiple wallets are not prevented.

For `s = soldPlots` immediately before purchase:

```text
priceWei = 10000 × 10^18 × (256 + s)^2 / 65536
feeWei   = priceWei × 4 / 100
payment  = priceWei + feeWei
```

The complete base price goes to `address(0)`. Of the fee, 50% enters the City
Rewards pool, 30% the Resource Pot, 10% goes to `address(0)`, and 10% goes to
the treasury. Calculations use minor units, multiply before division, and
assign any split remainder to treasury; at the specified 256 prices these
splits are exact. The first purchase costs 10,000 + 400 GRID; its fee puts
200 in rewards, 120 in resources, 40 in the zero sink and 40 in treasury.

**Burn convention:** GRID remains a fixed nominal supply ERC-20. Transfers to
zero permanently lock tokens in the zero-address balance; they do not decrease
`totalSupply()`. That balance cannot transfer or approve tokens. Circulating
supply can be calculated as `totalSupply() - balanceOf(address(0))` if ignoring
other locked balances. This reconciles the workflow's zero-address burns with
the launch's fixed-supply token. The token has no transfer fees, transfer limits,
owner, pause, blocklist, mint-after-construction or burn-specific entry point.

Read `quote()` and approve exactly its total before buying. An intervening
purchase raises the price and causes an exact stale allowance to revert rather
than authorize a higher payment. A generous allowance permits the current
execution-time price. `price()` and `quote()` revert when all plots are sold.
Purchases are final; no refund/timeout mechanism applies to this registry.

## Rewards and leveling

City reward weight equals its current `level²`. A purchase's reward allocation
includes the newly purchased level-1 city. New cities receive none of the earlier
fees. The first buyer therefore earns the first purchase's 200 GRID reward share.

Rewards use a cumulative per-weight index with `10^27` precision. Leveling first
checkpoints rewards at the old weight; the higher weight applies only to future
fees. Owner-only `claimRewards(cityId)` pays accumulated GRID and keeps fractional
minor units for later claims. A zero claim reverts. Global distribution rounding
dust remains in `rewardsPool`; it cannot be withdrawn or reassigned. Thus the
pool's balance can exceed the sum of currently claimable whole minor units.

Resources are **18-decimal nontransferable game credits**: one resource is
`10^18` units, funded by one GRID. This conversion is an implementation assumption
because the workflow does not specify resource precision or conversion. Grants
debit `resourcePot`, increase a city's resources, and increase cumulative
`resourcesAllocated`. Backing GRID remains permanently locked in the registry,
even after resources are spent. It is not paid to winners or treasury, burned
again, made claimable, or recycled into either pot.

Owner-only `levelUp(cityId)` consumes `100 × (nextLevel)^2` resources: level 1→2
costs 400 resources (`400 × 10^18` units). The hard ceiling is level 20.
**The specified fee funding and 1:1 conversion cannot naturally reach that ceiling:**
all 256 purchases together fund 71,500.078125 resources. Reaching level 12 costs
64,900 cumulatively; level 13 requires 81,800 and level 20 requires 286,900.
Level 12 is therefore the maximum economically reachable even if all grants
favor one city. No supplemental funding or alternate conversion has been added.

The custody identity, absent unsolicited transfers, is:

```text
GRID.balanceOf(registry) = rewardsPool + resourcePot + resourcesAllocated
resourcesAllocated = outstanding city resources + all resources consumed
```

Direct token donations do not credit either pot and cannot be rescued. Do not
send GRID directly as a top-up. Only this project's plain GRID token is supported;
rebasing, fee-on-transfer, callback, and arbitrary substitute tokens are not
supported deployment configurations.

## Grants and heartbeat operation

The immutable operator alone can call the executor's grant methods and
`pauseGrants()` / `unpauseGrants()`. Each grant call supplies the registry address;
the executor forwards only the two defined grant selectors. This avoids circular
constructor dependencies and requires no post-deployment setup. Operators should
verify the intended registry address before each call.

Registry `grantResources(cityId, amount)` and `recordHeartbeat(id1, amount1, id2,
amount2, id3, amount3)` accept only the configured executor. Heartbeats atomically
grant three positive amounts to three distinct owned cities, then record winners,
amounts, sequence and timestamp for the site. Any invalid or unfunded grant
reverts the entire heartbeat and preserves the prior winners. Single grants
leave the latest heartbeat unchanged. Before the first heartbeat, its count is
zero; the default stored IDs are not valid winner announcements.

Pausing affects grants and heartbeats only. Buying, leveling, claiming, and GRID
transfers stay live. The operator may choose recipients and timing arbitrarily,
spend the entire remaining resource pot on favored cities, or stop grants
indefinitely. There is no automatic keeper, on-chain ranking, Twitter verification,
randomness, signed-message relay, or enforceable heartbeat schedule. Winner
selection and operating policy are off-chain responsibilities. A repeated
operator-authorized heartbeat is a new allocation, not an idempotent retry;
operators must confirm transaction receipts before resubmitting.

## Integration, validation and release responsibilities

JSON ABIs are in `docs/abi/`; `docs/abi/README.md` maps frontend reads and writes.
Regenerate them with `sh scripts/export-abi.sh`. The later frontend contribution
must use actual deployed Sepolia addresses, wallet connection and the workflow's
dark terminal grid and panel. No placeholder deployment address is presented here.

Unit/fuzz tests cover token conservation and allowances, purchase pricing and
all 256 plots, fees, ownership, grants, heartbeat atomicity, pause scope,
weighted rewards and level checkpoints. Adversarial tests cover token failures
at each transfer, callback rejection, claim rollback, factory deployment,
forbidden runtime opcodes and the synthetic level-20 boundary. Stateful invariant
tests mix buys, claims, grants, heartbeats, leveling and pausing while checking
custody, reward solvency, resource accounting and supply conservation.

A separate read-only agent reviewed the implementation during this contribution;
it found no confirmed exploit under the intended deployment and highlighted the
economic and configuration assumptions documented above. This is not the required
independent contributor review of accepted source plus the final manifest, and
is not a security audit. Slither and Mythril were not run. Foundry's guard-reset
reentrancy lint warnings and multiply-after-price-division warning were reviewed:
state is updated before checked transfers under an active guard, and exact price
arithmetic plus bounded reward rounding is exercised by tests.

Before release, the independent review must inspect source, accepted bytecode,
ABI and every privileged manifest argument, including the fixed workflow wallet
and resource assumptions. Services then publish source to GitHub, attest/admit,
deploy without contributor keys, verify deployed identities/source as applicable,
and supply the addresses for the frontend/IPFS publication. Those later service
outcomes are not prerequisites for this source assignment.
