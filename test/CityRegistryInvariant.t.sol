// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {CityRegistry} from "../src/CityRegistry.sol";
import {GrantExecutor} from "../src/GrantExecutor.sol";

/// @dev Valid-action handler: unexpected reverts fail the configured invariant campaign.
contract CityRegistryHandler is Test {
    LaunchToken public immutable token;
    CityRegistry public immutable registry;
    GrantExecutor public immutable executor;
    uint256[] public ownedIds;
    uint256 public rewardsFunded;
    uint256 public resourcesFunded;
    uint256 public rewardsClaimed;
    uint256 public resourcesSpent;
    uint256 public sinkReceipts;
    uint256 public treasuryReceipts;

    constructor(LaunchToken token_, CityRegistry registry_, GrantExecutor executor_) {
        token = token_;
        registry = registry_;
        executor = executor_;
    }

    function actor(uint256 cityId) public pure returns (address) {
        return address(uint160(0x10000 + cityId));
    }

    function buy(uint256 citySeed) public {
        if (ownedIds.length == 256) return;
        uint256 cityId = citySeed % 256;
        (address existing,,) = registry.cities(cityId);
        while (existing != address(0)) {
            cityId = (cityId + 1) % 256;
            (existing,,) = registry.cities(cityId);
        }

        (uint256 price, uint256 fee, uint256 total) = registry.quote();
        address buyer = actor(cityId);
        // Exact funding leaves all balances in the finite set checked by the invariant.
        token.transfer(buyer, total);
        vm.startPrank(buyer);
        token.approve(address(registry), total);
        registry.buyCity(cityId);
        vm.stopPrank();
        ownedIds.push(cityId);

        uint256 rewards = fee * 50 / 100;
        uint256 resources = fee * 30 / 100;
        uint256 burnedFee = fee * 10 / 100;
        rewardsFunded += rewards;
        resourcesFunded += resources;
        sinkReceipts += price + burnedFee;
        treasuryReceipts += fee - rewards - resources - burnedFee;
    }

    function grant(uint256 citySeed, uint256 amountSeed) public {
        uint256 pot = registry.resourcePot();
        if (executor.grantsPaused() || ownedIds.length == 0 || pot == 0) return;
        uint256 cityId = ownedIds[citySeed % ownedIds.length];
        uint256 amount = bound(amountSeed, 1, pot);
        (, uint256 level, uint256 resources) = registry.cities(cityId);
        // Half the choices prioritize an affordable upgrade, ensuring weight changes are explored.
        if (amountSeed % 2 == 0 && level < 20) {
            uint256 cost = 100 ether * (level + 1) * (level + 1);
            if (resources < cost && cost - resources <= pot) amount = cost - resources;
        }
        vm.prank(executor.operator());
        executor.grantResources(address(registry), cityId, amount);
    }

    function heartbeat(uint256 citySeed, uint256 firstSeed, uint256 secondSeed, uint256 thirdSeed) public {
        uint256 pot = registry.resourcePot();
        uint256 count = ownedIds.length;
        if (executor.grantsPaused() || count < 3 || pot < 3) return;
        uint256 start = citySeed % count;
        uint256 amount1 = bound(firstSeed, 1, pot - 2);
        uint256 amount2 = bound(secondSeed, 1, pot - amount1 - 1);
        uint256 amount3 = bound(thirdSeed, 1, pot - amount1 - amount2);
        vm.prank(executor.operator());
        executor.recordHeartbeat(
            address(registry),
            ownedIds[start],
            amount1,
            ownedIds[(start + 1) % count],
            amount2,
            ownedIds[(start + 2) % count],
            amount3
        );
    }

    function levelUp(uint256 citySeed) public {
        if (ownedIds.length == 0) return;
        uint256 cityId = ownedIds[citySeed % ownedIds.length];
        (address owner, uint256 level, uint256 resources) = registry.cities(cityId);
        if (level == 20) return;
        uint256 cost = 100 ether * (level + 1) * (level + 1);
        if (resources < cost) return;
        vm.prank(owner);
        registry.levelUp(cityId);
        resourcesSpent += cost;
    }

    function claim(uint256 citySeed) public {
        if (ownedIds.length == 0) return;
        uint256 cityId = ownedIds[citySeed % ownedIds.length];
        uint256 expected = registry.claimableRewards(cityId);
        if (expected == 0) return;
        (address owner,,) = registry.cities(cityId);
        uint256 balanceBefore = token.balanceOf(owner);
        vm.prank(owner);
        uint256 paid = registry.claimRewards(cityId);
        assertEq(paid, expected);
        assertEq(token.balanceOf(owner) - balanceBefore, paid);
        rewardsClaimed += paid;
    }

    function setPaused(bool paused) public {
        if (executor.grantsPaused() == paused) return;
        vm.prank(executor.operator());
        if (paused) executor.pauseGrants();
        else executor.unpauseGrants();
    }
}

contract CityRegistryInvariantTest is Test {
    LaunchToken private token;
    GrantExecutor private executor;
    CityRegistry private registry;
    CityRegistryHandler private handler;
    address private constant OPERATOR = 0x5b95A971B4583A5f011E9DA082acdD679b870D06;

    function setUp() public {
        token = new LaunchToken();
        executor = new GrantExecutor(OPERATOR);
        registry = new CityRegistry(address(token), address(executor), OPERATOR);
        handler = new CityRegistryHandler(token, registry, executor);
        token.transfer(address(handler), token.totalSupply());

        // Start with all action types enabled and a changed reward weight.
        for (uint256 i; i < 8; ++i) {
            handler.buy(i);
        }
        handler.grant(0, 0);
        handler.levelUp(0);

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.grant.selector;
        selectors[2] = handler.heartbeat.selector;
        selectors[3] = handler.levelUp.selector;
        selectors[4] = handler.claim.selector;
        selectors[5] = handler.setPaused.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariantCustodyOwnershipWeightsAndConservation() public view {
        uint256 weight;
        uint256 count;
        uint256 outstandingRewards;
        uint256 unspentResources;
        uint256 spentByLevel;
        uint256 holderBalances;
        for (uint256 cityId; cityId < 256; ++cityId) {
            address actor = handler.actor(cityId);
            holderBalances += token.balanceOf(actor);
            (address owner, uint256 level, uint256 resources) = registry.cities(cityId);
            if (owner == address(0)) {
                assertEq(level, 0);
                assertEq(resources, 0);
                assertEq(registry.cityOf(actor), 0);
                continue;
            }
            assertEq(owner, actor);
            assertEq(registry.cityOf(owner), cityId + 1);
            assertGe(level, 1);
            assertLe(level, 20);
            ++count;
            weight += level * level;
            unspentResources += resources;
            outstandingRewards += registry.claimableRewards(cityId);
            // Independently reconstruct every upgrade cost from the present level.
            spentByLevel += 100 ether * (level * (level + 1) * (2 * level + 1) / 6 - 1);
        }

        assertEq(registry.soldPlots(), count);
        assertLe(count, 256);
        assertEq(registry.totalWeight(), weight);
        assertLe(outstandingRewards, registry.rewardsPool());
        assertEq(handler.rewardsClaimed() + registry.rewardsPool(), handler.rewardsFunded());
        assertEq(registry.resourcePot() + registry.resourcesAllocated(), handler.resourcesFunded());
        assertEq(unspentResources + handler.resourcesSpent(), registry.resourcesAllocated());
        assertEq(spentByLevel, handler.resourcesSpent());
        assertEq(
            token.balanceOf(address(registry)),
            registry.rewardsPool() + registry.resourcePot() + registry.resourcesAllocated()
        );
        assertEq(token.balanceOf(address(0)), handler.sinkReceipts());
        assertEq(token.balanceOf(OPERATOR), handler.treasuryReceipts());
        assertEq(token.totalSupply(), 1e27);
        assertEq(
            holderBalances + token.balanceOf(address(handler)) + token.balanceOf(address(registry))
                + token.balanceOf(OPERATOR) + token.balanceOf(address(0)),
            token.totalSupply()
        );
    }
}
