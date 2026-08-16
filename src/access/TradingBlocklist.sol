// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Roles} from "./Roles.sol";
import {ZeroAddress} from "../libraries/Errors.sol";

/// @title TradingBlocklist
/// @notice The set of market accounts barred from trading, shared by every engine.
///
/// @dev ## Why this is a contract of its own
///
/// The ban is written by {OptimisticResolver} — an account that staked a bond on a false outcome
/// loses the bond *and* the right to trade — and read by the engine on every trade. Those are two
/// different contracts with two different lifetimes, so the list lives in neither. A new engine
/// inherits the existing bans by pointing at the same list, and a new resolver starts writing to it
/// with a `grantRole`, neither of which is a migration.
///
/// ## What a ban does and does not reach
///
/// It blocks **trading**: opening a position and closing one. It deliberately does not block
/// {redeem}. A banned account's existing positions still settle at the honest outcome and it may
/// still collect them, because the penalty for lying is the forfeited bond and the loss of access —
/// not confiscation of money that was won fairly before the lie. An engine that blocked redemption
/// would be taking a trader's property on the strength of an operator's ruling, which is a different
/// and much larger claim than the one this system makes.
///
/// ## The honest limit
///
/// A market account is derived, and a determined trader can derive another. The ban is therefore a
/// friction, not a wall, and it is not what makes lying unprofitable — the forfeited bond is. What
/// the ban adds is that the cost cannot be amortised: the account that built up a trading history
/// and its funding path is the one that is lost, every time.
contract TradingBlocklist is AccessControl {
    /// @notice When each account was barred. Zero means it is free to trade.
    /// @dev A timestamp rather than a bool: same storage cost, and it answers "since when" for the
    ///      audit trail without a second mapping or a log query.
    mapping(address account => uint64 since) public bannedAt;

    /// @notice How many accounts are currently barred. For operator dashboards.
    uint256 public bannedCount;

    error AlreadyBanned(address account);
    error NotBanned(address account);

    /// @param context The resolver's market address, or zero when an operator bans directly.
    /// @param marketId The market the false statement was about.
    event Banned(address indexed account, address indexed context, uint256 marketId, uint64 at);
    event Unbanned(address indexed account, address indexed by);

    /// @param admin Receives `DEFAULT_ADMIN_ROLE` and `BLOCKLIST_ROLE`.
    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.BLOCKLIST_ROLE, admin);
    }

    /// @notice Bar `account` from trading on every engine reading this list.
    function ban(address account, address context, uint256 marketId) external onlyRole(Roles.BLOCKLIST_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        if (bannedAt[account] != 0) revert AlreadyBanned(account);

        uint64 at = uint64(block.timestamp);
        bannedAt[account] = at;
        unchecked {
            ++bannedCount;
        }
        emit Banned(account, context, marketId, at);
    }

    /// @notice Lift a ban.
    ///
    /// @dev Admin rather than `BLOCKLIST_ROLE`, on purpose. Banning is mechanical — it falls out of
    ///      an arbitration that already happened — so the resolver does it unattended. Reversing one
    ///      is a judgement call about a specific person, and the contract that applied the rule is
    ///      not the right place to make exceptions to it.
    function unban(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bannedAt[account] == 0) revert NotBanned(account);
        bannedAt[account] = 0;
        unchecked {
            --bannedCount;
        }
        emit Unbanned(account, _msgSender());
    }

    /// @notice Whether `account` is barred from trading.
    /// @dev The engine calls this on every trade, so it stays a single cold `SLOAD` and nothing more.
    function isBanned(address account) external view returns (bool) {
        return bannedAt[account] != 0;
    }
}
