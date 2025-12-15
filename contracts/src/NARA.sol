// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
    NARA SYSTEM (Simple Overview)

    There are two contracts:

    1) NARAToken (ERC-20)
       - Fixed supply: 3,333,333 NARA.
       - Every transfer charges a small fee (default 0.1%) that is sent to a feeRecipient.
       - For this game, the feeRecipient should be the NARAMiner contract.
       - The fee received by NARAMiner is counted as "NARA Jackpot".

       Holding NARA also builds up "loyalty tiers" over time:
       - Bronze, Silver, Gold, Platinum, Diamond.
       - The longer and more you hold, the bigger your bonus when mining.

    2) NARAMiner (The Game)
       - Users send ETH to this contract to "mine" NARA.
       - Each mining transaction:
         * Buys "tickets" based on how much ETH you send.
         * Part of the ETH goes to an ETH jackpot.
         * Part of the ETH is stored per epoch (minute) and can later be swept by the treasury.
         * Gives you a chance to win the ETH + NARA jackpot (up to 90% of both).
       - Rewards per epoch are shared based on:
         * Your tickets.
         * Your NARA holding (square-root weighting).
         * Your loyalty tier.
         * Your mining streak.

       Admin (owner/treasury) can:
         - Sweep ETH from finished epochs.
         - Configure game parameters (ticket price, base emission, jackpot share, etc.).
         - Seed NARA into the miner for rewards and liquidity.
         - Recover expired, unclaimed rewards in a safe, limited way.


    High-level for players:
      - Buy and hold NARA to increase your multiplier over time.
      - Send ETH to NARAMiner to mine NARA every minute.
      - Keep a daily streak to stack more bonus.
      - Sometimes, a mining transaction will win most of the ETH+NARA jackpot.
*/

/// --------------------------------------------------------------------------
/// Small interface so NARAToken can notify NARAMiner about fee receipts
/// --------------------------------------------------------------------------
import "./Base.sol";
import "./NARAToken.sol";



/// --------------------------------------------------------------------------
/// NARAMiner (mining game + ETH/NARA jackpot)
/// --------------------------------------------------------------------------
contract NARAMiner is Ownable, ReentrancyGuard, INaraJackpotReceiver {
    NARAToken public immutable token;
    address   public immutable treasury;
    address   public immutable liquidityRecipient;

    uint256 public constant EPOCH_SECONDS = 180;

    uint256 public streakWindowMin = 24 hours;
    uint256 public streakWindowMax = 48 hours;

    uint256 public basePerMin = 1e18;
    uint256 public unitWei   = 2e13;
    uint256 public hardCap   = 10_000;
    uint256 public linearL   = 600;
    uint256 public claimWindowEpochs = 7 days / EPOCH_SECONDS;

    bool    public seeded = false;
    bool    public paramsLocked = false;

    error ParamsLocked();
    error NotSeeded();

    modifier onlyOwnerWhenUnlocked() {
        if (owner() != _msgSender()) revert OwnableUnauthorizedAccount(_msgSender());
        if (paramsLocked) revert ParamsLocked();
        _;
    }

    struct SurgeTier { uint128 thresholdWei; uint128 bonus1e18; }
    SurgeTier[] public tiers;
    uint256 public constant MAX_TOTAL_SURGE_BONUS = 2e18;

    struct Streak { uint64 lastActiveTimestamp; uint32 daysCount; }
    mapping(address => Streak) public streaks;

    mapping(uint256 => mapping(address => uint256)) public tickets;
    mapping(uint256 => uint256) public totalTickets;
    mapping(uint256 => mapping(address => uint256)) public effWeightedUser;
    mapping(uint256 => uint256) public effWeightedTotal;
    mapping(uint256 => mapping(address => bool))    public hasMinedEpoch;

    mapping(uint256 => uint256) public ethBank;
    mapping(uint256 => uint256) public ethForBonus;

    mapping(uint256 => mapping(address => bool)) public claimed;
    mapping(uint256 => uint256) public epochClaimedTotal;
    mapping(uint256 => bool)    public epochRecovered;

    mapping(address => uint256) public pendingRefunds;

    mapping(uint256 => uint256) public epochBasePerMin;
    mapping(uint256 => bool)    public epochInitialized;

    uint256 public rewardTokenPool;

    address public autoMinerRegistry;

    // Holding amount bonus tiers (progressive rewards for all holders)
    // Holding amount bonus tiers (progressive rewards for all holders)
    // REMOVED: Now handled by NARAToken.getHoldingBonus()
    // uint256 public constant HOLD_TIER_1     = 1e18;
    // ...
    // uint256 public constant HOLD_BONUS_100K  = 13000;

    uint256 public jackpotEth;
    uint256 public jackpotNara;

    uint256 public jackpotShareBps = 3000;   // 30% of mining cost -> ETH jackpot
    uint256 public jackpotChanceBps = 25;    // 0.25% chance per mining tx (~1 in 400)
    uint256 public jackpotPayoutShareBps = 9000; // max 90% of pools per win

    // Lifetime aggregates per user
    mapping(address => uint256) public totalEthMined;
    mapping(address => uint256) public totalEthToJackpot;
    mapping(address => uint256) public totalNaraFeesToJackpot;
    mapping(address => uint256) public totalJackpotEthWon;
    mapping(address => uint256) public totalJackpotNaraWon;
    mapping(address => uint256) public jackpotWinsCount;

    event Ticket(uint256 indexed epoch, address indexed user, uint256 amountWei, uint256 addedTickets, uint256 totalTickets);
    event Claimed(uint256 indexed epoch, address indexed user, uint256 amountToken);
    event BatchClaimed(address indexed user, uint256[] epochs, uint256 totalPayout);
    event Swept(uint256 indexed epoch, uint256 amountWei, address to);
    event StreakUpdated(address indexed user, uint256 newStreak, string kind);
    event RefundCredited(address indexed user, uint256 amount);
    event RefundWithdrawn(address indexed user, uint256 amount);
    event ParamUpdated(string knobName, uint256 newValue);
    event Seeded(uint256 amount);
    event EpochRecovered(uint256 indexed epoch, uint256 amount);

    event MinerParamsLocked();

    event JackpotFunded(address indexed from, uint256 amountEth);
    event JackpotWon(address indexed winner, uint256 amountEth, uint256 amountNara);
    event JackpotParamsUpdated(uint256 shareBps, uint256 chanceBps);
    event JackpotPayoutUpdated(uint256 payoutShareBps);
    event NaraFeeToJackpot(address indexed from, uint256 amount);
    event AutoMinerRegistryUpdated(address indexed registry);

    constructor(
        address _token,
        address _treasury,
        address _liquidityRecipient,
        uint128[] memory surgeThresholds,
        uint128[] memory surgeBonuses
    ) Ownable(msg.sender) {
        require(_token != address(0), "Inv Token");
        require(_treasury != address(0), "Inv Treasury");
        require(_liquidityRecipient != address(0), "Inv Liq");

        token = NARAToken(_token);
        treasury = _treasury;
        liquidityRecipient = _liquidityRecipient;

        require(surgeThresholds.length == surgeBonuses.length, "Len Mismatch");
        uint256 len = surgeThresholds.length;
        require(len <= 32, "Too many surge tiers");

        uint256 last = 0;
        uint256 total = 0;
        for (uint256 i = 0; i < len; i++) {
            require(surgeThresholds[i] > last, "Order");
            last = surgeThresholds[i];
            total += surgeBonuses[i];
            tiers.push(SurgeTier(surgeThresholds[i], surgeBonuses[i]));
        }
        require(total <= MAX_TOTAL_SURGE_BONUS, "Bonus Too High");
    }

    /// Called by NARAToken when it sends fee to this contract
    function onNaraFeeReceived(address from, uint256 amount) external override {
        require(msg.sender == address(token), "Not token");
        jackpotNara += amount;
        totalNaraFeesToJackpot[from] += amount;
        emit NaraFeeToJackpot(from, amount);
    }

    receive() external payable nonReentrant { _mineInternal(msg.sender, msg.sender, msg.value, 0, false, block.number - 1); }
    fallback() external payable nonReentrant { require(msg.data.length == 0, "No Func"); _mineInternal(msg.sender, msg.sender, msg.value, 0, false, block.number - 1); }

    function setAutoMinerRegistry(address registry) external onlyOwnerWhenUnlocked {
        autoMinerRegistry = registry;
        emit AutoMinerRegistryUpdated(registry);
    }

    struct PendingMine {
        uint256 blockNumber;
        uint256 deposit;
        uint256 ticketCount;
        bool strictTickets;
        bool finalized;
        address payer;
    }
    mapping(address => mapping(uint256 => PendingMine)) public userRequests;
    mapping(address => uint256) public userRequestCount;
    mapping(address => uint256) public userClaimedCount;

    event MineRequested(address indexed user, uint256 indexed requestId, uint256 ticketCount);
    event MineFinalized(address indexed user, uint256 indexed requestId, bool success);

    function requestMine(uint256 ticketCount) external payable nonReentrant {
        if (!seeded) revert NotSeeded();
        require(ticketCount > 0, "Zero tickets");
        // FIX: Check eligibility at request time to fail early
        require(token.canMine(msg.sender), "Not eligible to mine");
        
        uint256 requiredCost = ticketCount * unitWei;
        require(msg.value >= requiredCost, "Insufficient ETH");

        // FIX: Provide immediate refund for excess ETH to avoid locking it
        // and ensure stored deposit matches cost perfectly for strict checks
        uint256 refund = msg.value - requiredCost;
        if (refund > 0) {
            pendingRefunds[msg.sender] += refund;
            emit RefundCredited(msg.sender, refund);
        }

        uint256 requestId = userRequestCount[msg.sender];
        userRequests[msg.sender][requestId] = PendingMine({
            blockNumber: block.number,
            deposit: requiredCost, // Store EXACT cost
            ticketCount: ticketCount,
            strictTickets: true,
            finalized: false,
            payer: msg.sender
        });
        userRequestCount[msg.sender]++;
        emit MineRequested(msg.sender, requestId, ticketCount);
    }

    function finalizeMines(uint256 count) external nonReentrant {
        uint256 claimed = userClaimedCount[msg.sender];
        uint256 requested = userRequestCount[msg.sender];
        uint256 end = claimed + count;
        if (end > requested) end = requested;

        for (uint256 i = claimed; i < end; i++) {
            PendingMine storage pm = userRequests[msg.sender][i];
            if (pm.finalized) continue;

            if (block.number <= pm.blockNumber) {
                // Not ready yet. Stop processing to save gas.
                end = i; 
                break;
            }

            if (block.number > pm.blockNumber + 256) {
                // Expired. Mark finalized but don't mine.
                // FIX: Refund the deposit for expired requests!
                pm.finalized = true;
                if (pm.deposit > 0) {
                    pendingRefunds[pm.payer] += pm.deposit;
                    emit RefundCredited(pm.payer, pm.deposit);
                }
                emit MineFinalized(msg.sender, i, false);
                continue;
            }

            // Ready!
            
            // FIX: Graceful failure if eligibility is lost between request and finalize
            if (!token.canMine(msg.sender)) {
                pm.finalized = true;
                if (pm.deposit > 0) {
                    pendingRefunds[pm.payer] += pm.deposit;
                    emit RefundCredited(pm.payer, pm.deposit);
                }
                emit MineFinalized(msg.sender, i, false);
                continue;
            }

            pm.finalized = true;
            _mineInternal(msg.sender, pm.payer, pm.deposit, pm.ticketCount, pm.strictTickets, pm.blockNumber);
            emit MineFinalized(msg.sender, i, true);
        }
        userClaimedCount[msg.sender] = end;
    }

    // AutoMiner bypasses 2-step because it's a trusted contract (or bot) that can't easily predict blockhashes
    // If AutoMinerRegistry is malicious, it can game it, but it's an admin-set contract.
    function requestMineFor(address user, uint256 ticketCount) external payable nonReentrant {
        if (!seeded) revert NotSeeded();
        require(msg.sender == autoMinerRegistry, "NARAMiner: not registry");
        require(ticketCount > 0, "Zero tickets");
        // FIX: Check eligibility
        require(token.canMine(user), "Not eligible to mine");
        
        uint256 requiredCost = ticketCount * unitWei;
        require(msg.value >= requiredCost, "Insufficient ETH");

        // FIX: Handle excess
        uint256 refund = msg.value - requiredCost;
        if (refund > 0) {
            pendingRefunds[msg.sender] += refund; // Refund to registry/sender
            emit RefundCredited(msg.sender, refund);
        }

        uint256 requestId = userRequestCount[user];
        userRequests[user][requestId] = PendingMine({
            blockNumber: block.number,
            deposit: requiredCost,
            ticketCount: ticketCount,
            strictTickets: true, // Auto-miner always strict
            finalized: false,
            payer: user
        });
        userRequestCount[user]++;
        emit MineRequested(user, requestId, ticketCount);
    }

    function finalizeMinesFor(address user, uint256 count) external nonReentrant {
        require(msg.sender == autoMinerRegistry, "NARAMiner: not registry");
        
        uint256 claimed = userClaimedCount[user];
        uint256 requested = userRequestCount[user];
        uint256 end = claimed + count;
        if (end > requested) end = requested;

        for (uint256 i = claimed; i < end; i++) {
            PendingMine storage pm = userRequests[user][i];
            if (pm.finalized) continue;

            if (block.number <= pm.blockNumber) {
                end = i; 
                break;
            }

            if (block.number > pm.blockNumber + 256) {
                // FIX: Refund on expiry
                pm.finalized = true;
                if (pm.deposit > 0) {
                    pendingRefunds[pm.payer] += pm.deposit;
                    emit RefundCredited(pm.payer, pm.deposit);
                }
                emit MineFinalized(user, i, false);
                continue;
            }

            // FIX: Graceful check for eligibility
            // Note: For auto-miner, the user might have lost eligibility.
            if (!token.canMine(user)) {
                pm.finalized = true;
                if (pm.deposit > 0) {
                    pendingRefunds[pm.payer] += pm.deposit;
                    emit RefundCredited(pm.payer, pm.deposit);
                }
                emit MineFinalized(user, i, false);
                continue;
            }

            pm.finalized = true;
            _mineInternal(user, pm.payer, pm.deposit, pm.ticketCount, pm.strictTickets, pm.blockNumber);
            emit MineFinalized(user, i, true);
        }
        userClaimedCount[user] = end;
    }
    function _mineInternal(
        address user,
        address payer,
        uint256 msgValue,
        uint256 expectedTickets,
        bool strictTickets,
        uint256 seedBlock
    ) internal {
        require(seeded, "NARAMiner: not seeded");
        require(token.canMine(user), "Must hold >= 0.1 NARA for required duration");

        uint256 e = (block.timestamp / EPOCH_SECONDS);

        uint256 potentialTickets = unitWei > 0 ? msgValue / unitWei : 0;
        require(potentialTickets > 0, "NARAMiner: not enough ETH for 1 ticket");

        if (strictTickets) {
            require(potentialTickets == expectedTickets, "NARAMiner: ticket mismatch");
        }

        uint256 prev = tickets[e][user];
        uint256 acceptedTickets = potentialTickets;

        if (hardCap > 0) {
            require(prev < hardCap, "Epoch Limit Reached");
            if (prev + potentialTickets > hardCap) {
                if (strictTickets) revert("NARAMiner: hard cap reached");
                acceptedTickets = hardCap - prev;
            }
        }

        // Always calculate cost based on accepted tickets and refund any remainder
        // This ensures consistent behavior whether or not hard cap is hit
        uint256 cost = acceptedTickets * unitWei;
        uint256 refund = msgValue - cost;

        if (strictTickets) {
            require(refund == 0, "NARAMiner: refund disallowed");
            require(acceptedTickets == expectedTickets, "NARAMiner: tickets not filled");
        }

        _allocateCost(e, user, cost);
        _recordTickets(e, user, prev, acceptedTickets, cost);

        if (refund > 0) {
            pendingRefunds[payer] += refund;
            emit RefundCredited(payer, refund);
        }

        _maybeTriggerJackpot(user, acceptedTickets, seedBlock);
    }

    function _allocateCost(uint256 epoch, address user, uint256 cost) internal {
        if (cost == 0) return;
        uint256 jackpotCut = (cost * jackpotShareBps) / 10000;
        uint256 epochCut = cost - jackpotCut;

        if (cost > 0) {
            totalEthMined[user] += cost;
        }

        if (jackpotCut > 0) {
            totalEthToJackpot[user] += jackpotCut;
            jackpotEth += jackpotCut;
            emit JackpotFunded(user, jackpotCut);
        }

        ethBank[epoch] += epochCut;
        ethForBonus[epoch] += cost;
    }

    function _recordTickets(
        uint256 epoch,
        address user,
        uint256 prev,
        uint256 acceptedTickets,
        uint256 cost
    ) internal {
        if (acceptedTickets == 0) return;

        if (!epochInitialized[epoch]) {
            epochInitialized[epoch] = true;
            epochBasePerMin[epoch] = basePerMin;
        }

        uint256 next = prev + acceptedTickets;
        uint256 currentMult = _calculateTotalMultiplier(user);

        if (!hasMinedEpoch[epoch][user]) {
            _updateStreak(user);
            currentMult = _calculateTotalMultiplier(user);
            hasMinedEpoch[epoch][user] = true;
        }

        uint256 effPrev = _effective(prev);
        uint256 effNext = _effective(next);
        uint256 deltaEff = effNext - effPrev;
        uint256 weightedDelta = (deltaEff * currentMult) / 10000;

        effWeightedUser[epoch][user] += weightedDelta;
        effWeightedTotal[epoch] += weightedDelta;
        totalTickets[epoch] += acceptedTickets;
        tickets[epoch][user] = next;

        emit Ticket(epoch, user, cost, acceptedTickets, next);
    }

    function withdrawRefund() external nonReentrant {
        uint256 amt = pendingRefunds[msg.sender];
        require(amt > 0, "No Refund");
        pendingRefunds[msg.sender] = 0;
        (bool ok, ) = payable(msg.sender).call{value: amt}("");
        require(ok, "Withdraw Failed");
        emit RefundWithdrawn(msg.sender, amt);
    }

    function _updateStreak(address user) internal {
        Streak storage s = streaks[user];
        uint64 now64 = uint64(block.timestamp);

        if (s.lastActiveTimestamp == 0) {
            s.daysCount = 1;
            s.lastActiveTimestamp = now64;
            emit StreakUpdated(user, 1, "New");
            return;
        }

        uint256 diff = uint256(now64) - uint256(s.lastActiveTimestamp);

        if (diff < streakWindowMin) {
            s.lastActiveTimestamp = now64;
            emit StreakUpdated(user, s.daysCount, "Maintain");
        } else if (diff <= streakWindowMax) {
            s.daysCount++;
            s.lastActiveTimestamp = now64;
            emit StreakUpdated(user, s.daysCount, "Inc");
        } else {
            s.daysCount = 1;
            s.lastActiveTimestamp = now64;
            emit StreakUpdated(user, 1, "Reset");
        }
    }

    function _calculateTotalMultiplier(address user) internal view returns (uint256 totalBps) {
        totalBps = 10000;

        // Get total holding bonus (Tier + Time) from token contract
        uint256 holdingBonus = token.getHoldingBonus(user);
        totalBps += holdingBonus;

        uint32 daysCount = streaks[user].daysCount;
        if (daysCount >= 30) totalBps += 5000;
        else if (daysCount >= 7) totalBps += 2500;
        else if (daysCount >= 3) totalBps += 1000;

        // Holding amount bonus is now included in getHoldingBonus()
        // No manual calculation needed here.
        // All holders get rewarded!
    }

    function _effective(uint256 n) internal view returns (uint256) {
        if (n == 0) return 0;
        uint256 L = linearL;
        if (n <= L) return n;
        unchecked { return L + _sqrt(n - L); }
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function _maybeTriggerJackpot(address user, uint256 ticketsThisTx, uint256 seedBlock) internal {
        if (ticketsThisTx == 0) return;
        if (jackpotChanceBps == 0) return;
        if (jackpotEth == 0 && jackpotNara == 0) return;

        // Secure Randomness: Use blockhash of the seed block (future block from request time)
        // Also mix in prevrandao if available (EVM dependent, but good practice)
        uint256 rand = uint256(
            keccak256(
                abi.encodePacked(
                    blockhash(seedBlock),
                    user,
                    ticketsThisTx,
                    address(this),
                    block.timestamp,
                    block.prevrandao // Mix in beacon chain randomness
                )
            )
        );

        if (rand % 10000 >= jackpotChanceBps) return;

        uint256 payoutEth  = (jackpotEth  * jackpotPayoutShareBps) / 10000;
        uint256 payoutNara = (jackpotNara * jackpotPayoutShareBps) / 10000;

        if (payoutEth == 0 && payoutNara == 0) return;

        // Checks-Effects-Interactions: Update state BEFORE external calls
        if (payoutEth > 0) {
            jackpotEth -= payoutEth;
            totalJackpotEthWon[user] += payoutEth;
        }
        if (payoutNara > 0) {
            jackpotNara -= payoutNara;
            totalJackpotNaraWon[user] += payoutNara;
        }
        jackpotWinsCount[user] += 1;

        emit JackpotWon(user, payoutEth, payoutNara);

        if (payoutEth > 0) {
            (bool okEth, ) = payable(user).call{value: payoutEth}("");
            if (!okEth) {
                pendingRefunds[user] += payoutEth;
                emit RefundCredited(user, payoutEth);
            }
        }
        if (payoutNara > 0) {
            require(token.transfer(user, payoutNara), "Jackpot NARA failed");
        }
    }

    function claim(uint256 e) external nonReentrant {
        uint256 currentEpoch = (block.timestamp / EPOCH_SECONDS);
        require(e < currentEpoch, "Epoch Not Over");
        require(!claimed[e][msg.sender], "Already Claimed");
        require(currentEpoch <= e + claimWindowEpochs, "Claim Expired");
        require(epochInitialized[e], "No Emission");

        uint256 wUser = effWeightedUser[e][msg.sender];
        require(wUser > 0, "No Tickets");

        claimed[e][msg.sender] = true;

        uint256 wTot = effWeightedTotal[e];
        require(wTot > 0, "Math Error");

        uint256 totalEmission = epochBasePerMin[e] + _surgeBonus(ethForBonus[e]);
        uint256 payout = (totalEmission * wUser) / wTot;

        epochClaimedTotal[e] += payout;

        require(rewardTokenPool >= payout, "RewardPool underflow");
        rewardTokenPool -= payout;

        require(token.balanceOf(address(this)) >= payout, "Contract Empty");
        require(token.transfer(msg.sender, payout), "Transfer Failed");

        emit Claimed(e, msg.sender, payout);
    }

    /// @notice Claim multiple epochs in a single transaction
    /// @dev Uses the same validation and accounting as claim() but aggregates payouts
    function claimBatch(uint256[] calldata epochs) external nonReentrant {
        uint256 len = epochs.length;
        require(len > 0, "No epochs");
        require(len <= 100, "Too many epochs");

        uint256 currentEpoch = (block.timestamp / EPOCH_SECONDS);
        uint256 totalPayout = 0;

        for (uint256 i = 0; i < len; ) {
            uint256 e = epochs[i];
            
            // Skip invalid or already claimed epochs instead of reverting
            // This ensures the transaction succeeds for the valid claims
            if (e >= currentEpoch || claimed[e][msg.sender] || !epochInitialized[e]) {
                unchecked { ++i; }
                continue;
            }

            // Check expiration
            if (currentEpoch > e + claimWindowEpochs) {
                 unchecked { ++i; }
                 continue;
            }

            uint256 wUser = effWeightedUser[e][msg.sender];
            if (wUser == 0) {
                 unchecked { ++i; }
                 continue;
            }

            claimed[e][msg.sender] = true;

            uint256 wTot = effWeightedTotal[e];
            // Should not happen if wUser > 0, but safety check
            if (wTot == 0) {
                 unchecked { ++i; }
                 continue;
            }

            uint256 totalEmission = epochBasePerMin[e] + _surgeBonus(ethForBonus[e]);
            uint256 payout = (totalEmission * wUser) / wTot;

            epochClaimedTotal[e] += payout;
            totalPayout += payout;

            emit Claimed(e, msg.sender, payout);

            unchecked {
                ++i;
            }
        }

        if (totalPayout > 0) {
            require(rewardTokenPool >= totalPayout, "RewardPool underflow");
            rewardTokenPool -= totalPayout;
            require(token.balanceOf(address(this)) >= totalPayout, "Contract Empty");
            require(token.transfer(msg.sender, totalPayout), "Transfer Failed");
            emit BatchClaimed(msg.sender, epochs, totalPayout);
        }
    }


    /// @notice Preview the claimable reward for a user in a specific epoch
    /// @param user The user address to preview rewards for
    /// @param epoch The epoch to preview
    /// @return naraAmount The NARA token amount that would be claimed (0 if not claimable)
    /// @dev This function mirrors the exact claim() logic without mutating state
    /// Returns 0 if user cannot claim (epoch not over, already claimed, expired, no tickets, etc.)
    /// NOTE: Only returns NARA amount. Jackpot winnings (ETH + NARA) are paid instantly during mining
    /// and are NOT part of the claimable epoch rewards system.
    function previewClaim(address user, uint256 epoch) external view returns (uint256 naraAmount) {
        uint256 currentEpoch = (block.timestamp / EPOCH_SECONDS);
        
        // Check all claim conditions (mirroring claim() function)
        if (epoch >= currentEpoch) return 0; // Epoch not over
        if (claimed[epoch][user]) return 0; // Already claimed
        if (currentEpoch > epoch + claimWindowEpochs) return 0; // Claim expired
        if (!epochInitialized[epoch]) return 0; // No emission
        
        uint256 wUser = effWeightedUser[epoch][user];
        if (wUser == 0) return 0; // No tickets
        
        uint256 wTot = effWeightedTotal[epoch];
        if (wTot == 0) return 0; // Math error (shouldn't happen if user has tickets)
        
        // Calculate total emission for the epoch
        uint256 totalEmission = epochBasePerMin[epoch] + _surgeBonus(ethForBonus[epoch]);
        
        // Calculate user's share
        uint256 payout = (totalEmission * wUser) / wTot;
        
        // Check if contract has enough tokens (preview should return 0 if insufficient)
        if (rewardTokenPool < payout) return 0;
        if (token.balanceOf(address(this)) < payout) return 0;
        
        return payout;
    }

    struct EpochUserClaimView {
        bool epochInitialized;
        bool claimed;
        bool expired;
        bool canClaim;
        uint256 userWeighted;      // effWeightedUser[epoch][user]
        uint256 totalWeighted;     // effWeightedTotal[epoch]
        uint256 totalEmission;     // epochBasePerMin + surgeBonus
        uint256 claimableAmount;   // same math as previewClaim
    }

    function getEpochUserClaimView(address user, uint256 epoch)
        external
        view
        returns (EpochUserClaimView memory viewData)
    {
        uint256 currentEpoch = block.timestamp / EPOCH_SECONDS;

        viewData.epochInitialized = epochInitialized[epoch];
        viewData.claimed = claimed[epoch][user];
        viewData.expired = currentEpoch > epoch + claimWindowEpochs;

        if (!viewData.epochInitialized || viewData.claimed || viewData.expired || epoch >= currentEpoch) {
            return viewData;
        }

        uint256 wUser = effWeightedUser[epoch][user];
        uint256 wTot  = effWeightedTotal[epoch];

        viewData.userWeighted = wUser;
        viewData.totalWeighted = wTot;

        if (wUser == 0 || wTot == 0) {
            return viewData;
        }

        uint256 totalEmission = epochBasePerMin[epoch] + _surgeBonus(ethForBonus[epoch]);
        viewData.totalEmission = totalEmission;

        uint256 payout = (totalEmission * wUser) / wTot;
        viewData.claimableAmount = payout;
        viewData.canClaim = (rewardTokenPool >= payout && token.balanceOf(address(this)) >= payout);
    }
    function _surgeBonus(uint256 ethWei) internal view returns (uint256 b) {
        uint256 n = tiers.length;
        for (uint256 i = 0; i < n; i++) {
            if (ethWei >= uint256(tiers[i].thresholdWei)) b += uint256(tiers[i].bonus1e18);
        }
    }

    function lockParams() external onlyOwnerWhenUnlocked {
        paramsLocked = true;
        emit MinerParamsLocked();
    }

    function seedLiquidity(uint256 amountToPull) external onlyOwnerWhenUnlocked nonReentrant {
        require(!seeded, "Already Seeded");
        require(amountToPull > 1e18, "Too Low");
        require(token.transferFrom(msg.sender, address(this), amountToPull), "Pull Failed");
        require(token.transfer(liquidityRecipient, 1e18), "Liq Failed");
        seeded = true;

        rewardTokenPool += (amountToPull - 1e18);

        emit Seeded(amountToPull);
    }

    function topUpRewardPool(uint256 amount) external onlyOwnerWhenUnlocked nonReentrant {
        require(amount > 0, "Zero amount");
        require(token.transferFrom(msg.sender, address(this), amount), "Pull Failed");
        rewardTokenPool += amount;
        emit Seeded(amount);
    }

    /// @notice Airdrop tokens from reward pool for testing (testnet only)
    /// @dev Allows owner to transfer tokens from reward pool to users for testing
    function airdropFromRewardPool(address to, uint256 amount) external onlyOwnerWhenUnlocked nonReentrant {
        require(to != address(0), "Zero address");
        require(amount > 0, "Zero amount");
        require(rewardTokenPool >= amount, "Insufficient reward pool");
        require(token.balanceOf(address(this)) >= amount, "Insufficient token balance");
        
        rewardTokenPool -= amount;
        require(token.transfer(to, amount), "Transfer failed");
        emit ParamUpdated("Airdrop", amount);
    }

    function setUnitWei(uint256 v) external onlyOwnerWhenUnlocked {
        require(v > 0, "UnitWei zero");
        unitWei = v;
        emit ParamUpdated("UnitWei", v);
    }

    function setHardCap(uint256 v) external onlyOwnerWhenUnlocked { hardCap = v; emit ParamUpdated("HardCap", v); }
    function setBasePerMin(uint256 v) external onlyOwnerWhenUnlocked { basePerMin = v; emit ParamUpdated("BasePerMin", v); }
    function setLinearL(uint256 v) external onlyOwnerWhenUnlocked { linearL = v; emit ParamUpdated("LinearL", v); }

    function setStreakWindows(uint256 minSeconds, uint256 maxSeconds) external onlyOwnerWhenUnlocked {
        require(minSeconds < maxSeconds, "Invalid Range");
        streakWindowMin = minSeconds;
        streakWindowMax = maxSeconds;
        emit ParamUpdated("StreakMin", minSeconds);
        emit ParamUpdated("StreakMax", maxSeconds);
    }



    // Holding amount tiers are now constants (see HOLD_TIER_* and HOLD_BONUS_* above)
    // Progressive rewards: 1=+4%, 10=+10%, 100=+20%, 1k=+40%, 5k=+60%, 10k=+80%, 100k=+130%

    function setJackpotParams(uint256 shareBps, uint256 chanceBps) external onlyOwnerWhenUnlocked {
        require(shareBps <= 5000, "Too high share");
        require(chanceBps <= 10000, "Chance > 100%");
        jackpotShareBps = shareBps;
        jackpotChanceBps = chanceBps;
        emit JackpotParamsUpdated(shareBps, chanceBps);
    }

    function setJackpotPayoutShareBps(uint256 bps) external onlyOwnerWhenUnlocked {
        require(bps <= 9000, "Too high payout");
        jackpotPayoutShareBps = bps;
        emit JackpotPayoutUpdated(bps);
    }

    /// @notice Sweep expired epoch ETH to treasury (permissionless after conditions met)
    function sweepETH(uint256 e) public nonReentrant {
        require(e < (block.timestamp / EPOCH_SECONDS), "Epoch Active");
        // Security: Prevent sweeping until 24 hours after epoch ends to allow for disputes/verification
        require(block.timestamp > (e * EPOCH_SECONDS) + 24 hours, "Sweep Locked 24h");
        uint256 amt = ethBank[e];
        require(amt > 0, "No ETH");
        (bool ok, ) = payable(treasury).call{value: amt}("");
        require(ok, "Sweep Failed");
        ethBank[e] = 0;
        emit Swept(e, amt, treasury);
    }

    /// @notice Recover unclaimed NARA from expired epochs (works even after params locked)
    /// @dev This ensures expired rewards don't get permanently stuck in the contract
    /// @notice Recover unclaimed NARA from expired epochs (permissionless after conditions met)
    function recoverExpiredNARA(uint256 e) external nonReentrant {
        uint256 currentEpoch = block.timestamp / EPOCH_SECONDS;
        require(currentEpoch > e + (claimWindowEpochs * 2), "Too Soon");
        require(!epochRecovered[e], "Epoch Recovered");

        if (!epochInitialized[e]) {
            epochRecovered[e] = true;
            emit EpochRecovered(e, 0);
            return;
        }

        uint256 epochEmission = epochBasePerMin[e] + _surgeBonus(ethForBonus[e]);
        uint256 claimedSoFar = epochClaimedTotal[e];

        if (epochEmission <= claimedSoFar) {
            epochRecovered[e] = true;
            emit EpochRecovered(e, 0);
            return;
        }

        uint256 recoverable = epochEmission - claimedSoFar;
        require(rewardTokenPool >= recoverable, "RewardPool underflow");
        rewardTokenPool -= recoverable;

        epochRecovered[e] = true;

        require(token.balanceOf(address(this)) >= recoverable, "Insufficient Token Balance");
        require(token.transfer(treasury, recoverable), "Rescue Failed");

        emit EpochRecovered(e, recoverable);
    }

    function getStreakInfo(address user) external view returns (uint32 daysCount, uint256 secondsSinceLastMine, uint256 nextMineWindowStart) {
        Streak memory s = streaks[user];
        daysCount = s.daysCount;
        if (s.lastActiveTimestamp == 0) return (0, 0, 0);
        uint256 nowSec = block.timestamp;
        secondsSinceLastMine = nowSec - s.lastActiveTimestamp;
        nextMineWindowStart = uint256(s.lastActiveTimestamp) + streakWindowMin;
    }

    function getProjectedMultiplier(address user) external view returns (uint256 bps) {
        return _calculateTotalMultiplier(user);
    }

    function isqrt(uint256 x) public pure returns (uint256 y) {
        return _sqrt(x);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BATCH VIEW FUNCTIONS - RPC OPTIMIZATION (1 call instead of 250+)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Complete user dashboard data in ONE call
    /// @param user The user address to query
    /// @return All dashboard data in a single struct
    struct UserDashboard {
        // Current epoch info
        uint256 currentEpoch;
        uint256 epochSecondsRemaining;
        
        // User's pending reward for current epoch
        uint256 pendingTickets;
        uint256 pendingWeighted;
        uint256 pendingTotalWeighted;
        uint256 pendingEstimatedReward;
        
        // User's tier and bonus info
        uint256 holdingBonusBps;
        uint256 streakDays;
        uint256 streakBonusBps;
        uint256 totalMultiplierBps;
        
        // Jackpot pools
        uint256 jackpotEthPool;
        uint256 jackpotNaraPool;
        
        // Contract state
        uint256 rewardPool;
        uint256 currentBasePerMin;
        uint256 ticketPrice;
        bool userCanMine;
    }

    function getUserDashboard(address user) external view returns (UserDashboard memory d) {
        uint256 epoch = block.timestamp / EPOCH_SECONDS;
        d.currentEpoch = epoch;
        d.epochSecondsRemaining = EPOCH_SECONDS - (block.timestamp % EPOCH_SECONDS);
        
        // Pending rewards in current epoch
        d.pendingTickets = tickets[epoch][user];
        d.pendingWeighted = effWeightedUser[epoch][user];
        d.pendingTotalWeighted = effWeightedTotal[epoch];
        
        if (d.pendingTotalWeighted > 0) {
            uint256 baseEm = epochInitialized[epoch] ? epochBasePerMin[epoch] : basePerMin;
            uint256 totalEm = baseEm + _surgeBonus(ethForBonus[epoch]);
            d.pendingEstimatedReward = (totalEm * d.pendingWeighted) / d.pendingTotalWeighted;
        }
        
        // User bonuses
        d.holdingBonusBps = token.getHoldingBonus(user);
        d.streakDays = streaks[user].daysCount;
        if (d.streakDays >= 30) d.streakBonusBps = 5000;
        else if (d.streakDays >= 7) d.streakBonusBps = 2500;
        else if (d.streakDays >= 3) d.streakBonusBps = 1000;
        d.totalMultiplierBps = 10000 + d.holdingBonusBps + d.streakBonusBps;
        
        // Pools
        d.jackpotEthPool = jackpotEth;
        d.jackpotNaraPool = jackpotNara;
        
        // Contract state
        d.rewardPool = rewardTokenPool;
        d.currentBasePerMin = basePerMin;
        d.ticketPrice = unitWei;
        d.userCanMine = token.canMine(user);
    }

    /// @notice Get all claimable epochs for a user in ONE call
    /// @param user User address to query
    /// @param maxEpochs Maximum epochs to scan (recommended: 100)
    /// @return epochs Array of claimable epoch numbers
    /// @return amounts Array of claimable NARA amounts (1:1 with epochs)
    /// @return totalClaimable Sum of all claimable amounts
    function getClaimableEpochsBatch(
        address user,
        uint256 maxEpochs
    ) external view returns (
        uint256[] memory epochs,
        uint256[] memory amounts,
        uint256 totalClaimable
    ) {
        uint256 currentEpoch = block.timestamp / EPOCH_SECONDS;
        if (currentEpoch == 0) {
            return (new uint256[](0), new uint256[](0), 0);
        }
        
        uint256 minEpoch = currentEpoch > claimWindowEpochs ? currentEpoch - claimWindowEpochs : 0;
        
        // First pass: count claimable epochs
        uint256 count = 0;
        uint256 scanned = 0;
        
        for (uint256 e = currentEpoch - 1; e >= minEpoch && scanned < maxEpochs; ) {
            if (_isClaimableView(user, e, currentEpoch)) {
                count++;
            }
            scanned++;
            if (e == 0) break;
            unchecked { e--; }
        }
        
        if (count == 0) {
            return (new uint256[](0), new uint256[](0), 0);
        }
        
        // Allocate exact-sized arrays
        epochs = new uint256[](count);
        amounts = new uint256[](count);
        
        // Second pass: fill arrays
        uint256 idx = 0;
        scanned = 0;
        for (uint256 e = currentEpoch - 1; e >= minEpoch && scanned < maxEpochs && idx < count; ) {
            if (_isClaimableView(user, e, currentEpoch)) {
                epochs[idx] = e;
                amounts[idx] = _calculatePayoutView(user, e);
                totalClaimable += amounts[idx];
                idx++;
            }
            scanned++;
            if (e == 0) break;
            unchecked { e--; }
        }
    }
    
    /// @dev Check if an epoch is claimable for a user (view helper)
    function _isClaimableView(address user, uint256 epoch, uint256 currentEpoch) internal view returns (bool) {
        if (epoch >= currentEpoch) return false;
        if (claimed[epoch][user]) return false;
        if (currentEpoch > epoch + claimWindowEpochs) return false;
        if (!epochInitialized[epoch]) return false;
        if (effWeightedUser[epoch][user] == 0) return false;
        
        // Solvency check: do not show as claimable if contract cannot pay
        uint256 payout = _calculatePayoutView(user, epoch);
        if (rewardTokenPool < payout || token.balanceOf(address(this)) < payout) return false;

        return true;
    }
    
    /// @dev Calculate payout for an epoch (view helper)
    function _calculatePayoutView(address user, uint256 epoch) internal view returns (uint256) {
        uint256 wUser = effWeightedUser[epoch][user];
        uint256 wTot = effWeightedTotal[epoch];
        if (wTot == 0) return 0;
        uint256 totalEmission = epochBasePerMin[epoch] + _surgeBonus(ethForBonus[epoch]);
        return (totalEmission * wUser) / wTot;
    }

    /// @notice Get current epoch parameters for frontend caching
    /// @return info Struct with all epoch-level parameters
    struct EpochParams {
        uint256 currentEpoch;
        uint256 epochSeconds;
        uint256 claimWindow;
        uint256 basePerMinCurrent;
        uint256 ticketPriceWei;
        uint256 hardCapTickets;
    }
    
    function getEpochParams() external view returns (EpochParams memory info) {
        info.currentEpoch = block.timestamp / EPOCH_SECONDS;
        info.epochSeconds = EPOCH_SECONDS;
        info.claimWindow = claimWindowEpochs;
        info.basePerMinCurrent = basePerMin;
        info.ticketPriceWei = unitWei;
        info.hardCapTickets = hardCap;
    }
}

