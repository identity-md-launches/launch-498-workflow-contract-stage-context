// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {CityRegistry} from "src/CityRegistry.sol";
import {GrantExecutor} from "src/GrantExecutor.sol";

contract SixDecimalTokenFixture {
    uint8 public constant decimals = 6;
}

/// forge-config: default.fuzz.runs = 1000
contract CityRegistryBoundariesTest is Test {
    address private constant OPERATOR = 0x5b95A971B4583A5f011E9DA082acdD679b870D06;
    LaunchToken private token;
    GrantExecutor private executor;
    CityRegistry private registry;

    function setUp() public {
        token = new LaunchToken();
        executor = new GrantExecutor(OPERATOR);
        registry = new CityRegistry(address(token), address(executor), OPERATOR);
    }

    function testStaleExactApprovalRevertsAtomicallyAndCanBeRefreshed() public {
        address buyer = _owner(1);
        (,, uint256 oldTotal) = registry.quote();
        token.transfer(buyer, 50_000 ether);
        vm.prank(buyer);
        token.approve(address(registry), oldTotal);
        _buy(0);
        (,, uint256 newTotal) = registry.quote();
        assertGt(newTotal, oldTotal);
        bytes32 beforeState = _stateDigest();
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchToken.ERC20InsufficientAllowance.selector, address(registry), oldTotal, newTotal
            )
        );
        vm.prank(buyer);
        registry.buyCity(1);
        assertEq(_stateDigest(), beforeState, "stale allowance must roll back all purchase effects");
        vm.startPrank(buyer);
        token.approve(address(registry), newTotal);
        registry.buyCity(1);
        vm.stopPrank();
        assertEq(token.balanceOf(buyer), 50_000 ether - newTotal);
        assertEq(token.allowance(buyer, address(registry)), 0);
        assertEq(registry.cityOf(buyer), 2);
        assertEq(registry.soldPlots(), 2);
    }

    function testHoldingThresholdAtZeroOneAndOneWeiBelowMinimum() public {
        uint256[3] memory amounts = [uint256(0), uint256(1), 1000 ether - 1];
        for (uint256 i; i < amounts.length; ++i) {
            token.transfer(_owner(i), amounts[i]);
            vm.prank(_owner(i));
            token.approve(address(registry), type(uint256).max);
            bytes32 beforeState = _stateDigest();
            vm.expectRevert(CityRegistry.InsufficientHolding.selector);
            vm.prank(_owner(i));
            registry.buyCity(i);
            assertEq(_stateDigest(), beforeState);
        }
    }

    function testExactMinimumPassesHoldingGateButCannotPayPurchasePrice() public {
        address buyer = _owner(0);
        token.transfer(buyer, 1000 ether);
        vm.prank(buyer);
        token.approve(address(registry), type(uint256).max);
        bytes32 beforeState = _stateDigest();
        vm.expectRevert(
            abi.encodeWithSelector(LaunchToken.ERC20InsufficientBalance.selector, buyer, 1000 ether, 10_400 ether)
        );
        vm.prank(buyer);
        registry.buyCity(0);
        assertEq(_stateDigest(), beforeState);
    }

    function testFuzzEveryValidatedCityEntryRejectsOutOfRangeIds(uint256 invalidId) public {
        invalidId = bound(invalidId, 256, type(uint256).max);
        _buy(0);
        bytes32 beforeState = _stateDigest();
        vm.expectRevert(CityRegistry.InvalidCity.selector);
        registry.coordinates(invalidId);
        vm.expectRevert(CityRegistry.InvalidCity.selector);
        registry.levelUpCost(invalidId);
        vm.expectRevert(CityRegistry.InvalidCity.selector);
        registry.claimableRewards(invalidId);
        vm.startPrank(_owner(0));
        vm.expectRevert(CityRegistry.InvalidCity.selector);
        registry.buyCity(invalidId);
        vm.expectRevert(CityRegistry.InvalidCity.selector);
        registry.levelUp(invalidId);
        vm.expectRevert(CityRegistry.InvalidCity.selector);
        registry.claimRewards(invalidId);
        vm.stopPrank();
        vm.expectRevert(CityRegistry.InvalidCity.selector);
        vm.prank(OPERATOR);
        executor.grantResources(address(registry), invalidId, 1);
        assertEq(_stateDigest(), beforeState);
    }

    function testMaximumCityIdCannotOverflowValidation() public {
        testFuzzEveryValidatedCityEntryRejectsOutOfRangeIds(type(uint256).max);
    }

    function testFuzzRejectedHeartbeatPreservesPreviousBatch(uint256 positionSeed, uint256 faultSeed) public {
        for (uint256 i; i < 3; ++i) {
            _buy(i);
        }
        vm.warp(100);
        vm.prank(OPERATOR);
        executor.recordHeartbeat(address(registry), 2, 1, 0, 2, 1, 3);
        bytes32 beforeState = _stateDigest();
        vm.warp(200);

        uint256 position = bound(positionSeed, 0, 2);
        uint256 fault = bound(faultSeed, 0, 4);
        uint256[3] memory ids = [uint256(0), uint256(1), uint256(2)];
        uint256[3] memory amounts = [uint256(1), uint256(1), uint256(1)];
        bytes4 expectedError;
        if (fault == 0) {
            ids[position] = type(uint256).max;
            expectedError = CityRegistry.InvalidCity.selector;
        } else if (fault == 1) {
            ids[position] = 255;
            expectedError = CityRegistry.CityUnowned.selector;
        } else if (fault == 2) {
            amounts[position] = 0;
            expectedError = CityRegistry.InvalidAmount.selector;
        } else {
            amounts[position] = fault == 3 ? registry.resourcePot() + 1 : type(uint256).max;
            expectedError = CityRegistry.InsufficientResourcePot.selector;
        }
        vm.expectRevert(expectedError);
        vm.prank(OPERATOR);
        executor.recordHeartbeat(address(registry), ids[0], amounts[0], ids[1], amounts[1], ids[2], amounts[2]);
        assertEq(_stateDigest(), beforeState, "failed batch changed balances or prior heartbeat");

        // Failure must release the guard, and a subsequent single grant must not replace winners.
        vm.prank(OPERATOR);
        executor.grantResources(address(registry), 0, 1);
        assertEq(registry.heartbeatCount(), 1);
        assertEq(registry.lastHeartbeatTimestamp(), 100);
        uint256[3] memory previousIds = [uint256(2), uint256(0), uint256(1)];
        for (uint256 i; i < 3; ++i) {
            (uint256 winner, uint256 amount) = registry.lastHeartbeat(i);
            assertEq(winner, previousIds[i]);
            assertEq(amount, i + 1);
        }
    }

    function testMaximumHeartbeatAmountAfterTwoValidAwardsRollsBack() public {
        testFuzzRejectedHeartbeatPreservesPreviousBatch(2, 4);
    }

    function testOneWeiGrantFullDrainThenPurchaseReplenishesPot() public {
        _buy(0);
        vm.startPrank(OPERATOR);
        executor.grantResources(address(registry), 0, 1);
        executor.grantResources(address(registry), 0, 120 ether - 1);
        vm.stopPrank();
        assertEq(registry.resourcePot(), 0);
        assertEq(registry.resourcesAllocated(), 120 ether);
        (,, uint256 resources) = registry.cities(0);
        assertEq(resources, 120 ether);
        bytes32 beforeState = _stateDigest();
        vm.expectRevert(CityRegistry.InsufficientResourcePot.selector);
        vm.prank(OPERATOR);
        executor.grantResources(address(registry), 0, 1);
        assertEq(_stateDigest(), beforeState);
        _buy(1);
        uint256 replenished = registry.resourcePot();
        assertGt(replenished, 0);
        vm.prank(OPERATOR);
        executor.grantResources(address(registry), 0, replenished);
        assertEq(registry.resourcePot(), 0);
        (,, resources) = registry.cities(0);
        assertEq(resources, 120 ether + replenished);
        assertEq(registry.resourcesAllocated(), resources);
        assertEq(token.balanceOf(address(registry)), resources + registry.rewardsPool());
    }

    function testFuzzSplittingResourceGrantPreservesOutcome(uint256 totalSeed, uint256 splitSeed) public {
        _buy(0);
        uint256 total = bound(totalSeed, 2, 120 ether);
        uint256 first = bound(splitSeed, 1, total - 1);
        uint256 snapshot = vm.snapshotState();
        vm.prank(OPERATOR);
        executor.grantResources(address(registry), 0, total);
        bytes32 oneGrantState = _stateDigest();
        assertTrue(vm.revertToState(snapshot));
        vm.startPrank(OPERATOR);
        executor.grantResources(address(registry), 0, first);
        executor.grantResources(address(registry), 0, total - first);
        vm.stopPrank();
        assertEq(_stateDigest(), oneGrantState, "splitting allocation changed its economic effect");
    }

    function testSoldOutRegistryStillAllowsGrantsLevelingAndAllClaimsWhilePaused() public {
        for (uint256 i; i < 256; ++i) {
            _buy(i);
        }
        vm.expectRevert(CityRegistry.SoldOut.selector);
        registry.quote();
        uint256 rewardFunding = registry.rewardsPool();
        uint256 resourceFunding = registry.resourcePot();
        vm.prank(OPERATOR);
        executor.recordHeartbeat(address(registry), 0, 400 ether, 1, 1, 255, 1);
        vm.prank(OPERATOR);
        executor.pauseGrants();
        uint256 oldEntitlement = registry.claimableRewards(0);
        vm.prank(_owner(0));
        registry.levelUp(0);
        assertEq(registry.claimableRewards(0), oldEntitlement, "level changed past rewards");
        assertEq(registry.totalWeight(), 259);
        uint256 claimed;
        for (uint256 i; i < 256; ++i) {
            vm.prank(_owner(i));
            uint256 amount = registry.claimRewards(i);
            assertGt(amount, 0);
            assertEq(token.balanceOf(_owner(i)), amount);
            claimed += amount;
            assertEq(registry.claimableRewards(i), 0);
            vm.expectRevert(CityRegistry.NothingToClaim.selector);
            vm.prank(_owner(i));
            registry.claimRewards(i);
        }
        assertEq(registry.rewardsPool(), rewardFunding - claimed);
        assertLe(registry.rewardsPool(), 256, "more than rounding dust left after everyone claimed");
        assertEq(registry.resourcePot() + registry.resourcesAllocated(), resourceFunding);
        assertEq(token.balanceOf(address(registry)), resourceFunding + registry.rewardsPool());
        assertTrue(executor.grantsPaused());
        assertEq(registry.soldPlots(), 256);
    }

    function testConstructorRejectsEOATokenAndWrongDecimals() public {
        vm.expectRevert(CityRegistry.InvalidConfiguration.selector);
        new CityRegistry(_owner(0), address(executor), OPERATOR);
        SixDecimalTokenFixture wrongDecimals = new SixDecimalTokenFixture();
        vm.expectRevert(CityRegistry.InvalidConfiguration.selector);
        new CityRegistry(address(wrongDecimals), address(executor), OPERATOR);
    }

    function _buy(uint256 cityId) private {
        (,, uint256 total) = registry.quote();
        address buyer = _owner(cityId);
        token.transfer(buyer, total);
        vm.startPrank(buyer);
        token.approve(address(registry), total);
        registry.buyCity(cityId);
        vm.stopPrank();
    }

    function _owner(uint256 cityId) private pure returns (address) {
        return address(uint160(0xC000 + cityId));
    }

    /// @dev Includes only contract state, so elapsed time alone cannot change the digest.
    function _stateDigest() private view returns (bytes32 state) {
        state = keccak256(
            abi.encode(
                registry.soldPlots(),
                registry.totalWeight(),
                registry.rewardsPool(),
                registry.resourcePot(),
                registry.resourcesAllocated(),
                registry.rewardIndex(),
                registry.heartbeatCount(),
                registry.lastHeartbeatTimestamp(),
                executor.grantsPaused()
            )
        );
        state = keccak256(
            abi.encode(
                state,
                token.balanceOf(address(this)),
                token.balanceOf(address(registry)),
                token.balanceOf(address(0)),
                token.balanceOf(OPERATOR),
                token.totalSupply()
            )
        );
        for (uint256 i; i < 4; ++i) {
            (address owner, uint256 level, uint256 resources) = registry.cities(i);
            uint256 claimable = owner == address(0) ? 0 : registry.claimableRewards(i);
            state = keccak256(
                abi.encode(
                    state,
                    owner,
                    level,
                    resources,
                    claimable,
                    registry.cityOf(_owner(i)),
                    token.balanceOf(_owner(i)),
                    token.allowance(_owner(i), address(registry))
                )
            );
        }
        for (uint256 i; i < 3; ++i) {
            (uint256 winner, uint256 amount) = registry.lastHeartbeat(i);
            state = keccak256(abi.encode(state, winner, amount));
        }
    }
}
