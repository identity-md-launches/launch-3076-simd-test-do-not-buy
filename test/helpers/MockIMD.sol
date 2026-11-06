// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Offline pair-token fixture only; never deployed by the launch.
contract MockIMD is ERC20 {
    address public rejectedRecipient;

    error RecipientRejected();

    constructor() ERC20("Mock IMD", "IMD") {}

    function rejectRecipient(address recipient) external {
        rejectedRecipient = recipient;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (to == rejectedRecipient && to != address(0)) revert RecipientRejected();
        super._update(from, to, value);
    }
}
