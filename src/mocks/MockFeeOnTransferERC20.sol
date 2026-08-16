// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockFeeOnTransferERC20
/// @notice ERC-20 that burns a fixed basis-point fee on every transfer, for tests only.
/// @dev Used to verify the market credits the *actually received* amount (balance-delta accounting)
///      rather than the requested amount. USDC is not fee-on-transfer, but robust accounting matters.
contract MockFeeOnTransferERC20 is ERC20 {
    uint256 public immutable feeBps; // fee burned on each transfer, in basis points

    constructor(uint256 feeBps_) ERC20("FeeToken", "FEE") {
        feeBps = feeBps_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || feeBps == 0) {
            super._update(from, to, value); // mint/burn pass through untaxed
            return;
        }
        uint256 fee = (value * feeBps) / 10_000;
        super._update(from, to, value - fee);
        super._update(from, address(0), fee); // burn the fee
    }
}
