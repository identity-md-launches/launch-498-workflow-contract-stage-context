// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken private token;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant SPENDER = address(0x5EED);
    uint256 private constant SUPPLY = 1e27;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new LaunchToken();
    }

    function testMetadataAndEntireSupplyMintedToDeployer() public view {
        assertEq(token.name(), "Swarm Cities");
        assertEq(token.symbol(), "GRID");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(ALICE), 0);
    }

    function testDeploymentCreditsActualCallerAndEmitsMint() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), ALICE, SUPPLY);
        vm.prank(ALICE);
        LaunchToken other = new LaunchToken();
        assertEq(other.balanceOf(ALICE), SUPPLY);
        assertEq(other.balanceOf(address(this)), 0);
    }

    function testTransferEmitsAndMovesExactAmount() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), ALICE, 123 ether);
        assertTrue(token.transfer(ALICE, 123 ether));
        assertEq(token.balanceOf(ALICE), 123 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 123 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testZeroTransferFromEmptyAccountSucceedsAndEmits() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(ALICE, BOB, 0);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 0);
    }

    function testSelfTransferPreservesBalance() public {
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function testInsufficientBalanceRevertsWithoutStateChange() public {
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(BOB, 1);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testApproveOverwritesAndCanBeRevoked() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), SPENDER, 100 ether);
        assertTrue(token.approve(SPENDER, 100 ether));
        assertEq(token.allowance(address(this), SPENDER), 100 ether);
        token.approve(SPENDER, 50 ether);
        assertEq(token.allowance(address(this), SPENDER), 50 ether);
        token.approve(SPENDER, 0);
        assertEq(token.allowance(address(this), SPENDER), 0);
    }

    function testApprovalDoesNotGiveAnotherCallerSpendingRights() public {
        token.approve(SPENDER, 100 ether);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InsufficientAllowance.selector, ALICE, 0, 1 ether));
        vm.prank(ALICE);
        token.transferFrom(address(this), ALICE, 1 ether);
        assertEq(token.allowance(address(this), SPENDER), 100 ether);
    }

    function testTransferFromSpendsOnlyApprovedAmount() public {
        token.approve(SPENDER, 100 ether);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), ALICE, 40 ether));
        assertEq(token.allowance(address(this), SPENDER), 60 ether);
        assertEq(token.balanceOf(ALICE), 40 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 40 ether);

        vm.expectRevert(
            abi.encodeWithSelector(LaunchToken.ERC20InsufficientAllowance.selector, SPENDER, 60 ether, 61 ether)
        );
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 61 ether);
        assertEq(token.allowance(address(this), SPENDER), 60 ether);
        assertEq(token.balanceOf(ALICE), 40 ether);
    }

    function testInfiniteAllowanceIsNotDecremented() public {
        token.approve(SPENDER, type(uint256).max);
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 100 ether);
        assertEq(token.allowance(address(this), SPENDER), type(uint256).max);
        assertEq(token.balanceOf(ALICE), 100 ether);
    }

    function testRevertingTransferFromRestoresAllowance() public {
        vm.prank(ALICE);
        token.approve(SPENDER, 100 ether);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InsufficientBalance.selector, ALICE, 0, 100 ether));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 100 ether);
        assertEq(token.allowance(ALICE, SPENDER), 100 ether);
        assertEq(token.balanceOf(BOB), 0);
    }

    function testSelfTransferFromStillConsumesAllowance() public {
        token.approve(SPENDER, 100 ether);
        vm.prank(SPENDER);
        token.transferFrom(address(this), address(this), 100 ether);
        assertEq(token.allowance(address(this), SPENDER), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function testTransfersToZeroSinkPreserveFixedSupply() public {
        token.transfer(address(0), 100 ether);
        token.approve(SPENDER, 200 ether);
        vm.prank(SPENDER);
        token.transferFrom(address(this), address(0), 200 ether);
        assertEq(token.balanceOf(address(0)), 300 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 300 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testZeroSinkCannotSendOrApproveEvenWithImpersonation() public {
        token.transfer(address(0), 100 ether);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InvalidSender.selector, address(0)));
        vm.prank(address(0));
        token.transfer(ALICE, 100 ether);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InvalidApprover.selector, address(0)));
        vm.prank(address(0));
        token.approve(SPENDER, 100 ether);
        assertEq(token.balanceOf(address(0)), 100 ether);
    }

    function testTransferFromZeroCannotEmitSpuriousMintEvenForZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InvalidSender.selector, address(0)));
        token.transferFrom(address(0), ALICE, 0);
    }

    function testZeroSpenderApprovalReverts() public {
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1 ether);
    }

    function testNoAdministrativeOrMintEntryPoints() public {
        bytes4[11] memory selectors = [
            bytes4(keccak256("mint(address,uint256)")),
            bytes4(keccak256("mint(uint256)")),
            bytes4(keccak256("mint()")),
            bytes4(keccak256("owner()")),
            bytes4(keccak256("transferOwnership(address)")),
            bytes4(keccak256("pause()")),
            bytes4(keccak256("unpause()")),
            bytes4(keccak256("upgradeTo(address)")),
            bytes4(keccak256("initialize(address)")),
            bytes4(keccak256("setMinter(address)")),
            bytes4(keccak256("setFee(uint256)"))
        ];
        for (uint256 i; i < selectors.length; ++i) {
            (bool deployerSuccess,) = address(token).call(abi.encodeWithSelector(selectors[i], ALICE, 1 ether));
            assertFalse(deployerSuccess);
            vm.prank(ALICE);
            (bool attackerSuccess,) = address(token).call(abi.encodeWithSelector(selectors[i], ALICE, 1 ether));
            assertFalse(attackerSuccess);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
    }

    function testCannotReceiveEther() public {
        vm.deal(address(this), 1 ether);
        (bool success,) = address(token).call{value: 1 ether}("");
        assertFalse(success);
        assertEq(address(token).balance, 0);
    }

    function testFuzzTransferConservesSupply(address recipient, uint256 amount) public {
        vm.assume(recipient != address(this));
        amount = bound(amount, 0, SUPPLY);
        token.transfer(recipient, amount);
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.balanceOf(recipient) + token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzzDelegatedTransferConservesSupplyAndAllowance(uint256 approved, uint256 amount) public {
        approved = bound(approved, 0, SUPPLY);
        amount = bound(amount, 0, approved);
        token.approve(SPENDER, approved);
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, amount);
        assertEq(token.allowance(address(this), SPENDER), approved - amount);
        assertEq(token.balanceOf(ALICE) + token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
