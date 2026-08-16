// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/**
 * @title IPoolEntrypoint
 * @notice The sliver of the entrypoint that the pool itself depends on.
 * @dev Upstream (0xbow's privacy-pools-core) this is a ~340 line interface covering an asset
 *      registry, vetting and relay fees, upgradeability and role administration. The pool contract
 *      uses exactly two things from it: the address, to gate `deposit` and `windDown`, and the
 *      latest association-set root, to check a withdrawal proof against.
 *
 *      Narrowing it to those two is what lets {NumeraPoolEntrypoint} be a plain contract instead of
 *      a UUPS proxy with an initializer, which is one fewer deployment step and one fewer way to
 *      brick a hackathon deployment.
 */
interface IPoolEntrypoint {
    /// @notice The newest approved association-set root. Every withdrawal proves against this.
    function latestRoot() external view returns (uint256 _root);
}
