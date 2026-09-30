// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "src/LaunchToken.sol";

/// @dev A closed set of four holders and the zero sink, including self transfers and self approvals.
contract LaunchTokenSequenceHandler is Test {
    uint256 public constant SUPPLY = 1e27;
    LaunchToken public immutable token;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor(LaunchToken token_) {
        token = token_;
        expectedBalance[actor(0)] = SUPPLY;
    }

    function actor(uint256 seed) public pure returns (address) {
        return address(uint160(0xA000 + seed % 4));
    }

    function recipient(uint256 seed) public pure returns (address) {
        return seed % 5 == 4 ? address(0) : actor(seed % 5);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) public {
        address from = actor(fromSeed);
        address to = recipient(toSeed);
        uint256 amount = bound(amountSeed, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _move(from, to, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) public {
        address owner = actor(ownerSeed);
        address spender = actor(spenderSeed);
        uint256 amount = amountSeed;
        // Include revoked, unlimited and practical finite approvals in long sequences.
        if (amountSeed % 3 == 0) amount = 0;
        else if (amountSeed % 3 == 1) amount = type(uint256).max;
        else amount = bound(amountSeed, 0, SUPPLY);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 fromSeed, uint256 toSeed, uint256 spenderSeed, uint256 amountSeed) public {
        address from = actor(fromSeed);
        address to = recipient(toSeed);
        address spender = actor(spenderSeed);
        uint256 permitted = expectedAllowance[from][spender];
        uint256 limit = expectedBalance[from] < permitted ? expectedBalance[from] : permitted;
        uint256 amount = bound(amountSeed, 0, limit);
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
        if (permitted != type(uint256).max) expectedAllowance[from][spender] -= amount;
        _move(from, to, amount);
    }

    function revokeAndReject(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed) public {
        address owner = actor(ownerSeed);
        address spender = actor(spenderSeed);
        vm.prank(owner);
        assertTrue(token.approve(spender, 0));
        expectedAllowance[owner][spender] = 0;
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(owner, recipient(toSeed), 1);
    }

    function rejectOverspend(uint256 ownerSeed, uint256 spenderSeed, bool delegated) public {
        address owner = actor(ownerSeed);
        uint256 balance = expectedBalance[owner];
        uint256 amount = balance + 1;
        if (delegated) {
            address spender = actor(spenderSeed);
            // A finite sufficient allowance must survive the failing transferFrom unchanged.
            vm.prank(owner);
            assertTrue(token.approve(spender, amount));
            expectedAllowance[owner][spender] = amount;
            vm.expectRevert(
                abi.encodeWithSelector(LaunchToken.ERC20InsufficientBalance.selector, owner, balance, amount)
            );
            vm.prank(spender);
            token.transferFrom(owner, spender, amount);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(LaunchToken.ERC20InsufficientBalance.selector, owner, balance, amount)
            );
            vm.prank(owner);
            token.transfer(actor(spenderSeed), amount);
        }
    }

    function _move(address from, address to, uint256 amount) private {
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract LaunchTokenInvariantTest is Test {
    LaunchToken private token;
    LaunchTokenSequenceHandler private handler;

    function setUp() public {
        token = new LaunchToken();
        handler = new LaunchTokenSequenceHandler(token);
        token.transfer(handler.actor(0), 1e27);
        handler.transfer(0, 1, 100 ether);
        handler.transfer(0, 2, 100 ether);
        handler.transfer(0, 3, 100 ether);
        handler.transfer(0, 4, 1);
        // Seed nonzero finite and unlimited delegated transfers before random ordering begins.
        handler.approve(0, 1, 101);
        handler.transferFrom(0, 2, 1, 1);
        handler.approve(0, 2, 1);
        handler.transferFrom(0, 3, 2, 1);

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.revokeAndReject.selector;
        selectors[4] = handler.rejectOverspend.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_balancesAllowancesAndFixedSupplyMatchTransactionHistory() public view {
        uint256 sum = token.balanceOf(address(0));
        assertEq(sum, handler.expectedBalance(address(0)), "sink lost or created tokens");
        for (uint256 i; i < 4; ++i) {
            address owner = handler.actor(i);
            uint256 balance = token.balanceOf(owner);
            assertEq(balance, handler.expectedBalance(owner), "wrong holder balance");
            sum += balance;
            for (uint256 j; j < 4; ++j) {
                address spender = handler.actor(j);
                assertEq(
                    token.allowance(owner, spender),
                    handler.expectedAllowance(owner, spender),
                    "wrong spending authority"
                );
            }
            assertEq(token.allowance(address(0), owner), 0, "sink became spendable");
        }
        assertEq(sum, 1e27, "transfers created or destroyed nominal supply");
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }

    function testBoundaryFullSupplyAndMaximumRequests() public {
        LaunchToken fresh = new LaunchToken();
        address spender = address(0xBEEF);
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchToken.ERC20InsufficientBalance.selector, address(this), 1e27, type(uint256).max
            )
        );
        fresh.transfer(spender, type(uint256).max);
        fresh.approve(spender, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchToken.ERC20InsufficientBalance.selector, address(this), 1e27, type(uint256).max
            )
        );
        vm.prank(spender);
        fresh.transferFrom(address(this), spender, type(uint256).max);
        assertEq(fresh.allowance(address(this), spender), type(uint256).max);
        assertEq(fresh.balanceOf(address(this)), 1e27);
        assertEq(fresh.balanceOf(spender), 0);
        vm.prank(spender);
        assertTrue(fresh.transferFrom(address(this), address(0), 1e27));
        assertEq(fresh.balanceOf(address(this)), 0);
        assertEq(fresh.balanceOf(address(0)), 1e27);
        assertEq(fresh.allowance(address(this), spender), type(uint256).max);
        assertEq(fresh.totalSupply(), 1e27);
    }
}
