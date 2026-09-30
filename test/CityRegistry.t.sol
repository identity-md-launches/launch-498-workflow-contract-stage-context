// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {CityRegistry} from "../src/CityRegistry.sol";
import {GrantExecutor} from "../src/GrantExecutor.sol";

contract CityRegistryTest is Test {
    LaunchToken private token;
    GrantExecutor private executor;
    CityRegistry private registry;

    address private constant OPERATOR = 0x5b95A971B4583A5f011E9DA082acdD679b870D06;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    uint256 private constant UNIT = 1e18;

    event CityBought(uint256 indexed cityId, address indexed owner, uint256 price, uint256 fee);
    event TaxTaken(
        address indexed payer, uint256 fee, uint256 rewards, uint256 resources, uint256 burned, uint256 treasuryAmount
    );
    event ResourcesGranted(uint256 indexed cityId, uint256 amount);
    event CityLeveled(uint256 indexed cityId, uint256 level, uint256 resourcesConsumed);
    event RewardsClaimed(uint256 indexed cityId, address indexed owner, uint256 amount);
    event HeartbeatRecorded(
        uint256 indexed sequence,
        uint256 cityId1,
        uint256 amount1,
        uint256 cityId2,
        uint256 amount2,
        uint256 cityId3,
        uint256 amount3
    );

    function setUp() public {
        token = new LaunchToken();
        executor = new GrantExecutor(OPERATOR);
        registry = new CityRegistry(address(token), address(executor), OPERATOR);
    }

    function testConstructorsLeaveLaunchSupplyAtDeployer() public view {
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.balanceOf(address(registry)), 0);
        assertEq(token.balanceOf(address(executor)), 0);
        assertEq(token.balanceOf(OPERATOR), 0);
        assertEq(executor.operator(), OPERATOR);
        assertFalse(executor.grantsPaused());
        assertEq(registry.soldPlots(), 0);
        assertEq(registry.totalWeight(), 0);
        assertEq(registry.rewardsPool(), 0);
        assertEq(registry.resourcePot(), 0);
    }

    function testFirstPurchaseExactSplitAndPlotZeroOwnership() public {
        (uint256 basePrice, uint256 fee, uint256 total) = registry.quote();
        assertEq(basePrice, 10_000 * UNIT);
        assertEq(fee, 400 * UNIT);
        assertEq(total, 10_400 * UNIT);
        _fundAndApprove(ALICE, total);
        vm.expectEmit(true, true, false, true, address(registry));
        emit CityBought(0, ALICE, basePrice, fee);
        vm.expectEmit(true, false, false, true, address(registry));
        emit TaxTaken(ALICE, fee, 200 * UNIT, 120 * UNIT, 40 * UNIT, 40 * UNIT);
        vm.prank(ALICE);
        registry.buyCity(0);

        (address owner, uint256 level, uint256 resources) = registry.cities(0);
        assertEq(owner, ALICE);
        assertEq(level, 1);
        assertEq(resources, 0);
        assertEq(registry.cityOf(ALICE), 1, "zero plot needs an unambiguous owner sentinel");
        assertEq(registry.cityOf(BOB), 0);
        assertEq(registry.soldPlots(), 1);
        assertEq(registry.totalWeight(), 1);
        assertEq(registry.rewardsPool(), 200 * UNIT);
        assertEq(registry.resourcePot(), 120 * UNIT);
        assertEq(registry.claimableRewards(0), 200 * UNIT);
        assertEq(token.balanceOf(address(registry)), 320 * UNIT);
        assertEq(token.balanceOf(OPERATOR), 40 * UNIT);
        assertEq(token.balanceOf(address(0)), 10_040 * UNIT);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.totalSupply(), 1e27);
        _assertBacking();
    }

    function testPricesUseExistingSalesAndSmallestTokenUnits() public {
        for (uint256 i; i < 12; ++i) {
            uint256 expected = 10_000 * UNIT * (256 + i) ** 2 / 65_536;
            (uint256 basePrice, uint256 fee, uint256 total) = registry.quote();
            assertEq(registry.price(), expected);
            assertEq(basePrice, expected);
            assertEq(fee, expected * 4 / 100);
            assertEq(total, expected + fee);
            _buy(_buyer(i), i);
        }
    }

    function testCoordinatesCoverAllPlots() public view {
        for (uint256 i; i < 256; ++i) {
            (uint256 x, uint256 y) = registry.coordinates(i);
            assertEq(x, i % 16);
            assertEq(y, i / 16);
        }
    }

    function testInvalidPlotCannotBeBoughtOrMapped() public {
        _fundAndApprove(ALICE, 20_000 * UNIT);
        vm.expectRevert(CityRegistry.InvalidCity.selector);
        vm.prank(ALICE);
        registry.buyCity(256);
        vm.expectRevert(CityRegistry.InvalidCity.selector);
        registry.coordinates(256);
        assertEq(registry.soldPlots(), 0);
        assertEq(token.balanceOf(ALICE), 20_000 * UNIT);
    }

    function testRequiresAtLeastOneThousandGridBeforePaying() public {
        _fundAndApprove(ALICE, 999 * UNIT);
        vm.expectRevert(CityRegistry.InsufficientHolding.selector);
        vm.prank(ALICE);
        registry.buyCity(0);
        assertEq(token.balanceOf(ALICE), 999 * UNIT);
        assertEq(registry.soldPlots(), 0);
    }

    function testInsufficientPaymentAndAllowanceRollbackEverything() public {
        _fundAndApprove(ALICE, 10_399 * UNIT);
        vm.expectRevert();
        vm.prank(ALICE);
        registry.buyCity(0);
        token.transfer(BOB, 10_400 * UNIT);
        vm.expectRevert();
        vm.prank(BOB);
        registry.buyCity(1);
        assertEq(token.balanceOf(ALICE), 10_399 * UNIT);
        assertEq(token.balanceOf(BOB), 10_400 * UNIT);
        assertEq(token.balanceOf(address(registry)), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(OPERATOR), 0);
        assertEq(registry.soldPlots(), 0);
        assertEq(registry.totalWeight(), 0);
        assertEq(registry.rewardsPool(), 0);
        assertEq(registry.cityOf(ALICE), 0);
        assertEq(registry.cityOf(BOB), 0);
    }

    function testOwnedPlotAndSecondCityAreRejectedIncludingPlotZeroOwner() public {
        _buy(ALICE, 0);
        _fundAndApprove(BOB, 50_000 * UNIT);
        _fundAndApprove(ALICE, 50_000 * UNIT);
        vm.expectRevert(CityRegistry.CityOccupied.selector);
        vm.prank(BOB);
        registry.buyCity(0);
        vm.expectRevert(CityRegistry.AlreadyOwnsCity.selector);
        vm.prank(ALICE);
        registry.buyCity(1);
        assertEq(registry.soldPlots(), 1);
        assertEq(registry.cityOf(ALICE), 1);
        assertEq(registry.cityOf(BOB), 0);
    }

    function testAll256PlotsCanSellWithExactAccounting() public {
        uint256 totalBurn;
        uint256 totalTreasury;
        uint256 totalRewards;
        uint256 totalResources;
        for (uint256 i; i < 256; ++i) {
            (uint256 basePrice, uint256 fee,) = registry.quote();
            totalBurn += basePrice + fee / 10;
            totalTreasury += fee / 10;
            totalRewards += fee / 2;
            totalResources += fee * 3 / 10;
            _buy(_buyer(i), i);
        }
        assertEq(registry.soldPlots(), 256);
        vm.expectRevert(CityRegistry.SoldOut.selector);
        registry.price();
        vm.expectRevert(CityRegistry.SoldOut.selector);
        registry.quote();
        assertEq(registry.totalWeight(), 256);
        assertEq(registry.rewardsPool(), totalRewards);
        assertEq(registry.resourcePot(), totalResources);
        assertEq(token.balanceOf(address(0)), totalBurn);
        assertEq(token.balanceOf(OPERATOR), totalTreasury);
        assertEq(token.balanceOf(address(this)) + totalBurn + totalTreasury + totalRewards + totalResources, 1e27);
        _assertBacking();

        _fundAndApprove(ALICE, 100_000 * UNIT);
        vm.expectRevert();
        vm.prank(ALICE);
        registry.buyCity(0);
        vm.expectRevert();
        vm.prank(ALICE);
        registry.buyCity(256);
        assertEq(registry.soldPlots(), 256);
    }

    function testNewCityReceivesItsPurchaseFeeButNoEarlierRewards() public {
        _buy(ALICE, 0);
        (, uint256 secondFee,) = registry.quote();
        _buy(BOB, 1);
        assertEq(registry.claimableRewards(0), 200 * UNIT + secondFee / 4);
        assertEq(registry.claimableRewards(1), secondFee / 4);
        assertEq(registry.totalWeight(), 2);

        vm.prank(BOB);
        uint256 bobClaim = registry.claimRewards(1);
        assertEq(bobClaim, secondFee / 4);
        assertEq(token.balanceOf(BOB), bobClaim);
        assertEq(registry.claimableRewards(1), 0);
        assertEq(registry.rewardsPool(), 200 * UNIT + secondFee / 4);
        _assertBacking();
    }

    function testOnlyCityOwnerCanLevelOrClaim() public {
        _buy(ALICE, 0);
        vm.expectRevert(CityRegistry.NotCityOwner.selector);
        vm.prank(BOB);
        registry.claimRewards(0);
        vm.expectRevert(CityRegistry.NotCityOwner.selector);
        vm.prank(BOB);
        registry.levelUp(0);
        vm.expectRevert(CityRegistry.CityUnowned.selector);
        vm.prank(ALICE);
        registry.claimRewards(1);
        vm.expectRevert(CityRegistry.CityUnowned.selector);
        vm.prank(ALICE);
        registry.levelUp(1);
        assertEq(registry.claimableRewards(0), 200 * UNIT);
        assertEq(token.balanceOf(BOB), 0);
    }

    function testClaimTransfersOnlyAccruedRewardsAndNeverResourceBacking() public {
        _buy(ALICE, 0);
        vm.expectEmit(true, true, false, true, address(registry));
        emit RewardsClaimed(0, ALICE, 200 * UNIT);
        vm.prank(ALICE);
        assertEq(registry.claimRewards(0), 200 * UNIT);
        assertEq(token.balanceOf(ALICE), 200 * UNIT);
        assertEq(registry.rewardsPool(), 0);
        assertEq(registry.resourcePot(), 120 * UNIT);
        assertEq(token.balanceOf(address(registry)), 120 * UNIT);
        assertEq(registry.claimableRewards(0), 0);
        vm.expectRevert(CityRegistry.NothingToClaim.selector);
        vm.prank(ALICE);
        registry.claimRewards(0);
        _assertBacking();
    }

    function testOnlyExecutorCanGrantOrRecordHeartbeat() public {
        _buy(ALICE, 0);
        vm.expectRevert(CityRegistry.Unauthorized.selector);
        registry.grantResources(0, UNIT);
        vm.expectRevert(CityRegistry.Unauthorized.selector);
        vm.prank(OPERATOR);
        registry.grantResources(0, UNIT);
        vm.expectRevert(CityRegistry.Unauthorized.selector);
        registry.recordHeartbeat(0, UNIT, 1, UNIT, 2, UNIT);
        assertEq(registry.resourcePot(), 120 * UNIT);
    }

    function testGrantDebitsPotAndKeepsTokensBackingTheResourceAllocation() public {
        _buy(ALICE, 0);
        vm.expectEmit(true, false, false, true, address(registry));
        emit ResourcesGranted(0, 90 * UNIT);
        vm.prank(OPERATOR);
        executor.grantResources(address(registry), 0, 90 * UNIT);
        (, uint256 level, uint256 resources) = registry.cities(0);
        assertEq(level, 1);
        assertEq(resources, 90 * UNIT);
        assertEq(registry.resourcePot(), 30 * UNIT);
        assertEq(registry.resourcesAllocated(), 90 * UNIT);
        assertEq(token.balanceOf(address(registry)), 320 * UNIT);
        assertEq(registry.rewardsPool(), 200 * UNIT);
        assertEq(token.balanceOf(ALICE), 0);
        _assertBacking();
    }

    function testGrantCannotExceedPotOrTargetUnownedPlot() public {
        _buy(ALICE, 0);
        vm.startPrank(OPERATOR);
        vm.expectRevert(CityRegistry.InsufficientResourcePot.selector);
        executor.grantResources(address(registry), 0, 120 * UNIT + 1);
        vm.expectRevert(CityRegistry.CityUnowned.selector);
        executor.grantResources(address(registry), 1, UNIT);
        vm.expectRevert(CityRegistry.InvalidCity.selector);
        executor.grantResources(address(registry), 256, UNIT);
        vm.stopPrank();
        (,, uint256 resources) = registry.cities(0);
        assertEq(resources, 0);
        assertEq(registry.resourcePot(), 120 * UNIT);
        assertEq(registry.resourcesAllocated(), 0);
        _assertBacking();
    }

    function testLevelUpConsumesSquareCostAndIncreasesSquareWeight() public {
        _buy(ALICE, 0);
        for (uint256 i = 1; i < 12; ++i) {
            _buy(_buyer(i), i);
        }
        assertEq(registry.levelUpCost(0), 400 * UNIT);
        vm.prank(OPERATOR);
        executor.grantResources(address(registry), 0, 1_300 * UNIT);
        uint256 unclaimed = registry.claimableRewards(0);
        vm.expectEmit(true, false, false, true, address(registry));
        emit CityLeveled(0, 2, 400 * UNIT);
        vm.prank(ALICE);
        registry.levelUp(0);
        (, uint256 level, uint256 resources) = registry.cities(0);
        assertEq(level, 2);
        assertEq(resources, 900 * UNIT);
        assertEq(registry.levelUpCost(0), 900 * UNIT);
        assertEq(registry.totalWeight(), 15);
        assertEq(registry.claimableRewards(0), unclaimed, "new weight must not rewrite past rewards");
        vm.prank(ALICE);
        registry.levelUp(0);
        (, level, resources) = registry.cities(0);
        assertEq(level, 3);
        assertEq(resources, 0);
        assertEq(registry.levelUpCost(0), 1_600 * UNIT);
        assertEq(registry.totalWeight(), 20);
        assertEq(registry.resourcesAllocated(), 1_300 * UNIT, "spent resources retain token backing");
        _assertBacking();
    }

    function testInsufficientResourcesCannotLevelAndLeavesRewardsUnchanged() public {
        _buy(ALICE, 0);
        vm.prank(OPERATOR);
        executor.grantResources(address(registry), 0, 120 * UNIT);
        vm.expectRevert(CityRegistry.InsufficientResources.selector);
        vm.prank(ALICE);
        registry.levelUp(0);
        (, uint256 level, uint256 resources) = registry.cities(0);
        assertEq(level, 1);
        assertEq(resources, 120 * UNIT);
        assertEq(registry.totalWeight(), 1);
        assertEq(registry.claimableRewards(0), 200 * UNIT);
    }

    function testFutureFeesUseNewWeightWithoutRetroactiveRewards() public {
        _buy(ALICE, 0);
        for (uint256 i = 1; i < 4; ++i) {
            _buy(_buyer(i), i);
        }
        uint256 beforeAlice = registry.claimableRewards(0);
        uint256 beforeBob = registry.claimableRewards(1);
        vm.prank(OPERATOR);
        executor.grantResources(address(registry), 0, 400 * UNIT);
        vm.prank(ALICE);
        registry.levelUp(0);
        assertEq(registry.claimableRewards(0), beforeAlice);
        assertEq(registry.claimableRewards(1), beforeBob);
        assertEq(registry.totalWeight(), 7);

        (, uint256 fee,) = registry.quote();
        _buy(BOB, 4);
        uint256 share = (fee / 2) / 8;
        assertApproxEqAbs(registry.claimableRewards(0), beforeAlice + share * 4, 4);
        assertApproxEqAbs(registry.claimableRewards(1), beforeBob + share, 1);
        assertApproxEqAbs(registry.claimableRewards(4), share, 1);
        assertEq(registry.totalWeight(), 8);
        _assertBacking();
    }

    function testHeartbeatGrantsThreeWinnersAndPublishesLatestBatch() public {
        for (uint256 i; i < 3; ++i) {
            _buy(_buyer(i), i);
        }
        uint256 potBefore = registry.resourcePot();
        vm.warp(123_456);
        vm.expectEmit(true, false, false, true, address(registry));
        emit HeartbeatRecorded(1, 2, 30 * UNIT, 0, 20 * UNIT, 1, 10 * UNIT);
        vm.prank(OPERATOR);
        executor.recordHeartbeat(address(registry), 2, 30 * UNIT, 0, 20 * UNIT, 1, 10 * UNIT);
        assertEq(registry.heartbeatCount(), 1);
        assertEq(registry.lastHeartbeatTimestamp(), 123_456);
        (uint256 id, uint256 amount) = registry.lastHeartbeat(0);
        assertEq(id, 2);
        assertEq(amount, 30 * UNIT);
        (id, amount) = registry.lastHeartbeat(1);
        assertEq(id, 0);
        assertEq(amount, 20 * UNIT);
        (id, amount) = registry.lastHeartbeat(2);
        assertEq(id, 1);
        assertEq(amount, 10 * UNIT);
        (,, uint256 resource0) = registry.cities(0);
        (,, uint256 resource1) = registry.cities(1);
        (,, uint256 resource2) = registry.cities(2);
        assertEq(resource0, 20 * UNIT);
        assertEq(resource1, 10 * UNIT);
        assertEq(resource2, 30 * UNIT);
        assertEq(registry.resourcePot(), potBefore - 60 * UNIT);
        assertEq(registry.resourcesAllocated(), 60 * UNIT);

        vm.warp(123_457);
        vm.prank(OPERATOR);
        executor.recordHeartbeat(address(registry), 0, UNIT, 1, 2 * UNIT, 2, 3 * UNIT);
        assertEq(registry.heartbeatCount(), 2);
        assertEq(registry.lastHeartbeatTimestamp(), 123_457);
        (id, amount) = registry.lastHeartbeat(0);
        assertEq(id, 0);
        assertEq(amount, UNIT);
        _assertBacking();
    }

    function testHeartbeatFailureRollsBackAllThreeGrantsAndStoredWinners() public {
        for (uint256 i; i < 3; ++i) {
            _buy(_buyer(i), i);
        }
        uint256 pot = registry.resourcePot();
        vm.startPrank(OPERATOR);
        vm.expectRevert(CityRegistry.CityUnowned.selector);
        executor.recordHeartbeat(address(registry), 0, UNIT, 1, UNIT, 3, UNIT);
        vm.expectRevert(CityRegistry.InsufficientResourcePot.selector);
        executor.recordHeartbeat(address(registry), 0, UNIT, 1, UNIT, 2, pot);
        vm.stopPrank();
        for (uint256 i; i < 3; ++i) {
            (,, uint256 resources) = registry.cities(i);
            (uint256 winner, uint256 amount) = registry.lastHeartbeat(i);
            assertEq(resources, 0);
            assertEq(winner, 0);
            assertEq(amount, 0);
        }
        assertEq(registry.resourcePot(), pot);
        assertEq(registry.resourcesAllocated(), 0);
        assertEq(registry.heartbeatCount(), 0);
        assertEq(registry.lastHeartbeatTimestamp(), 0);
        _assertBacking();
    }

    function testOnlyConfiguredOperatorControlsExecutor() public {
        _buy(ALICE, 0);
        vm.expectRevert(GrantExecutor.Unauthorized.selector);
        executor.pauseGrants();
        vm.expectRevert(GrantExecutor.Unauthorized.selector);
        vm.prank(ALICE);
        executor.grantResources(address(registry), 0, UNIT);
        vm.expectRevert(GrantExecutor.Unauthorized.selector);
        executor.recordHeartbeat(address(registry), 0, UNIT, 1, UNIT, 2, UNIT);
        vm.prank(OPERATOR);
        executor.pauseGrants();
        vm.expectRevert(GrantExecutor.Unauthorized.selector);
        executor.unpauseGrants();
        assertTrue(executor.grantsPaused());
    }

    function testPausingGrantsKeepsPurchasesClaimsAndLevelUpsLive() public {
        _buy(ALICE, 0);
        for (uint256 i = 1; i < 4; ++i) {
            _buy(_buyer(i), i);
        }
        vm.startPrank(OPERATOR);
        executor.grantResources(address(registry), 0, 400 * UNIT);
        executor.pauseGrants();
        vm.expectRevert(GrantExecutor.GrantsPaused.selector);
        executor.grantResources(address(registry), 0, UNIT);
        vm.expectRevert(GrantExecutor.GrantsPaused.selector);
        executor.recordHeartbeat(address(registry), 0, UNIT, 1, UNIT, 2, UNIT);
        vm.stopPrank();
        _buy(BOB, 4);
        vm.startPrank(ALICE);
        registry.levelUp(0);
        uint256 paid = registry.claimRewards(0);
        vm.stopPrank();
        assertGt(paid, 0);
        assertEq(token.balanceOf(ALICE), paid);
        assertEq(registry.soldPlots(), 5);
        assertTrue(executor.grantsPaused());
        vm.prank(OPERATOR);
        executor.unpauseGrants();
        vm.prank(OPERATOR);
        executor.grantResources(address(registry), 0, UNIT);
        assertFalse(executor.grantsPaused());
        _assertBacking();
    }

    function testTokenDonationsDoNotCreateSpendableRewardsOrResources() public {
        _buy(ALICE, 0);
        token.transfer(address(registry), 10_000 * UNIT);
        assertEq(registry.rewardsPool(), 200 * UNIT);
        assertEq(registry.resourcePot(), 120 * UNIT);
        assertEq(registry.claimableRewards(0), 200 * UNIT);
        vm.expectRevert();
        vm.prank(OPERATOR);
        executor.grantResources(address(registry), 0, 121 * UNIT);
        vm.prank(ALICE);
        registry.claimRewards(0);
        assertEq(token.balanceOf(address(registry)), 10_120 * UNIT);
    }

    function testDuplicateOrZeroHeartbeatAwardsRevertWithoutAllocating() public {
        for (uint256 i; i < 3; ++i) {
            _buy(_buyer(i), i);
        }
        uint256 pot = registry.resourcePot();
        vm.startPrank(OPERATOR);
        vm.expectRevert(CityRegistry.DuplicateWinner.selector);
        executor.recordHeartbeat(address(registry), 0, UNIT, 0, UNIT, 2, UNIT);
        vm.expectRevert(CityRegistry.DuplicateWinner.selector);
        executor.recordHeartbeat(address(registry), 0, UNIT, 1, UNIT, 0, UNIT);
        vm.expectRevert(CityRegistry.DuplicateWinner.selector);
        executor.recordHeartbeat(address(registry), 0, UNIT, 1, UNIT, 1, UNIT);
        vm.expectRevert(CityRegistry.InvalidAmount.selector);
        executor.recordHeartbeat(address(registry), 0, UNIT, 1, UNIT, 2, 0);
        vm.expectRevert(CityRegistry.InvalidAmount.selector);
        executor.grantResources(address(registry), 0, 0);
        vm.stopPrank();
        assertEq(registry.resourcePot(), pot);
        assertEq(registry.resourcesAllocated(), 0);
        assertEq(registry.heartbeatCount(), 0);
        for (uint256 i; i < 3; ++i) {
            (,, uint256 resources) = registry.cities(i);
            assertEq(resources, 0);
        }
        _assertBacking();
    }

    function testPauseTransitionsCannotBeRepeated() public {
        vm.startPrank(OPERATOR);
        vm.expectRevert(GrantExecutor.NotPaused.selector);
        executor.unpauseGrants();
        executor.pauseGrants();
        vm.expectRevert(GrantExecutor.AlreadyPaused.selector);
        executor.pauseGrants();
        executor.unpauseGrants();
        vm.expectRevert(GrantExecutor.NotPaused.selector);
        executor.unpauseGrants();
        vm.stopPrank();
        assertFalse(executor.grantsPaused());
    }

    function testExecutorRejectsRegistryWithoutCode() public {
        vm.startPrank(OPERATOR);
        vm.expectRevert(GrantExecutor.InvalidRegistry.selector);
        executor.grantResources(ALICE, 0, UNIT);
        vm.expectRevert(GrantExecutor.InvalidRegistry.selector);
        executor.recordHeartbeat(address(0), 0, UNIT, 1, UNIT, 2, UNIT);
        vm.stopPrank();
    }

    function testConstructorRejectsMissingDependenciesOrRoles() public {
        vm.expectRevert(GrantExecutor.InvalidOperator.selector);
        new GrantExecutor(address(0));
        vm.expectRevert(CityRegistry.InvalidConfiguration.selector);
        new CityRegistry(address(0), address(executor), OPERATOR);
        vm.expectRevert(CityRegistry.InvalidConfiguration.selector);
        new CityRegistry(address(token), address(0), OPERATOR);
        vm.expectRevert(CityRegistry.InvalidConfiguration.selector);
        new CityRegistry(address(token), ALICE, OPERATOR);
        vm.expectRevert(CityRegistry.InvalidConfiguration.selector);
        new CityRegistry(address(token), address(executor), address(0));
    }

    function testFrequentClaimsRetainFractionalRewardsAcrossLevelCheckpoints() public {
        _buy(ALICE, 0);
        uint256 snapshot = vm.snapshotState();
        uint256 frequentlyClaimed;
        for (uint256 i = 1; i < 16; ++i) {
            _buy(_buyer(i), i);
            vm.prank(ALICE);
            frequentlyClaimed += registry.claimRewards(0);
            if (i == 4) {
                vm.prank(OPERATOR);
                executor.grantResources(address(registry), 0, 400 * UNIT);
                vm.prank(ALICE);
                registry.levelUp(0);
            }
        }
        assertTrue(vm.revertToState(snapshot));
        for (uint256 i = 1; i < 16; ++i) {
            _buy(_buyer(i), i);
            if (i == 4) {
                vm.prank(OPERATOR);
                executor.grantResources(address(registry), 0, 400 * UNIT);
                vm.prank(ALICE);
                registry.levelUp(0);
            }
        }
        vm.prank(ALICE);
        uint256 onceClaimed = registry.claimRewards(0);
        assertEq(frequentlyClaimed, onceClaimed, "claim timing must not discard fractional entitlement");
        _assertBacking();
    }

    function testSoulboundCityHasNoTransferEntryPoint() public {
        _buy(ALICE, 0);
        vm.startPrank(ALICE);
        (bool transferSuccess,) =
            address(registry).call(abi.encodeWithSignature("transferCity(uint256,address)", 0, BOB));
        (bool nftTransferSuccess,) =
            address(registry).call(abi.encodeWithSignature("transferFrom(address,address,uint256)", ALICE, BOB, 0));
        vm.stopPrank();
        assertFalse(transferSuccess);
        assertFalse(nftTransferSuccess);
        (address owner,,) = registry.cities(0);
        assertEq(owner, ALICE);
        assertEq(registry.cityOf(ALICE), 1);
        assertEq(registry.cityOf(BOB), 0);
    }

    function testFuzzPartialGrantAndClaimConserveBacking(uint256 allocation) public {
        _buy(ALICE, 0);
        allocation = bound(allocation, 1, 120 * UNIT);
        vm.prank(OPERATOR);
        executor.grantResources(address(registry), 0, allocation);
        vm.prank(ALICE);
        registry.claimRewards(0);
        assertEq(registry.resourcePot(), 120 * UNIT - allocation);
        assertEq(registry.resourcesAllocated(), allocation);
        assertEq(token.balanceOf(ALICE), 200 * UNIT);
        assertEq(token.balanceOf(address(registry)), 120 * UNIT);
        _assertBacking();
    }

    function testFuzzManyOwnersCannotClaimMoreThanCollectedFees(uint8 countSeed) public {
        uint256 count = bound(uint256(countSeed), 1, 32);
        uint256 collected;
        for (uint256 i; i < count; ++i) {
            (, uint256 fee,) = registry.quote();
            collected += fee / 2;
            _buy(_buyer(i), i);
        }
        uint256 paid;
        for (uint256 i; i < count; ++i) {
            uint256 owed = registry.claimableRewards(i);
            vm.prank(_buyer(i));
            uint256 received = registry.claimRewards(i);
            assertEq(received, owed);
            assertEq(token.balanceOf(_buyer(i)), received);
            assertEq(registry.claimableRewards(i), 0);
            paid += received;
        }
        assertLe(paid, collected);
        assertEq(registry.rewardsPool(), collected - paid);
        assertLe(collected - paid, count, "only sub-wei reward dust should remain");
        _assertBacking();
    }

    function _buy(address buyer, uint256 cityId) private {
        (,, uint256 total) = registry.quote();
        _fundAndApprove(buyer, total);
        vm.prank(buyer);
        registry.buyCity(cityId);
    }

    function _fundAndApprove(address buyer, uint256 amount) private {
        token.transfer(buyer, amount);
        vm.prank(buyer);
        token.approve(address(registry), type(uint256).max);
    }

    function _buyer(uint256 id) private pure returns (address) {
        return address(uint160(0x1000 + id));
    }

    function _assertBacking() private view {
        assertEq(
            token.balanceOf(address(registry)),
            registry.rewardsPool() + registry.resourcePot() + registry.resourcesAllocated()
        );
    }
}
