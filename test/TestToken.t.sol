// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {TestToken} from "../src/TestToken.sol";

contract TestTokenTest is Test {
    TestToken internal token;

    function setUp() public {
        token = new TestToken();
    }

    function test_launchSupplyMetadataAndAllocation() public {
        assertEq(token.name(), "SIMD TEST - DO NOT BUY");
        assertEq(token.symbol(), "SIMDTEST");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
        address distributor = makeAddr("launch distributor");
        address pool = makeAddr("launch pool manager");
        address remainder = 0x4F375B772F0668282F0d1AAe573Fcb601EA04772;
        token.transfer(distributor, 1e26);
        token.transfer(pool, 266_900_000 ether);
        token.transfer(remainder, 633_100_000 ether);
        assertEq(token.balanceOf(distributor), 1e26);
        assertEq(token.balanceOf(pool), 266_900_000 ether);
        assertEq(token.balanceOf(remainder), 633_100_000 ether);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.totalSupply(), 1e27);
    }

    function testFuzz_transferAndAllowanceConserveSupply(uint96 raw) public {
        uint256 amount = bound(raw, 0, 1e27);
        address holder = makeAddr("holder");
        address spender = makeAddr("spender");
        address recipient = makeAddr("recipient");
        token.transfer(holder, amount);
        vm.prank(holder);
        token.approve(spender, amount);
        vm.prank(spender);
        token.transferFrom(holder, recipient, amount);
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.allowance(holder, spender), 0);
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(recipient), 1e27);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_failuresDoNotMoveOrFreezeTokens() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, attacker, 0, 1)
        );
        token.transferFrom(address(this), attacker, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        string[8] memory signatures = [
            "mint(address,uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "blacklist(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            // Even its deployer has no privileged entry point.
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], attacker, uint256(1)));
            assertFalse(ok);
        }
        token.transfer(attacker, 1 ether);
        assertEq(token.balanceOf(attacker), 1 ether);
        assertEq(token.totalSupply(), 1e27);
    }
}
