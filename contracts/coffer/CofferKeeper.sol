// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/ICofferKeeper.sol";
import "./interfaces/ICofferOperatorRegistry.sol";
import "./interfaces/ICofferStrategy.sol";
import "./interfaces/ICofferVault.sol";

/// @title CofferKeeper
/// @notice Upkeep = remint path only (`keeperCheck`); harvest is a separate cadence.
contract CofferKeeper is ICofferKeeper, Ownable, ReentrancyGuard {
    uint32 public constant DEFAULT_MIN_INTERVAL = 3;

    struct WatchedStrategy {
        address stratAddr;
        uint32 minInterval;
        uint32 lastUpkeep;
        uint32 lastHarvest;
        bool active;
    }

    ICofferOperatorRegistry public immutable operatorRegistry;
    WatchedStrategy[] public watched;

    error Unauthorized();
    error ZeroAddress();
    error BadId();

    event StrategyAdded(address indexed stratAddr, uint32 minInterval);
    event UpkeepFailed(uint256 indexed id, address indexed stratAddr, bytes reason);
    event VaultPoolValueSnapshot(uint256 indexed id, address indexed vault, address indexed strat, address caller);

    constructor(address operatorRegistry_) Ownable(msg.sender) {
        if (operatorRegistry_ == address(0)) revert ZeroAddress();
        operatorRegistry = ICofferOperatorRegistry(operatorRegistry_);
    }

    modifier onlyOperator() {
        if (!operatorRegistry.isOperator(msg.sender) && msg.sender != owner()) revert Unauthorized();
        _;
    }

    function addStrategy(address strat) external override onlyOwner returns (uint256 id) {
        if (strat == address(0)) revert ZeroAddress();
        watched.push(
            WatchedStrategy({
                stratAddr: strat, minInterval: DEFAULT_MIN_INTERVAL, lastUpkeep: 0, lastHarvest: 0, active: true
            })
        );
        id = watched.length - 1;
        ICofferStrategy(strat).setWatched(true);
        emit StrategyAdded(strat, DEFAULT_MIN_INTERVAL);
    }

    function strategiesLength() external view returns (uint256) {
        return watched.length;
    }

    function updateStrategy(uint256 id, bool active, uint32 minInterval) external onlyOperator {
        if (id >= watched.length) revert BadId();
        WatchedStrategy storage ws = watched[id];
        ws.active = active;
        ws.minInterval = minInterval;
    }

    function performUpkeep(uint256 id) external override nonReentrant onlyOperator {
        _performUpkeep(id, false);
    }

    function performUpkeepBatch(uint256[] calldata ids) external nonReentrant onlyOperator {
        uint256 len = ids.length;
        uint256 maxId = watched.length;
        for (uint256 i = 0; i < len; i++) {
            if (ids[i] >= maxId) continue;
            _performUpkeep(ids[i], true);
        }
    }

    /// @dev `isolate` is set by the batch path so one failing strategy cannot block the others. The
    /// revert reason is emitted, never discarded; the single-id entrypoint propagates it instead.
    function _performUpkeep(uint256 id, bool isolate) internal {
        if (id >= watched.length) revert BadId();
        WatchedStrategy storage ws = watched[id];
        if (!ws.active || ws.stratAddr == address(0)) return;
        if (ws.lastUpkeep != 0 && ws.minInterval > 0 && uint32(block.timestamp) < ws.lastUpkeep + ws.minInterval) {
            return;
        }
        ICofferStrategy strat = ICofferStrategy(ws.stratAddr);
        if (!isolate) {
            if (strat.keeperCheck()) ws.lastUpkeep = uint32(block.timestamp);
            return;
        }
        try strat.keeperCheck() returns (bool worked) {
            if (worked) ws.lastUpkeep = uint32(block.timestamp);
        } catch (bytes memory reason) {
            emit UpkeepFailed(id, ws.stratAddr, reason);
        }
    }

    function performHarvest(uint256 id, bool skipIncreaseLiquidity) external override nonReentrant onlyOperator {
        _performHarvest(id, skipIncreaseLiquidity, false);
    }

    /// @dev Isolated like the upkeep batch: three strategies share one vault here, and one pair's bad hour must not
    ///      stop the other two collecting.
    function performHarvestBatch(uint256[] calldata ids, bool skipIncreaseLiquidity)
        external
        nonReentrant
        onlyOperator
    {
        uint256 len = ids.length;
        uint256 maxId = watched.length;
        for (uint256 i = 0; i < len; i++) {
            if (ids[i] >= maxId) continue;
            _performHarvest(ids[i], skipIncreaseLiquidity, true);
        }
    }

    function _performHarvest(uint256 id, bool skipIncreaseLiquidity, bool isolate) internal {
        if (id >= watched.length) revert BadId();
        WatchedStrategy storage ws = watched[id];
        if (!ws.active || ws.stratAddr == address(0)) return;
        ICofferStrategy strat = ICofferStrategy(ws.stratAddr);
        if (!isolate) {
            strat.harvestBoolean(skipIncreaseLiquidity);
        } else {
            try strat.harvestBoolean(skipIncreaseLiquidity) {}
            catch (bytes memory reason) {
                emit UpkeepFailed(id, ws.stratAddr, reason);
                return;
            }
        }
        ws.lastHarvest = uint32(block.timestamp);
        _recordVaultPoolValueSnapshot(ws.stratAddr);
    }

    /// @notice Record vault NAV + cumulative fees only (does not harvest or increase liquidity).
    function snapshotVaultPoolValue(uint256 id) external override nonReentrant onlyOperator {
        _snapshotVaultPoolValue(id);
    }

    function snapshotVaultPoolValueBatch(uint256[] calldata ids) external nonReentrant onlyOperator {
        uint256 len = ids.length;
        uint256 maxId = watched.length;
        for (uint256 i = 0; i < len; i++) {
            if (ids[i] >= maxId) continue;
            _snapshotVaultPoolValue(ids[i]);
        }
    }

    function _snapshotVaultPoolValue(uint256 id) internal {
        if (id >= watched.length) revert BadId();
        WatchedStrategy storage ws = watched[id];
        if (!ws.active || ws.stratAddr == address(0)) return;
        _recordVaultPoolValueSnapshot(ws.stratAddr);
    }

    function _recordVaultPoolValueSnapshot(address stratAddr) internal {
        address vaultAddr = ICofferStrategy(stratAddr).vault();
        if (vaultAddr == address(0)) revert ZeroAddress();
        ICofferVault(vaultAddr).recordPoolValueSnapshot();
    }
}
