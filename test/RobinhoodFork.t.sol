// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookScenarios} from "./TestHook.t.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Run with --fork-url and --fork-block-number. Never reads an environment variable or
/// creates a network connection during the ordinary offline suite.
contract RobinhoodForkTest is HookScenarios {
    function setUp() public {
        try vm.activeFork() returns (uint256) {}
        catch {
            vm.skip(true);
            return;
        }
        assertEq(block.chainid, 4663, "requires Robinhood Chain");
        assertEq(IERC20Metadata(IMD).symbol(), "IMD");
        assertEq(IERC20Metadata(IMD).decimals(), 18);
        _setUp(true, true);
    }
}
