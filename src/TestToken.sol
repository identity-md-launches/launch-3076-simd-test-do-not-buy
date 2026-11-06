// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test token only. Has no value and must not be bought.
/// @dev The launch factory receives the entire supply and performs the launch allocations.
contract TestToken is ERC20 {
    constructor() ERC20("SIMD TEST - DO NOT BUY", "SIMDTEST") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
