// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title IMDwindowshopper (WWW)
/// @notice A fixed supply ERC-20 with 18 decimals and no administrative powers.
contract IMDwindowshopper is ERC20 {
    /// @notice One billion tokens, expressed in the token's smallest units.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    /// @notice Mints the entire supply once to the immediate deployer.
    /// @dev During the custom token launch, msg.sender is the launch factory.
    constructor() ERC20("IMDwindowshopper", "WWW") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
