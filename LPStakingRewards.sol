// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import "./Pausable.sol";

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "./interfaces/IStakingPool.sol";

contract LPStakingRewards is IStakingPool, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */

    IERC20 public rewardsToken;
    IERC20 public stakingToken;
    uint256 public periodFinish = 0;
    uint256 public curPeriodReward = 0;
    uint256 public rewardRate = 0;
    uint256 public rewardsDuration = 7 days - 30 minutes;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public totalReward;
    uint256 public totalClaimed;

    address public timeLocker;
    address public paramSetter;
    address public emergencyAddr;
    address public proxyAddr;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    enum Functions {
        TransferTimeLocker,
        SetEmergencyAddr
    }
    uint256 private constant _TIMELOCK = 2 days;
    mapping(Functions => uint256) public timeLock;
    //  The right of updating periodFinish ending time
    uint256 public upPerFinEndTime;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _rewardsToken,
        address _stakingToken,
        address _timeLocker,
        address _paramSetter,
        address _emergencyAddr,
        address _proxyAddr,
        uint256 _upPerFinEndTime
    ) public {
        require(
            _rewardsToken != address(0) &&
            _stakingToken != address(0) &&
            _timeLocker != address(0) &&
            _paramSetter != address(0) &&
            _emergencyAddr != address(0) &&
            _proxyAddr != address(0)
        );
        rewardsToken = IERC20(_rewardsToken);
        stakingToken = IERC20(_stakingToken);
        timeLocker = _timeLocker;
        paramSetter = _paramSetter;
        emergencyAddr = _emergencyAddr;
        proxyAddr = _proxyAddr;
        upPerFinEndTime = _upPerFinEndTime;
    }

    receive() external payable {
        payable(emergencyAddr).transfer(address(this).balance);
    }

    /* ========== VIEWS ========== */

    function totalSupply() external override view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external override view returns (uint256) {
        return _balances[account];
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return Math.min(block.timestamp, periodFinish);
    }

    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return
        rewardPerTokenStored.add(
            lastTimeRewardApplicable().
            sub(lastUpdateTime).
            mul(rewardRate).
            mul(1e18).
            div(_totalSupply)
        );
    }

    function earned(address account) public override view returns (uint256) {
        return _balances[account].mul(rewardPerToken().sub(userRewardPerTokenPaid[account])).div(1e18).add(rewards[account]);
    }

    function getRewardForDuration() external view returns (uint256) {
        return rewardRate.mul(rewardsDuration);
    }

    function getCurRewardRate() external override view returns (uint256){
        return rewardRate;
    }
    /* ========== MUTATIVE FUNCTIONS ========== */

    function stake(uint256 amount) external override nonReentrant notPaused updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        _totalSupply = _totalSupply.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public override nonReentrant notPaused updateReward(msg.sender) {
        require(amount > 0, "Cannot withdraw 0");
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function emergencyWithdraw() public override nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        totalReward = totalReward.sub(reward);
        rewards[msg.sender] = 0;
        uint256 amount = _balances[msg.sender];
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = 0;
        stakingToken.safeTransfer(msg.sender, amount);
        emit EmergencyWithdrawn(msg.sender, amount);
    }

    function getReward() public override nonReentrant notPaused updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardsToken.safeTransfer(msg.sender, reward);
            totalClaimed = totalClaimed.add(reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function getReward(address rewardOwner_) public nonReentrant onlyProxy notPaused updateReward(rewardOwner_) {
        uint256 reward = rewards[rewardOwner_];
        if (reward > 0) {
            rewards[rewardOwner_] = 0;
            rewardsToken.safeTransfer(rewardOwner_, reward);
            totalClaimed = totalClaimed.add(reward);
            emit RewardPaid(rewardOwner_, reward);
        }
    }

    function exit() external override {
        withdraw(_balances[msg.sender]);
        getReward();
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function notifyRewardAmount(uint256 reward) external onlyOwner updateReward(address(0)) {
        if (block.timestamp >= periodFinish) {
            rewardRate = reward.div(rewardsDuration);
        } else {
            uint256 remaining = periodFinish.sub(block.timestamp);
            uint256 leftover = remaining.mul(rewardRate);
            rewardRate = reward.add(leftover).div(rewardsDuration);
        }

        uint256 unclaimedReward = totalReward.sub(totalClaimed);
        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of rewardRate in the earned and rewardsPerToken functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        uint256 balance = rewardsToken.balanceOf(address(this)).sub(unclaimedReward);
        require(rewardRate <= balance.div(rewardsDuration), "Provided reward too high");

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp.add(rewardsDuration);

        curPeriodReward = reward;
        emit RewardAdded(reward);
    }

    // End rewards emission earlier
    function updatePeriodFinish(uint256 timestamp) external onlyOwner updateReward(address(0)) {
        require(block.timestamp <= upPerFinEndTime, "Have not this right");
        if (timestamp < periodFinish) {
            curPeriodReward = curPeriodReward.sub(rewardRate.mul(periodFinish.sub(timestamp)));
        }
        periodFinish = timestamp;
    }

    function setRewardsDuration(uint256 _rewardsDuration) external onlyParamSetter {
        require(
            block.timestamp > periodFinish,
            "Previous rewards period is not complete"
        );
        require(rewardsDuration != _rewardsDuration, "rewardsDuration has the same value");
        rewardsDuration = _rewardsDuration;
        emit RewardsDurationUpdated(rewardsDuration);
    }

    function transferTimeLocker(address newTimeLocker) public onlyTimeLocker notLockedThenLock(Functions.TransferTimeLocker) {
        require(newTimeLocker != address(0), "new time locker is the zero address");
        timeLocker = newTimeLocker;
    }

    function transferParamSetter(address newParamSetter) public onlyParamSetter {
        require(newParamSetter != address(0), "new reward setter is the zero address");
        paramSetter = newParamSetter;
    }

    function setEmergencyAddr(address newEmergencyAddr) external onlyParamSetter notLockedThenLock(Functions.SetEmergencyAddr) {
        require(newEmergencyAddr != address(0), "new Emergency is the zero address");
        emergencyAddr = newEmergencyAddr;
    }

    function recoverReward() external onlyOwner updateReward(address(0)) {
        uint256 balance = rewardsToken.balanceOf(address(this));
        uint256 userAssets;
        if (block.timestamp < periodFinish) {
            userAssets = totalReward.sub(totalClaimed).add(rewardRate.mul(block.timestamp.sub(periodFinish)));
        } else {
            userAssets = totalReward.sub(totalClaimed);
        }
        require(balance > userAssets, "No more reward token left");
        rewardsToken.safeTransfer(emergencyAddr, balance.sub(userAssets));
    }

    function recoverStaking() external onlyOwner updateReward(address(0)) {
        uint balance = stakingToken.balanceOf(address(this));
        require(balance > _totalSupply, "no more staking token left");
        stakingToken.safeTransfer(emergencyAddr, balance.sub(_totalSupply));
    }

    function recoverToken(address tokenAddr, uint256 amount) external onlyOwner {
        require(tokenAddr != address(stakingToken) && tokenAddr != address(rewardsToken), "Can not be stake and reward token");
        IERC20 token = IERC20(tokenAddr);
        uint balance = token.balanceOf(address(this));
        require(amount <= balance, "No assets left");
        token.safeTransfer(emergencyAddr, amount);
    }

    function unlockFunction(Functions _fn) public onlyTimeLocker {
        timeLock[_fn] = block.timestamp.add(_TIMELOCK);
        emit UnLockFunction(_fn);
    }

    function lockFunction(Functions _fn) public onlyTimeLocker {
        timeLock[_fn] = 0;
        emit LockFunction(_fn);
    }

    /* ========== MODIFIERS ========== */

    modifier notLockedThenLock(Functions _fn) {
        require(timeLock[_fn] != 0 && timeLock[_fn] <= block.timestamp, "Function is timeLocked");
        _;
        timeLock[_fn] = 0;
    }

    modifier onlyTimeLocker() {
        require(timeLocker == msg.sender, "caller is not the time locker");
        _;
    }

    modifier onlyParamSetter() {
        require(paramSetter == msg.sender, "caller is not the param setter");
        _;
    }

    modifier onlyProxy() {
        require(proxyAddr == _msgSender(), "caller is not the proxy");
        _;
    }

    modifier updateReward(address account) {
        if (_totalSupply != 0)
            totalReward = totalReward.add(lastTimeRewardApplicable().sub(lastUpdateTime).mul(rewardRate));
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    /* ========== EVENTS ========== */

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event EmergencyWithdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardsDurationUpdated(uint256 newDuration);
    event LockFunction(Functions indexed fn);
    event UnLockFunction(Functions indexed fn);
}
