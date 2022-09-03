// SPDX-License-Identifier: None

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract token is ERC20 {

    constructor() ERC20 ("TokenA", "A") {
        _mint(msg.sender, 1000000000000000000e18);
    }
}