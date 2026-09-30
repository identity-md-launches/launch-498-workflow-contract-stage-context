// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IGridToken {
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Soulbound Swarm Cities, funded by explicit purchase fees on plain GRID transfers.
/// @dev Intended exclusively for LaunchToken. Resource credits have 18 decimals and cannot be redeemed.
contract CityRegistry {
    uint256 public constant PLOT_COUNT = 256;
    uint256 public constant MAX_LEVEL = 20;
    uint256 public constant MIN_HOLDING = 1000 ether;
    uint256 public constant RESOURCE_UNIT = 1 ether;
    uint256 public constant REWARD_SCALE = 1e27;

    struct City {
        address owner;
        uint256 level;
        uint256 resources;
    }

    struct HeartbeatWinner {
        uint256 cityId;
        uint256 amount;
    }

    error InvalidConfiguration();
    error InvalidCity();
    error CityOccupied();
    error AlreadyOwnsCity();
    error InsufficientHolding();
    error NotCityOwner();
    error CityUnowned();
    error SoldOut();
    error MaximumLevel();
    error InsufficientResources();
    error Unauthorized();
    error InvalidAmount();
    error InsufficientResourcePot();
    error DuplicateWinner();
    error NothingToClaim();
    error TokenTransferFailed();
    error ReentrantCall();

    event CityBought(uint256 indexed cityId, address indexed owner, uint256 price, uint256 fee);
    event TaxTaken(
        address indexed payer, uint256 fee, uint256 rewards, uint256 resources, uint256 burned, uint256 treasuryAmount
    );
    event ResourcesGranted(uint256 indexed cityId, uint256 amount);
    event CityLeveled(uint256 indexed cityId, uint256 level, uint256 resourcesConsumed);
    event RewardsClaimed(uint256 indexed cityId, address indexed owner, uint256 amount);
    event HeartbeatRecorded(
        uint256 indexed sequence,
        uint256 cityId1,
        uint256 amount1,
        uint256 cityId2,
        uint256 amount2,
        uint256 cityId3,
        uint256 amount3
    );

    IGridToken public immutable token;
    address public immutable grantExecutor;
    address public immutable treasury;
    mapping(uint256 => City) public cities;
    /// @notice Encodes cityId + 1; zero means the wallet owns no city.
    mapping(address => uint256) public cityOf;
    uint256 public soldPlots;
    uint256 public totalWeight;
    uint256 public rewardsPool;
    uint256 public resourcePot;
    /// @notice Cumulative GRID permanently committed to game resources, including spent resources.
    uint256 public resourcesAllocated;
    uint256 public rewardIndex;
    mapping(uint256 => uint256) private rewardIndexPaid;
    mapping(uint256 => uint256) private accruedScaled;
    HeartbeatWinner[3] public lastHeartbeat;
    uint256 public heartbeatCount;
    uint256 public lastHeartbeatTimestamp;
    uint256 private entered;

    /// @dev Roles are explicit because the deploying factory cannot operate this application.
    constructor(address token_, address grantExecutor_, address treasury_) {
        if (
            token_ == address(0) || grantExecutor_ == address(0) || token_.code.length == 0
                || grantExecutor_.code.length == 0 || treasury_ == address(0)
        ) {
            revert InvalidConfiguration();
        }
        if (IGridToken(token_).decimals() != 18) revert InvalidConfiguration();
        token = IGridToken(token_);
        grantExecutor = grantExecutor_;
        treasury = treasury_;
    }

    modifier nonReentrant() {
        if (entered != 0) revert ReentrantCall();
        entered = 1;
        _;
        entered = 0;
    }

    modifier onlyGrantExecutor() {
        if (msg.sender != grantExecutor) revert Unauthorized();
        _;
    }

    function coordinates(uint256 cityId) external pure returns (uint256 x, uint256 y) {
        _validId(cityId);
        return (cityId % 16, cityId / 16);
    }

    /// @notice Base price in GRID minor units; reverts once every plot is sold.
    function price() public view returns (uint256) {
        if (soldPlots == PLOT_COUNT) revert SoldOut();
        uint256 step = PLOT_COUNT + soldPlots;
        return 10_000 ether * step * step / 65_536;
    }

    function quote() public view returns (uint256 basePrice, uint256 fee, uint256 total) {
        basePrice = price();
        fee = basePrice * 4 / 100;
        total = basePrice + fee;
    }

    /// @notice Approve exactly quote().total first to bound exposure to intervening purchases.
    function buyCity(uint256 cityId) external nonReentrant {
        _validId(cityId);
        if (cities[cityId].owner != address(0)) revert CityOccupied();
        if (cityOf[msg.sender] != 0) revert AlreadyOwnsCity();
        if (token.balanceOf(msg.sender) < MIN_HOLDING) revert InsufficientHolding();
        (uint256 basePrice, uint256 fee, uint256 total) = quote();
        uint256 forRewards = fee * 50 / 100;
        uint256 forResources = fee * 30 / 100;
        uint256 toBurn = fee * 10 / 100;
        uint256 forTreasury = fee - forRewards - forResources - toBurn;

        cities[cityId] = City(msg.sender, 1, 0);
        cityOf[msg.sender] = cityId + 1;
        rewardIndexPaid[cityId] = rewardIndex;
        ++soldPlots;
        ++totalWeight;
        rewardsPool += forRewards;
        resourcePot += forResources;
        // The new city joins this distribution, but receives none of the preceding purchases.
        // Division dust remains in rewardsPool; it is never reassigned to subsequent owners.
        rewardIndex += forRewards * REWARD_SCALE / totalWeight;

        emit CityBought(cityId, msg.sender, basePrice, fee);
        emit TaxTaken(msg.sender, fee, forRewards, forResources, toBurn, forTreasury);

        if (!token.transferFrom(msg.sender, address(this), total)) revert TokenTransferFailed();
        // LaunchToken accepts zero-address sink transfers while preserving nominal fixed supply.
        if (!token.transfer(address(0), basePrice + toBurn)) revert TokenTransferFailed();
        if (!token.transfer(treasury, forTreasury)) revert TokenTransferFailed();
    }

    function levelUpCost(uint256 cityId) public view returns (uint256) {
        City storage city = _ownedCity(cityId);
        if (city.level == MAX_LEVEL) revert MaximumLevel();
        uint256 next = city.level + 1;
        return 100 * RESOURCE_UNIT * next * next;
    }

    function levelUp(uint256 cityId) external nonReentrant {
        City storage city = _callerCity(cityId);
        uint256 cost = levelUpCost(cityId);
        if (city.resources < cost) revert InsufficientResources();
        _checkpoint(cityId, city.level);
        uint256 oldWeight = city.level * city.level;
        city.resources -= cost;
        ++city.level;
        totalWeight = totalWeight - oldWeight + city.level * city.level;
        emit CityLeveled(cityId, city.level, cost);
    }

    function claimableRewards(uint256 cityId) public view returns (uint256) {
        City storage city = _ownedCity(cityId);
        return
            (accruedScaled[cityId] + (rewardIndex - rewardIndexPaid[cityId]) * city.level * city.level) / REWARD_SCALE;
    }

    function claimRewards(uint256 cityId) external nonReentrant returns (uint256 amount) {
        City storage city = _callerCity(cityId);
        _checkpoint(cityId, city.level);
        amount = accruedScaled[cityId] / REWARD_SCALE;
        if (amount == 0) revert NothingToClaim();
        accruedScaled[cityId] %= REWARD_SCALE;
        rewardsPool -= amount;
        emit RewardsClaimed(cityId, msg.sender, amount);
        if (!token.transfer(msg.sender, amount)) revert TokenTransferFailed();
    }

    function grantResources(uint256 cityId, uint256 amount) external nonReentrant onlyGrantExecutor {
        _grant(cityId, amount);
    }

    /// @notice Atomically allocate resources to three distinct cities and record the latest winners.
    function recordHeartbeat(
        uint256 cityId1,
        uint256 amount1,
        uint256 cityId2,
        uint256 amount2,
        uint256 cityId3,
        uint256 amount3
    ) external nonReentrant onlyGrantExecutor {
        if (cityId1 == cityId2 || cityId1 == cityId3 || cityId2 == cityId3) revert DuplicateWinner();
        _grant(cityId1, amount1);
        _grant(cityId2, amount2);
        _grant(cityId3, amount3);
        lastHeartbeat[0] = HeartbeatWinner(cityId1, amount1);
        lastHeartbeat[1] = HeartbeatWinner(cityId2, amount2);
        lastHeartbeat[2] = HeartbeatWinner(cityId3, amount3);
        ++heartbeatCount;
        lastHeartbeatTimestamp = block.timestamp;
        emit HeartbeatRecorded(heartbeatCount, cityId1, amount1, cityId2, amount2, cityId3, amount3);
    }

    function _grant(uint256 cityId, uint256 amount) private {
        City storage city = _ownedCity(cityId);
        if (amount == 0) revert InvalidAmount();
        if (amount > resourcePot) revert InsufficientResourcePot();
        resourcePot -= amount;
        resourcesAllocated += amount;
        city.resources += amount;
        emit ResourcesGranted(cityId, amount);
    }

    function _checkpoint(uint256 cityId, uint256 level) private {
        accruedScaled[cityId] += (rewardIndex - rewardIndexPaid[cityId]) * level * level;
        rewardIndexPaid[cityId] = rewardIndex;
    }

    function _callerCity(uint256 cityId) private view returns (City storage city) {
        city = _ownedCity(cityId);
        if (city.owner != msg.sender) revert NotCityOwner();
    }

    function _ownedCity(uint256 cityId) private view returns (City storage city) {
        _validId(cityId);
        city = cities[cityId];
        if (city.owner == address(0)) revert CityUnowned();
    }

    function _validId(uint256 cityId) private pure {
        if (cityId >= PLOT_COUNT) revert InvalidCity();
    }
}
