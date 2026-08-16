// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockToggleFeeERC20
/// @notice ERC-20 whose transfer fee can be toggled at runtime, for tests only.
/// @dev Lets a test create a market while the token behaves normally, then switch on a transfer fee
///      to exercise the engines' balance-delta / received-amount guards.
contract MockToggleFeeERC20 is ERC20 {
    uint256 public feeBps;

    constructor() ERC20("ToggleFee", "TGL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFee(uint256 feeBps_) external {
        feeBps = feeBps_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || feeBps == 0) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * feeBps) / 10_000;
        super._update(from, to, value - fee);
        super._update(from, address(0), fee);
    }
}
