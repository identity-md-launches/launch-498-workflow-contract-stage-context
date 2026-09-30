// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ICityGrants {
    function grantResources(uint256 cityId, uint256 amount) external;
    function recordHeartbeat(
        uint256 cityId1,
        uint256 amount1,
        uint256 cityId2,
        uint256 amount2,
        uint256 cityId3,
        uint256 amount3
    ) external;
}

/// @notice Immutable operator gate for resource grants. No custody or general-purpose execution.
/// @dev Deploy before CityRegistry; each call supplies the registry to avoid a constructor cycle.
contract GrantExecutor {
    error InvalidOperator();
    error Unauthorized();
    error GrantsPaused();
    error InvalidRegistry();
    error AlreadyPaused();
    error NotPaused();

    event GrantsPauseChanged(bool paused);

    address public immutable operator;
    bool public grantsPaused;

    constructor(address operator_) {
        if (operator_ == address(0)) revert InvalidOperator();
        operator = operator_;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert Unauthorized();
        _;
    }

    modifier whenGrantsLive(address registry) {
        if (grantsPaused) revert GrantsPaused();
        if (registry.code.length == 0) revert InvalidRegistry();
        _;
    }

    function pauseGrants() external onlyOperator {
        if (grantsPaused) revert AlreadyPaused();
        grantsPaused = true;
        emit GrantsPauseChanged(true);
    }

    function unpauseGrants() external onlyOperator {
        if (!grantsPaused) revert NotPaused();
        grantsPaused = false;
        emit GrantsPauseChanged(false);
    }

    function grantResources(address registry, uint256 cityId, uint256 amount)
        external
        onlyOperator
        whenGrantsLive(registry)
    {
        ICityGrants(registry).grantResources(cityId, amount);
    }

    function recordHeartbeat(
        address registry,
        uint256 cityId1,
        uint256 amount1,
        uint256 cityId2,
        uint256 amount2,
        uint256 cityId3,
        uint256 amount3
    ) external onlyOperator whenGrantsLive(registry) {
        ICityGrants(registry).recordHeartbeat(cityId1, amount1, cityId2, amount2, cityId3, amount3);
    }
}
