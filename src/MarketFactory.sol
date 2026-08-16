// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {MarketTypes} from "./libraries/MarketTypes.sol";
import {Roles} from "./access/Roles.sol";
import {IMarketEngine} from "./interfaces/IMarketEngine.sol";
import {ZeroAddress, MarketNotFound, NotAuthorized} from "./libraries/Errors.sol";

/// @title MarketFactory
/// @notice Generic catalog for a multi-engine, multi-category private prediction marketplace.
///
/// @dev Design: market engines ({ParimutuelMarket}, {LMSRMarket}) are deployed independently — each
///      is large and must own its own collateral vault and admin — and then *registered* here.
///      Routing creation through the factory is deliberately avoided: for LMSR the creator seeds
///      liquidity, so `msg.sender` (and therefore the LP identity) must be the real creator, not the
///      factory. Instead this contract is the neutral registry/discovery layer:
///        - an **engine registry** (which pricing engines exist and are live),
///        - a **category catalog** (which categories the marketplace officially supports — any
///          category can be added, so the system is generic across sports, politics, etc.),
///        - a **market index** so every market across every engine is enumerable on-chain.
///
///      Nothing here touches collateral or user identity, so it adds no privacy surface: the trader
///      privacy guarantee lives entirely in the engines' Unlink integration.
contract MarketFactory is AccessControl {
    struct EngineInfo {
        address engine;
        MarketTypes.Kind kind;
        string label;
        bool enabled;
    }

    struct CategoryInfo {
        string label;
        bool enabled;
        bool exists;
    }

    struct MarketRef {
        uint256 engineId;
        uint256 marketId;
        MarketTypes.Kind kind;
        bytes32 category;
        address creator;
        uint64 createdAt;
    }

    EngineInfo[] private _engines;
    MarketRef[] private _markets;

    bytes32[] private _categoryIds;
    mapping(bytes32 => CategoryInfo) public categories;

    event EngineRegistered(
        uint256 indexed engineId, address indexed engine, MarketTypes.Kind kind, string label
    );
    event EngineEnabledSet(uint256 indexed engineId, bool enabled);
    event CategorySet(bytes32 indexed category, string label, bool enabled);
    event MarketIndexed(
        uint256 indexed refId,
        uint256 indexed engineId,
        uint256 marketId,
        bytes32 indexed category,
        address creator
    );

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.CURATOR_ROLE, admin);
    }

    // -------------------------------------------------------------------------
    // Engine registry (admin)
    // -------------------------------------------------------------------------

    /// @notice Register a deployed market engine. Returns its registry id.
    function registerEngine(address engine, MarketTypes.Kind kind, string calldata label)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint256 engineId)
    {
        if (engine == address(0)) revert ZeroAddress();
        engineId = _engines.length;
        _engines.push(EngineInfo({engine: engine, kind: kind, label: label, enabled: true}));
        emit EngineRegistered(engineId, engine, kind, label);
    }

    /// @notice Enable or disable an engine for new indexing (does not affect existing markets).
    function setEngineEnabled(uint256 engineId, bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (engineId >= _engines.length) revert MarketNotFound(engineId);
        _engines[engineId].enabled = enabled;
        emit EngineEnabledSet(engineId, enabled);
    }

    // -------------------------------------------------------------------------
    // Category catalog (curator) — any category is supportable, making the system generic
    // -------------------------------------------------------------------------

    /// @notice Add or update a category (e.g. "SPORTS", "POLITICS", "CRYPTO", "ESPORTS").
    function setCategory(bytes32 category, string calldata label, bool enabled)
        external
        onlyRole(Roles.CURATOR_ROLE)
    {
        if (category == bytes32(0)) revert ZeroAddress();
        CategoryInfo storage c = categories[category];
        if (!c.exists) {
            c.exists = true;
            _categoryIds.push(category);
        }
        c.label = label;
        c.enabled = enabled;
        emit CategorySet(category, label, enabled);
    }

    // -------------------------------------------------------------------------
    // Market index (curator)
    // -------------------------------------------------------------------------

    /// @notice Index a market that was created on a registered engine, into the global catalog.
    /// @dev Verifies the engine is live, the category is enabled, and the marketId exists on-chain.
    /// @return refId The global index id of the recorded market.
    function recordMarket(uint256 engineId, uint256 marketId, bytes32 category)
        external
        onlyRole(Roles.CURATOR_ROLE)
        returns (uint256 refId)
    {
        if (engineId >= _engines.length) revert MarketNotFound(engineId);
        EngineInfo storage e = _engines[engineId];
        if (!e.enabled) revert NotAuthorized(e.engine);
        if (!categories[category].enabled) revert NotAuthorized(address(0));
        // Verify the market actually exists on the engine.
        if (marketId >= IMarketEngine(e.engine).marketCount()) revert MarketNotFound(marketId);

        refId = _markets.length;
        _markets.push(
            MarketRef({
                engineId: engineId,
                marketId: marketId,
                kind: e.kind,
                category: category,
                creator: msg.sender,
                createdAt: uint64(block.timestamp)
            })
        );
        emit MarketIndexed(refId, engineId, marketId, category, msg.sender);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function engineCount() external view returns (uint256) {
        return _engines.length;
    }

    function getEngine(uint256 engineId) external view returns (EngineInfo memory) {
        if (engineId >= _engines.length) revert MarketNotFound(engineId);
        return _engines[engineId];
    }

    function isCategoryEnabled(bytes32 category) external view returns (bool) {
        return categories[category].enabled;
    }

    function categoryCount() external view returns (uint256) {
        return _categoryIds.length;
    }

    function categoryAt(uint256 index) external view returns (bytes32) {
        return _categoryIds[index];
    }

    function marketCount() external view returns (uint256) {
        return _markets.length;
    }

    function getMarketRef(uint256 refId) external view returns (MarketRef memory) {
        if (refId >= _markets.length) revert MarketNotFound(refId);
        return _markets[refId];
    }

    /// @notice All indexed markets belonging to a category (view-time filter).
    function getMarketsByCategory(bytes32 category) external view returns (MarketRef[] memory out) {
        uint256 n = _markets.length;
        uint256 count;
        for (uint256 i; i < n; ++i) {
            if (_markets[i].category == category) ++count;
        }
        out = new MarketRef[](count);
        uint256 j;
        for (uint256 i; i < n; ++i) {
            if (_markets[i].category == category) {
                out[j++] = _markets[i];
            }
        }
    }
}
