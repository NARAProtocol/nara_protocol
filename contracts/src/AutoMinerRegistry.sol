// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./NARA.sol";

contract AutoMinerRegistry is Ownable, ReentrancyGuard {
    struct AutoMiningConfig {
        bool enabled;
        bool stopOnAnyJackpot;
        uint32 ticketsPerMine;
        uint32 minesPerWindow;
        uint32 windowEpochs;
        uint32 minesInCurrentWindow;
        uint64 currentWindowStart;
        uint64 lastMinedEpoch;
        uint64 lastJackpotEpochSeen;
        uint256 depositedBalance;
        uint256 stopWinThreshold;
        uint256 totalMined;
    }

    NARAMiner public immutable miner;
    NARAToken public immutable token;
    address public immutable treasury;

    address public bot;

    uint256 public serviceFeeBps = 2500;
    uint256 public constant MAX_SERVICE_FEE_BPS = 2500;
    uint256 public serviceFeePool;

    uint256 public pendingServiceFeeBps;
    uint256 public serviceFeeUpdateTimestamp;
    uint256 public constant FEE_UPDATE_DELAY = 3 days;

    mapping(address => AutoMiningConfig) public configs;
    mapping(address => uint256) public userJackpotWins;
    uint256 public lastGlobalJackpotEpoch;

    event Registered(address indexed user, uint256 ticketsPerMine, uint256 minesPerWindow, uint256 windowEpochs);
    event Deposit(address indexed user, uint256 amount);
    event Withdrawal(address indexed user, uint256 amount);
    event AutoMiningToggled(address indexed user, bool enabled);
    event ScheduleUpdated(address indexed user, uint256 minesPerWindow, uint256 windowEpochs);
    event StopConditionsUpdated(address indexed user, uint256 stopWinThreshold, bool stopOnAnyJackpot);
    event AutoMined(address indexed user, uint256 tickets, uint256 ticketCost, uint256 serviceFee, uint256 epoch);
    event ServiceFeeUpdated(uint256 newFeeBps);
    event ServiceFeeCommitted(uint256 newFeeBps, uint256 effectiveTime);
    event ServiceFeesWithdrawn(address indexed treasury, uint256 amount);
    event BotUpdated(address indexed bot);
    event GlobalJackpotNotified(uint256 epoch);
    event UserJackpotRecorded(address indexed user, uint256 amount);
    event AutoMiningHalted(address indexed user, bytes32 reason);

    error InvalidMiner();
    error FeeTooHigh();
    error NoPendingFee();
    error TimelockActive();
    error InvalidConfig();
    error ZeroDeposit();
    error NotRegistered();
    error InsufficientBalance();
    error WithdrawFailed();
    error ZeroBalance();
    error NotEnabled();
    error PendingMineExists();
    error WindowQuotaExceeded();
    error AlreadyMinedThisEpoch();
    error UnitWeiZero();
    error UserIneligible();
    error NoFees();
    error Unauthorized();

    modifier onlyBotOrOwner() {
        if (msg.sender != bot && msg.sender != owner()) revert Unauthorized();
        _;
    }

    constructor(address _miner, address _bot) Ownable(msg.sender) {
        if (_miner == address(0)) revert InvalidMiner();
        miner = NARAMiner(payable(_miner));
        treasury = miner.treasury();
        token = NARAToken(miner.token());
        bot = _bot;
    }

    receive() external payable {
        revert("AutoMinerRegistry: use deposit()");
    }

    function setBot(address newBot) external onlyOwner {
        bot = newBot;
        emit BotUpdated(newBot);
    }

    function commitServiceFeeBps(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_SERVICE_FEE_BPS) revert FeeTooHigh();
        pendingServiceFeeBps = newFeeBps;
        serviceFeeUpdateTimestamp = block.timestamp + FEE_UPDATE_DELAY;
        emit ServiceFeeCommitted(newFeeBps, serviceFeeUpdateTimestamp);
    }

    function applyServiceFeeBps() external onlyOwner {
        if (serviceFeeUpdateTimestamp == 0) revert NoPendingFee();
        if (block.timestamp < serviceFeeUpdateTimestamp) revert TimelockActive();
        serviceFeeBps = pendingServiceFeeBps;
        serviceFeeUpdateTimestamp = 0;
        emit ServiceFeeUpdated(serviceFeeBps);
    }

    function register(
        uint256 ticketsPerMine,
        uint256 minesPerWindow,
        uint256 windowEpochs,
        uint256 stopWinThreshold,
        bool stopOnAnyJackpot
    ) external payable nonReentrant {
        if (ticketsPerMine == 0) revert InvalidConfig();
        if (minesPerWindow == 0) revert InvalidConfig();
        if (windowEpochs == 0) revert InvalidConfig();
        if (minesPerWindow > windowEpochs) revert InvalidConfig();
        if (ticketsPerMine > type(uint32).max) revert InvalidConfig();
        if (minesPerWindow > type(uint32).max) revert InvalidConfig();
        if (windowEpochs > type(uint32).max) revert InvalidConfig();
        AutoMiningConfig storage cfg = configs[msg.sender];

        cfg.ticketsPerMine = uint32(ticketsPerMine);
        cfg.minesPerWindow = uint32(minesPerWindow);
        cfg.windowEpochs = uint32(windowEpochs);
        cfg.stopWinThreshold = stopWinThreshold;
        cfg.stopOnAnyJackpot = stopOnAnyJackpot;

        uint256 currentEpoch = block.timestamp / miner.EPOCH_SECONDS();
        cfg.currentWindowStart = uint64(currentEpoch - (currentEpoch % windowEpochs));
        cfg.minesInCurrentWindow = 0;
        cfg.lastJackpotEpochSeen = uint64(lastGlobalJackpotEpoch);
        cfg.enabled = false;

        if (msg.value > 0) {
            cfg.depositedBalance += msg.value;
            emit Deposit(msg.sender, msg.value);
        }

        emit Registered(msg.sender, ticketsPerMine, minesPerWindow, windowEpochs);
    }

    function deposit() external payable nonReentrant {
        if (msg.value == 0) revert ZeroDeposit();
        AutoMiningConfig storage cfg = configs[msg.sender];
        if (cfg.ticketsPerMine == 0) revert NotRegistered();
        cfg.depositedBalance += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external nonReentrant {
        AutoMiningConfig storage cfg = configs[msg.sender];
        if (cfg.depositedBalance < amount) revert InsufficientBalance();
        cfg.depositedBalance -= amount;
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert WithdrawFailed();
        emit Withdrawal(msg.sender, amount);
    }

    function emergencyWithdraw() external nonReentrant {
        AutoMiningConfig storage cfg = configs[msg.sender];
        uint256 amount = cfg.depositedBalance;
        if (amount == 0) revert ZeroBalance();
        cfg.depositedBalance = 0;
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert WithdrawFailed();
        emit Withdrawal(msg.sender, amount);
    }

    function enableAutoMining() external {
        AutoMiningConfig storage cfg = configs[msg.sender];
        if (cfg.ticketsPerMine == 0) revert NotRegistered();
        cfg.enabled = true;
        cfg.lastJackpotEpochSeen = uint64(lastGlobalJackpotEpoch);
        emit AutoMiningToggled(msg.sender, true);
    }

    function disableAutoMining() external {
        AutoMiningConfig storage cfg = configs[msg.sender];
        if (cfg.ticketsPerMine == 0) revert NotRegistered();
        cfg.enabled = false;
        emit AutoMiningToggled(msg.sender, false);
    }

    function updateSchedule(uint256 minesPerWindow, uint256 windowEpochs) external {
        if (minesPerWindow == 0) revert InvalidConfig();
        if (windowEpochs == 0) revert InvalidConfig();
        if (minesPerWindow > windowEpochs) revert InvalidConfig();
        if (minesPerWindow > type(uint32).max) revert InvalidConfig();
        if (windowEpochs > type(uint32).max) revert InvalidConfig();

        AutoMiningConfig storage cfg = configs[msg.sender];
        if (cfg.ticketsPerMine == 0) revert NotRegistered();

        cfg.minesPerWindow = uint32(minesPerWindow);
        cfg.windowEpochs = uint32(windowEpochs);

        uint256 currentEpoch = block.timestamp / miner.EPOCH_SECONDS();
        cfg.currentWindowStart = uint64(currentEpoch - (currentEpoch % windowEpochs));
        cfg.minesInCurrentWindow = 0;

        emit ScheduleUpdated(msg.sender, minesPerWindow, windowEpochs);
    }

    function updateStopConditions(uint256 stopWinThreshold, bool stopOnAnyJackpot) external {
        AutoMiningConfig storage cfg = configs[msg.sender];
        if (cfg.ticketsPerMine == 0) revert NotRegistered();
        cfg.stopWinThreshold = stopWinThreshold;
        cfg.stopOnAnyJackpot = stopOnAnyJackpot;
        emit StopConditionsUpdated(msg.sender, stopWinThreshold, stopOnAnyJackpot);
    }

    function notifyGlobalJackpot(uint256 epoch) external onlyBotOrOwner {
        if (epoch > lastGlobalJackpotEpoch) {
            lastGlobalJackpotEpoch = epoch;
            emit GlobalJackpotNotified(epoch);
        }
    }

    function notifyUserJackpot(address user, uint256 amount) external onlyBotOrOwner {
        userJackpotWins[user] += amount;
        AutoMiningConfig storage cfg = configs[user];
        if (cfg.stopWinThreshold > 0 && userJackpotWins[user] >= cfg.stopWinThreshold && cfg.enabled) {
            cfg.enabled = false;
            emit AutoMiningToggled(user, false);
            emit AutoMiningHalted(user, "STOP_THRESHOLD");
        }
        emit UserJackpotRecorded(user, amount);
    }

    function withdrawServiceFees() external onlyOwner nonReentrant {
        uint256 amount = serviceFeePool;
        if (amount == 0) revert NoFees();
        serviceFeePool = 0;
        (bool ok, ) = payable(treasury).call{value: amount}("");
        if (!ok) revert WithdrawFailed();
        emit ServiceFeesWithdrawn(treasury, amount);
    }

    function mineBatch(address[] calldata users) external nonReentrant {
        if (msg.sender != bot && msg.sender != owner()) revert Unauthorized();
        
        uint256 len = users.length;
        for (uint256 i = 0; i < len; ) {
            // Best-effort: skip failed mines so the batch keeps going
            _processMine(users[i], false);
            unchecked { ++i; }
        }
    }

    function mineForUser(address user) external nonReentrant {
        if (user == address(0)) revert InvalidConfig();
        if (msg.sender != bot && msg.sender != user && msg.sender != owner()) {
            revert Unauthorized();
        }
        // Strict mode: revert on failure
        _processMine(user, true);
    }

    function _processMine(address user, bool revertOnFailure) internal {
        // 1. Checks
        AutoMiningConfig storage cfg = configs[user];
        if (!cfg.enabled) { if (revertOnFailure) revert NotEnabled(); return; }
        if (cfg.ticketsPerMine == 0) { if (revertOnFailure) revert NotRegistered(); return; }

        // Pending mine check
        uint256 requested = miner.userRequestCount(user);
        uint256 claimed = miner.userClaimedCount(user);
        if (requested > claimed) {
            (uint256 pendingBlock, , , , , ) = miner.userRequests(user, claimed);
            if (block.number <= pendingBlock) { if (revertOnFailure) revert PendingMineExists(); return; }
            
            // Auto-cleanup if ready
            miner.finalizeMinesFor(user, 1);
            return;
        }

        // Window/Stop Checks
        if (cfg.stopWinThreshold > 0 && userJackpotWins[user] >= cfg.stopWinThreshold) {
            _haltAutoMining(user, "STOP_THRESHOLD");
            return;
        }
        if (cfg.stopOnAnyJackpot && lastGlobalJackpotEpoch > cfg.lastJackpotEpochSeen) {
            cfg.lastJackpotEpochSeen = uint64(lastGlobalJackpotEpoch);
            _haltAutoMining(user, "GLOBAL_JACKPOT");
            return;
        }

        uint256 epochSeconds = miner.EPOCH_SECONDS();
        uint256 currentEpoch = block.timestamp / epochSeconds;

        _syncWindow(cfg, currentEpoch);
        if (cfg.minesInCurrentWindow >= cfg.minesPerWindow) { if (revertOnFailure) revert WindowQuotaExceeded(); return; }
        if (cfg.lastMinedEpoch >= currentEpoch) { if (revertOnFailure) revert AlreadyMinedThisEpoch(); return; }

        if (!token.canMine(user)) { if (revertOnFailure) revert UserIneligible(); return; }

        // 2. Cost Calc
        uint256 unit = miner.unitWei();
        if (unit == 0) { if (revertOnFailure) revert UnitWeiZero(); return; }

        uint256 ticketCost = uint256(cfg.ticketsPerMine) * unit;
        uint256 serviceFee = (ticketCost * serviceFeeBps) / 10000;
        uint256 totalCost = ticketCost + serviceFee;

        if (cfg.depositedBalance < totalCost) { if (revertOnFailure) revert InsufficientBalance(); return; }

        // 3. Effects
        cfg.depositedBalance -= totalCost;
        unchecked {
            if (serviceFee > 0) {
                serviceFeePool += serviceFee;
            }
            cfg.minesInCurrentWindow += 1;
            cfg.totalMined += 1;
        }
        cfg.lastMinedEpoch = uint64(currentEpoch);
        cfg.lastJackpotEpochSeen = uint64(lastGlobalJackpotEpoch);

        // 4. Interactions
        miner.requestMineFor{value: ticketCost}(user, cfg.ticketsPerMine);
        emit AutoMined(user, cfg.ticketsPerMine, ticketCost, serviceFee, currentEpoch);
    }

    function _haltAutoMining(address user, bytes32 reason) internal {
        AutoMiningConfig storage cfg = configs[user];
        if (cfg.enabled) {
            cfg.enabled = false;
            emit AutoMiningToggled(user, false);
            emit AutoMiningHalted(user, reason);
        }
    }

    function shouldMineThisEpoch(address user, uint256 epoch) external view returns (bool) {
        AutoMiningConfig memory cfg = configs[user];
        if (!cfg.enabled || cfg.ticketsPerMine == 0) return false;
        if (cfg.windowEpochs == 0) return false;
        if (cfg.stopWinThreshold > 0 && userJackpotWins[user] >= cfg.stopWinThreshold) return false;
        if (cfg.stopOnAnyJackpot && lastGlobalJackpotEpoch > cfg.lastJackpotEpochSeen) return false;
        if (cfg.lastMinedEpoch >= epoch) return false;
        // Check if user meets mining eligibility requirements
        if (!token.canMine(user)) return false;
        (uint256 windowStart, uint256 minesInWindow) = _previewWindow(cfg, epoch);
        if (epoch < windowStart) return false;
        return minesInWindow < cfg.minesPerWindow;
    }

    function getProjectedCost(address user) external view returns (uint256 totalCost, uint256 ticketCost, uint256 serviceFee) {
        AutoMiningConfig memory cfg = configs[user];
        if (cfg.ticketsPerMine == 0) return (0, 0, 0);
        uint256 unit = miner.unitWei();
        ticketCost = uint256(cfg.ticketsPerMine) * unit;
        serviceFee = (ticketCost * serviceFeeBps) / 10000;
        totalCost = ticketCost + serviceFee;
    }

    function _syncWindow(AutoMiningConfig storage cfg, uint256 currentEpoch) internal {
        if (cfg.windowEpochs == 0) return;

        uint256 windowStart = cfg.currentWindowStart;
        if (windowStart == 0) {
            cfg.currentWindowStart = uint64(currentEpoch - (currentEpoch % cfg.windowEpochs));
            cfg.minesInCurrentWindow = 0;
            return;
        }

        if (currentEpoch >= windowStart + cfg.windowEpochs) {
            uint256 windowsPassed = (currentEpoch - windowStart) / cfg.windowEpochs;
            cfg.currentWindowStart = uint64(windowStart + (windowsPassed * cfg.windowEpochs));
            cfg.minesInCurrentWindow = 0;
        }
    }

    function _previewWindow(AutoMiningConfig memory cfg, uint256 currentEpoch) internal pure returns (uint256 windowStart, uint256 minesInWindow) {
        windowStart = cfg.currentWindowStart;
        minesInWindow = cfg.minesInCurrentWindow;

        if (cfg.windowEpochs == 0) {
            return (0, 0);
        }

        if (windowStart == 0) {
            windowStart = currentEpoch - (currentEpoch % cfg.windowEpochs);
            minesInWindow = 0;
            return (windowStart, minesInWindow);
        }

        if (currentEpoch >= windowStart + cfg.windowEpochs) {
            uint256 windowsPassed = (currentEpoch - windowStart) / cfg.windowEpochs;
            windowStart = windowStart + (windowsPassed * cfg.windowEpochs);
            minesInWindow = 0;
        }

        return (windowStart, minesInWindow);
    }
}

