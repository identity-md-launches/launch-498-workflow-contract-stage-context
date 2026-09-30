# Swarm Cities ABI integration

`LaunchToken.json`, `GrantExecutor.json` and `CityRegistry.json` are JSON ABI arrays
exported by Solidity 0.8.26 through `forge inspect`. Rebuild with
`sh scripts/export-abi.sh`; deployments use the source artifacts listed in the
root README, not JSON files as executable artifacts.

All GRID values, resource balances and grant amounts use 18 decimals. City IDs,
levels, weights, sequence numbers, coordinates and timestamps are unscaled.

| UI or operator action | Contract method | Notes |
| --- | --- | --- |
| Wallet balance and authorization | `LaunchToken.balanceOf`, `allowance`, `approve` | Approve the registry for the exact purchase total |
| Grid | `CityRegistry.cities(id)` | `(owner, level, resources)`; zero owner means empty; IDs 0..255 |
| Coordinates | `coordinates(id)` | `(x, y)` |
| Connected wallet's city | `cityOf(wallet)` | Zero means none; otherwise subtract one |
| Purchase quote | `quote()` | `(basePrice, fee, total)` in minor GRID; reverts when sold out |
| Buy | `buyCity(id)` | Transaction from buyer, after approval |
| Level requirements | `levelUpCost(id)` | Resource minor units; reverts at level20 or for an unowned city |
| Upgrade | `levelUp(id)` | Only the city owner |
| Rewards panel | `claimableRewards(id)`, `rewardsPool()` | Whole claimable minor units; pool also includes rounding dust |
| Claim | `claimRewards(id)` | Only owner; returns paid GRID amount; reverts if zero |
| Resource Pot panel | `resourcePot()` | Unallocated GRID, not total token balance of the registry |
| Historical resource backing | `resourcesAllocated()` | Cumulative permanent backing, includes spent resources |
| Last heartbeat | `heartbeatCount()`, `lastHeartbeatTimestamp()`, `lastHeartbeat(0..2)` | Ignore default winners when count=0; winner is `(cityId, amount)` |
| Check role and pause | `GrantExecutor.operator()`, `grantsPaused()` | Registry's `grantExecutor()` binds its executor |
| Individual grant | `GrantExecutor.grantResources(registry, id, amount)` | Only operator, positive resource minor units |
| Heartbeat | `GrantExecutor.recordHeartbeat(registry, id1, amount1, id2, amount2, id3, amount3)` | Only operator, three distinct owned cities, atomic |
| Pause or resume grants | `GrantExecutor.pauseGrants()`, `unpauseGrants()` | Only operator; other application functions stay live |

Registry event signatures (all integer arguments are `uint256`):

```solidity
CityBought(uint256 indexed cityId, address indexed owner, uint256 price, uint256 fee)
TaxTaken(address indexed payer, uint256 fee, uint256 rewards, uint256 resources, uint256 burned, uint256 treasuryAmount)
ResourcesGranted(uint256 indexed cityId, uint256 amount)
CityLeveled(uint256 indexed cityId, uint256 level, uint256 resourcesConsumed)
RewardsClaimed(uint256 indexed cityId, address indexed owner, uint256 amount)
HeartbeatRecorded(uint256 indexed sequence, uint256 cityId1, uint256 amount1, uint256 cityId2, uint256 amount2, uint256 cityId3, uint256 amount3)
```

`TaxTaken.burned` is only the fee's burn share; `CityBought.price` is also sent
to the zero sink. A heartbeat emits three `ResourcesGranted` events plus one
`HeartbeatRecorded`; do not double-count grants. The executor emits
`GrantsPauseChanged(bool paused)`. The token emits standard ERC-20 `Transfer` and
`Approval`. No event proves an off-chain ranking or tweet. Refresh state after
confirmed receipts and account for chain reorganizations when indexing events.
