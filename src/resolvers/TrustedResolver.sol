// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IResolvableMarket} from "../interfaces/IResolvableMarket.sol";
import {Roles} from "../access/Roles.sol";
import {ZeroAddress} from "../libraries/Errors.sol";

/// @title TrustedResolver
/// @notice Reference resolver: a role-gated contract that settles many markets across engines.
/// @dev Bind a market's `resolver` to an instance of this contract. Accounts holding
///      `RESOLVER_ROLE` (an operator, a multisig, or an oracle-adapter contract) then push
///      resolutions. `DEFAULT_ADMIN_ROLE` manages membership. Every parameter is configurable:
///      swap the resolver a market trusts by choosing a different `resolver` at market creation.
contract TrustedResolver is AccessControl {
    /// @param admin Receives DEFAULT_ADMIN_ROLE and RESOLVER_ROLE at deploy.
    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.RESOLVER_ROLE, admin);
    }

    /// @notice Settle `market`'s `marketId` to `winningOutcomeId`.
    /// @dev Forwards to the engine, which enforces that this resolver is the market's bound resolver.
    function resolveMarket(address market, uint256 marketId, uint256 winningOutcomeId)
        external
        onlyRole(Roles.RESOLVER_ROLE)
    {
        IResolvableMarket(market).resolve(marketId, winningOutcomeId);
    }

    /// @notice Void `market`'s `marketId`, enabling full refunds.
    function invalidateMarket(address market, uint256 marketId) external onlyRole(Roles.RESOLVER_ROLE) {
        IResolvableMarket(market).invalidate(marketId);
    }
}
