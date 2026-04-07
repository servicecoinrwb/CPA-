/**
 *Submitted for verification at Arbiscan.io on 2026-04-07
*/

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * ██████╗██████╗  █████╗     ███████╗████████╗ █████╗ ██╗  ██╗██╗███╗   ██╗ ██████╗
 *██╔════╝██╔══██╗██╔══██╗    ██╔════╝╚══██╔══╝██╔══██╗██║ ██╔╝██║████╗  ██║██╔════╝
 *██║     ██████╔╝███████║    ███████╗   ██║   ███████║█████╔╝ ██║██╔██╗ ██║██║  ███╗
 *██║     ██╔═══╝ ██╔══██║    ╚════██║   ██║   ██╔══██║██╔═██╗ ██║██║╚██╗██║██║   ██║
 *╚██████╗██║     ██║  ██║    ███████║   ██║   ██║  ██║██║  ██╗██║██║ ╚████║╚██████╔╝
 * ╚═════╝╚═╝     ╚═╝  ╚═╝    ╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝ ╚═════╝
 *
 * @title   CPAStaking
 * @notice  Stake $CPA tokens and earn $CPA rewards.
 *          Uses the Synthetix reward-per-token accumulator pattern.
 *          No lock period. Withdraw anytime. Rewards stream per second.
 *
 * @dev     Deployment checklist:
 *          1. Deploy this contract with the CPA token address as constructor arg.
 *          2. Transfer CPA reward tokens INTO this contract (fund the rewards pool).
 *          3. Call setRewardRate(n) to start emissions (n = CPA wei per second).
 *          4. Update STAKING_ADDRESS in the website JS.
 *
 * Architecture:
 *   - rewardPerTokenStored  : global accumulator, increases over time
 *   - userRewardPerTokenPaid: per-user snapshot of accumulator at last interaction
 *   - rewards[user]         : accrued but unclaimed CPA for each user
 *
 *   earned(user) = stakedBalance * (rewardPerToken - userSnapshot) + rewards[user]
 */

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract CPAStaking {

    // ── Immutables ────────────────────────────────────────────────────────────
    IERC20  public immutable cpaToken;
    address public           owner;

    // ── Reward State ──────────────────────────────────────────────────────────
    uint256 public rewardRate;            // CPA wei distributed per second (global)
    uint256 public rewardPerTokenStored;  // Accumulator: total reward per staked token (scaled 1e18)
    uint256 public lastUpdateTime;        // Timestamp of last accumulator update
    uint256 public periodFinish;          // Timestamp when current reward period ends
    uint256 public rewardsDuration = 30 days; // Default reward period length

    // ── User State ────────────────────────────────────────────────────────────
    mapping(address => uint256) public stakedBalance;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    // ── Supply ────────────────────────────────────────────────────────────────
    uint256 public totalStaked;

    // ── Events ────────────────────────────────────────────────────────────────
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    event RewardRateSet(uint256 rewardRate, uint256 periodFinish);
    event RewardFunded(uint256 amount);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event EmergencyWithdraw(address indexed user, uint256 amount);

    // ── Errors ────────────────────────────────────────────────────────────────
    error NotOwner();
    error ZeroAmount();
    error InsufficientBalance();
    error TransferFailed();
    error RewardPeriodNotEnded();

    // ── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /**
     * @dev Updates the global accumulator and the caller's personal reward tally
     *      before any state-changing operation. Must run on every stake/unstake/claim.
     */
    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime       = lastTimeRewardApplicable();

        if (account != address(0)) {
            rewards[account]              = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    // ── Constructor ───────────────────────────────────────────────────────────

    constructor(address _cpaToken) {
        cpaToken = IERC20(_cpaToken);
        owner    = msg.sender;
    }

    // ── View Functions ────────────────────────────────────────────────────────

    /**
     * @notice The lesser of now and when the current reward period ends.
     *         Prevents accumulator from running past the funded period.
     */
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    /**
     * @notice Cumulative reward per single staked CPA token (scaled 1e18).
     */
    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;
        return rewardPerTokenStored
            + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * 1e18)
            / totalStaked;
    }

    /**
     * @notice Total CPA rewards earned by `account` (claimed + unclaimed).
     */
    function earned(address account) public view returns (uint256) {
        return (stakedBalance[account] * (rewardPerToken() - userRewardPerTokenPaid[account]))
            / 1e18
            + rewards[account];
    }

    /**
     * @notice How much CPA the contract holds for rewards (unfunded staked tokens excluded).
     */
    function rewardPoolBalance() external view returns (uint256) {
        return cpaToken.balanceOf(address(this)) > totalStaked
            ? cpaToken.balanceOf(address(this)) - totalStaked
            : 0;
    }

    /**
     * @notice Estimated seconds remaining in the current reward period.
     */
    function remainingTime() external view returns (uint256) {
        if (block.timestamp >= periodFinish) return 0;
        return periodFinish - block.timestamp;
    }

    // ── User Actions ──────────────────────────────────────────────────────────

    /**
     * @notice Stake `amount` CPA tokens. Starts earning rewards immediately.
     * @param amount CPA tokens to stake (in wei, i.e. include 18 decimals).
     */
    function stake(uint256 amount) external updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();

        totalStaked                  += amount;
        stakedBalance[msg.sender]    += amount;

        bool ok = cpaToken.transferFrom(msg.sender, address(this), amount);
        if (!ok) revert TransferFailed();

        emit Staked(msg.sender, amount);
    }

    /**
     * @notice Unstake `amount` CPA tokens back to your wallet.
     *         Accrued rewards are NOT auto-claimed — call claimRewards() separately.
     * @param amount CPA tokens to unstake (in wei).
     */
    function unstake(uint256 amount) external updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        if (stakedBalance[msg.sender] < amount) revert InsufficientBalance();

        totalStaked                  -= amount;
        stakedBalance[msg.sender]    -= amount;

        bool ok = cpaToken.transfer(msg.sender, amount);
        if (!ok) revert TransferFailed();

        emit Unstaked(msg.sender, amount);
    }

    /**
     * @notice Claim all pending $CPA rewards to your wallet.
     */
    function claimRewards() external updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward == 0) revert ZeroAmount();

        rewards[msg.sender] = 0;

        bool ok = cpaToken.transfer(msg.sender, reward);
        if (!ok) revert TransferFailed();

        emit RewardClaimed(msg.sender, reward);
    }

    /**
     * @notice Convenience: unstake everything AND claim all rewards in one tx.
     */
    function exit() external updateReward(msg.sender) {
        uint256 staked = stakedBalance[msg.sender];
        uint256 reward = rewards[msg.sender];

        if (staked > 0) {
            totalStaked               -= staked;
            stakedBalance[msg.sender]  = 0;
        }

        if (reward > 0) {
            rewards[msg.sender] = 0;
        }

        uint256 total = staked + reward;
        if (total == 0) revert ZeroAmount();

        bool ok = cpaToken.transfer(msg.sender, total);
        if (!ok) revert TransferFailed();

        if (staked > 0) emit Unstaked(msg.sender, staked);
        if (reward > 0) emit RewardClaimed(msg.sender, reward);
    }

    // ── Owner: Reward Management ──────────────────────────────────────────────

    /**
     * @notice Fund the reward pool by transferring CPA into this contract.
     *         Call BEFORE setRewardRate so the contract holds enough tokens.
     * @param amount CPA tokens to deposit as rewards (in wei).
     */
    function fundRewards(uint256 amount) external onlyOwner updateReward(address(0)) {
        if (amount == 0) revert ZeroAmount();

        bool ok = cpaToken.transferFrom(msg.sender, address(this), amount);
        if (!ok) revert TransferFailed();

        emit RewardFunded(amount);
    }

    /**
     * @notice Set the reward emission rate and start a new reward period.
     *         Automatically handles partial leftover from a previous period.
     *
     * @dev    Example: to emit 10,000 CPA over 30 days:
     *           rate = (10_000 * 1e18) / (30 * 24 * 3600)
     *                = 3_858_024_691_358  (wei per second)
     *
     * @param  _rewardAmount Total CPA to distribute over the next `rewardsDuration`.
     *                       The contract must already hold at least this much CPA
     *                       (above the staked balance) — call fundRewards() first.
     */
    function setRewardRate(uint256 _rewardAmount)
        external
        onlyOwner
        updateReward(address(0))
    {
        if (block.timestamp < periodFinish) {
            // Roll leftover from current period into new period
            uint256 remaining  = periodFinish - block.timestamp;
            uint256 leftover   = remaining * rewardRate;
            rewardRate = (_rewardAmount + leftover) / rewardsDuration;
        } else {
            rewardRate = _rewardAmount / rewardsDuration;
        }

        lastUpdateTime = block.timestamp;
        periodFinish   = block.timestamp + rewardsDuration;

        emit RewardRateSet(rewardRate, periodFinish);
    }

    /**
     * @notice Change the reward period duration (default: 30 days).
     *         Only takes effect on the next setRewardRate() call.
     * @param  _duration New duration in seconds.
     */
    function setRewardsDuration(uint256 _duration) external onlyOwner {
        if (block.timestamp < periodFinish) revert RewardPeriodNotEnded();
        rewardsDuration = _duration;
    }

    // ── Owner: Admin ──────────────────────────────────────────────────────────

    /**
     * @notice Transfer contract ownership to a new address.
     */
    function transferOwnership(address newOwner) external onlyOwner {
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /**
     * @notice Renounce ownership permanently — no more admin functions possible.
     *         Use with caution: rewards can no longer be refunded or rate adjusted.
     */
    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(owner, address(0));
        owner = address(0);
    }

    /**
     * @notice Recover excess reward tokens from the contract after a period ends.
     *         Cannot recover staked user funds — only the surplus above totalStaked.
     * @param  to      Address to send recovered tokens.
     * @param  amount  Amount of CPA to recover (in wei).
     */
    function recoverExcessRewards(address to, uint256 amount)
        external
        onlyOwner
    {
        if (block.timestamp < periodFinish) revert RewardPeriodNotEnded();
        uint256 excess = cpaToken.balanceOf(address(this)) - totalStaked;
        require(amount <= excess, "CPAStaking: amount exceeds excess");
        bool ok = cpaToken.transfer(to, amount);
        if (!ok) revert TransferFailed();
    }
}
