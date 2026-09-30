// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {CityRegistry} from "../src/CityRegistry.sol";
import {GrantExecutor} from "../src/GrantExecutor.sol";

/// @dev Untrusted token ONLY for exercising rollback and callback defenses; never a deployment option.
contract HostileToken {
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    uint256 public calls;
    uint256 public failAt;
    bool public bubbleCallback;
    bool public callbackSucceeded;
    bytes4 public callbackError;
    address public callbackTarget;
    bytes public callbackData;

    function fund(address who, uint256 value) external {
        balanceOf[who] += value;
    }

    function configure(uint256 failure, address target, bytes calldata data, bool bubble) external {
        calls = 0;
        failAt = failure;
        callbackTarget = target;
        callbackData = data;
        bubbleCallback = bubble;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        return _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) private returns (bool) {
        ++calls;
        if (calls == failAt) return false;
        require(balanceOf[from] >= amount, "test balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        if (callbackTarget != address(0)) {
            (bool ok, bytes memory data) = callbackTarget.call(callbackData);
            callbackSucceeded = ok;
            callbackError = bytes4(data);
            if (bubbleCallback) require(ok, "callback rejected");
        }
        return true;
    }
}

/// @dev Deployment through a contract simulates the factory's constructor caller context.
contract LocalFactory {
    function deploy(address operator, address treasury)
        external
        returns (LaunchToken token, GrantExecutor executor, CityRegistry registry)
    {
        token = new LaunchToken();
        executor = new GrantExecutor(operator);
        registry = new CityRegistry(address(token), address(executor), treasury);
    }
}

contract AdversarialTest is Test {
    address private constant BUYER = address(0xBEEF);
    address private constant TREASURY = 0x5b95A971B4583A5f011E9DA082acdD679b870D06;
    GrantExecutor private executor;
    HostileToken private token;
    CityRegistry private registry;

    function setUp() public {
        executor = new GrantExecutor(TREASURY);
        token = new HostileToken();
        registry = new CityRegistry(address(token), address(executor), TREASURY);
        token.fund(BUYER, 100_000 ether);
    }

    function testPurchaseRollbackAtEveryTokenTransfer() public {
        for (uint256 stage = 1; stage <= 3; ++stage) {
            token.configure(stage, address(0), "", false);
            vm.expectRevert(CityRegistry.TokenTransferFailed.selector);
            vm.prank(BUYER);
            registry.buyCity(0);
            assertEq(registry.soldPlots(), 0);
            assertEq(registry.totalWeight(), 0);
            assertEq(registry.cityOf(BUYER), 0);
            assertEq(registry.rewardIndex(), 0);
            assertEq(registry.rewardsPool(), 0);
            assertEq(registry.resourcePot(), 0);
            (address owner,,) = registry.cities(0);
            assertEq(owner, address(0));
            assertEq(token.balanceOf(BUYER), 100_000 ether);
            assertEq(token.balanceOf(address(registry)), 0);
            assertEq(token.balanceOf(address(0)), 0);
            assertEq(token.balanceOf(TREASURY), 0);
        }
        token.configure(0, address(0), "", false);
        vm.prank(BUYER);
        registry.buyCity(0);
        assertEq(registry.soldPlots(), 1);
    }

    function testAllRegistryMutatorsRejectTokenCallbacks() public {
        bytes[5] memory data = [
            abi.encodeCall(registry.buyCity, (1)),
            abi.encodeCall(registry.levelUp, (0)),
            abi.encodeCall(registry.claimRewards, (0)),
            abi.encodeCall(registry.grantResources, (0, 1)),
            abi.encodeCall(registry.recordHeartbeat, (0, 1, 1, 1, 2, 1))
        ];
        for (uint256 i; i < data.length; ++i) {
            CityRegistry other = new CityRegistry(address(token), address(executor), TREASURY);
            token.configure(0, address(other), data[i], false);
            vm.prank(BUYER);
            other.buyCity(0);
            assertFalse(token.callbackSucceeded());
            assertEq(token.callbackError(), CityRegistry.ReentrantCall.selector);
            assertEq(other.soldPlots(), 1);
            assertEq(other.totalWeight(), 1);
            assertEq(other.rewardsPool(), 200 ether);
        }
    }

    function testBubblingCallbackRevertsPurchaseAndReleasesLock() public {
        token.configure(0, address(registry), abi.encodeCall(registry.buyCity, (1)), true);
        vm.expectRevert("callback rejected");
        vm.prank(BUYER);
        registry.buyCity(0);
        assertEq(registry.soldPlots(), 0);
        assertEq(token.balanceOf(BUYER), 100_000 ether);
        token.configure(0, address(0), "", false);
        vm.prank(BUYER);
        registry.buyCity(0);
        assertEq(registry.soldPlots(), 1);
    }

    function testClaimRollbackRestoresEntitlementAndPool() public {
        vm.prank(BUYER);
        registry.buyCity(0);
        uint256 before = token.balanceOf(BUYER);
        token.configure(1, address(0), "", false);
        vm.expectRevert(CityRegistry.TokenTransferFailed.selector);
        vm.prank(BUYER);
        registry.claimRewards(0);
        assertEq(registry.claimableRewards(0), 200 ether);
        assertEq(registry.rewardsPool(), 200 ether);
        assertEq(token.balanceOf(BUYER), before);

        token.configure(0, address(registry), abi.encodeCall(registry.claimRewards, (0)), false);
        vm.prank(BUYER);
        assertEq(registry.claimRewards(0), 200 ether);
        assertFalse(token.callbackSucceeded());
        assertEq(token.callbackError(), CityRegistry.ReentrantCall.selector);
        assertEq(registry.claimableRewards(0), 0);
        assertEq(registry.rewardsPool(), 0);
        assertEq(token.balanceOf(BUYER), before + 200 ether);
    }

    function testMaximumLevelBoundaryWithSyntheticResourceFunding() public {
        vm.prank(BUYER);
        registry.buyCity(0);
        // Real sales cannot fund level 20 at the specified 1:1 conversion. Seed ONLY the
        // resource slot in a test fixture to verify the otherwise unreachable hard ceiling.
        bytes32 cityBase = keccak256(abi.encode(uint256(0), uint256(0)));
        vm.store(address(registry), bytes32(uint256(cityBase) + 2), bytes32(uint256(286_900 ether)));
        for (uint256 next = 2; next <= 20; ++next) {
            assertEq(registry.levelUpCost(0), 100 ether * next * next);
            vm.prank(BUYER);
            registry.levelUp(0);
            (, uint256 level,) = registry.cities(0);
            assertEq(level, next);
            assertEq(registry.totalWeight(), next * next);
        }
        (, uint256 finalLevel, uint256 remaining) = registry.cities(0);
        assertEq(finalLevel, 20);
        assertEq(remaining, 0);
        assertEq(registry.claimableRewards(0), 200 ether);
        vm.expectRevert(CityRegistry.MaximumLevel.selector);
        vm.prank(BUYER);
        registry.levelUp(0);
        vm.expectRevert(CityRegistry.MaximumLevel.selector);
        registry.levelUpCost(0);
    }

    function testFactoryConstructorsPreserveSupplyAndSetExplicitRoles() public {
        LocalFactory factory = new LocalFactory();
        (LaunchToken deployedToken, GrantExecutor deployedExecutor, CityRegistry deployedRegistry) =
            factory.deploy(TREASURY, TREASURY);
        assertEq(deployedToken.totalSupply(), 1e27);
        assertEq(deployedToken.balanceOf(address(factory)), 1e27);
        assertEq(deployedToken.balanceOf(address(deployedRegistry)), 0);
        assertEq(deployedExecutor.operator(), TREASURY);
        assertEq(deployedRegistry.grantExecutor(), address(deployedExecutor));
        assertEq(deployedRegistry.treasury(), TREASURY);
        assertEq(address(deployedRegistry.token()), address(deployedToken));
        vm.expectRevert(GrantExecutor.Unauthorized.selector);
        vm.prank(address(factory));
        deployedExecutor.pauseGrants();
        vm.prank(TREASURY);
        deployedExecutor.pauseGrants();
        assertTrue(deployedExecutor.grantsPaused());
        _checkRuntime(address(deployedToken));
        _checkRuntime(address(deployedExecutor));
        _checkRuntime(address(deployedRegistry));
    }

    function testNoPostDeploymentInitializationOrCityTransfers() public {
        bytes4[5] memory selectors = [
            bytes4(keccak256("initialize(address)")),
            bytes4(keccak256("setGrantExecutor(address)")),
            bytes4(keccak256("setTreasury(address)")),
            bytes4(keccak256("transferCity(uint256,address)")),
            bytes4(keccak256("transferFrom(address,address,uint256)"))
        ];
        for (uint256 i; i < selectors.length; ++i) {
            (bool ok,) = address(registry).call(abi.encodeWithSelector(selectors[i], BUYER, BUYER, 0));
            assertFalse(ok);
        }
    }

    function _checkRuntime(address deployed) private view {
        bytes memory code = deployed.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
            } else {
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
            }
        }
    }
}
