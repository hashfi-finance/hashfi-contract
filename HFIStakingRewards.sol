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

contract HFIStakingRewards is IStakingPool, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */

    IERC20 public hfiToken;
    uint256 public periodFinish;
    uint256 public curPeriodReward;
    uint256 public rewardRate;
    uint256 public rewardsDuration = 7 days - 30 minutes;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint128 public lockUpTime = 10 days;
    uint128 public lockUpTimePre;
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

    struct UserStakeLocked {
        //  user address => latest timestamp of interact stake & withdraw
        uint256 userLatestStakeTime;
        //  user address => unlocked amount
        uint256 userFreeAmount;
        //  user address => the unlock rate; (pending unlock amount + new stake amount) / lockUpTime
        uint256 userFreeRate;
    }

    mapping(address => UserStakeLocked) public userStakeLocked;

    enum Functions {
        SetLockUpTime,
        TransferTimeLocker,
        SetEmergencyAddr
    }
    uint256 private constant _TIMELOCK = 2 days;
    uint256 private constant _TIMELOCK_PRE = 1 hours;
    mapping(Functions => uint256) public timeLock;
    mapping(Functions => uint256) public stopLock;
    //  The right of updating periodFinish ending time
    uint256 public upPerFinEndTime;
    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _hfiToken,
        address _timeLocker,
        address _paramSetter,
        address _emergencyAddr,
        address _proxyAddr,
        uint256 _upPerFinEndTime
    ) public {
        require(
            _hfiToken != address(0) &&
            _timeLocker != address(0) &&
            _paramSetter != address(0) &&
            _emergencyAddr != address(0) &&
            _proxyAddr != address(0)
        );
        hfiToken = IERC20(_hfiToken);
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
            lastTimeRewardApplicable().sub(lastUpdateTime).mul(rewardRate).mul(1e18).div(_totalSupply)
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

    /// @notice calculate the latest free amount of user
    /// @dev newUserFreeAmount_ = userFreeAmount_ + passedTime * userFreeRate_ / e18;If the passed time is greater than lockUpTime, the free amount is _balances[_user]
    /// @param _user The user address
    /// @return newUserFreeAmount_ The latest free amount of user
    function newUserFreeAmount(address _user) private view returns (uint256 newUserFreeAmount_){
        uint256 userFreeAmount_ = userStakeLocked[_user].userFreeAmount;
        uint256 userLatestStakeTime_ = userStakeLocked[_user].userLatestStakeTime;
        uint256 userFreeRate_ = userStakeLocked[_user].userFreeRate;
        uint256 passedTime = block.timestamp.sub(userLatestStakeTime_);
        if (passedTime >= lockUpTime) {
            newUserFreeAmount_ = _balances[_user];
        } else {
            newUserFreeAmount_ = userFreeAmount_.add(passedTime.mul(userFreeRate_).div(1e18));
        }
        return newUserFreeAmount_;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function stake(uint256 amount) external override nonReentrant notPaused updateReward(msg.sender) {
        require(amount != 0, "Cannot stake 0");
        uint256 newUserFreeAmount_ = newUserFreeAmount(msg.sender);
        userStakeLocked[msg.sender] = UserStakeLocked({
            userLatestStakeTime : block.timestamp,
            userFreeAmount : newUserFreeAmount_,
            userFreeRate : _balances[msg.sender].sub(newUserFreeAmount_).add(amount).mul(1e18).div(lockUpTime)
        });
        _totalSupply = _totalSupply.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);
        hfiToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public override nonReentrant notPaused updateReward(msg.sender) {
        require(amount != 0, "Cannot withdraw 0");
        uint256 newUserFreeAmount_ = newUserFreeAmount(msg.sender);
        require(amount <= newUserFreeAmount_, "Exceed free amount");
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        userStakeLocked[msg.sender].userFreeAmount = newUserFreeAmount_.sub(amount);
        userStakeLocked[msg.sender].userLatestStakeTime = block.timestamp;
        hfiToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function emergencyWithdraw() public override nonReentrant updateReward(msg.sender) {
        uint256 newUserFreeAmount_ = newUserFreeAmount(msg.sender);
        _totalSupply = _totalSupply.sub(newUserFreeAmount_);
        _balances[msg.sender] = _balances[msg.sender].sub(newUserFreeAmount_);
        userStakeLocked[msg.sender].userFreeAmount = 0;
        userStakeLocked[msg.sender].userLatestStakeTime = block.timestamp;

        uint256 reward = rewards[msg.sender];
        totalReward = totalReward.sub(reward);
        rewards[msg.sender] = 0;
        hfiToken.safeTransfer(msg.sender, newUserFreeAmount_);
        emit EmergencyWithdrawn(msg.sender, newUserFreeAmount_);
    }

    function getReward() public override nonReentrant notPaused updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            totalClaimed = totalClaimed.add(reward);
            require(hfiToken.balanceOf(address(this)).sub(reward) >= _totalSupply, "Can't be smaller then staking amount");
            hfiToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function getReward(address rewardOwner_) public nonReentrant onlyProxy notPaused updateReward(rewardOwner_) {
        uint256 reward = rewards[rewardOwner_];
        if (reward > 0) {
            rewards[rewardOwner_] = 0;
            totalClaimed = totalClaimed.add(reward);
            require(hfiToken.balanceOf(address(this)).sub(reward) >= _totalSupply, "Can't be smaller then staking amount");
            hfiToken.safeTransfer(rewardOwner_, reward);
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
        uint256 balance = hfiToken.balanceOf(address(this)).sub(_totalSupply).sub(unclaimedReward);
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
            "Previous period is not complete"
        );
        require(rewardsDuration != _rewardsDuration, "rewardsDuration has the same value");
        rewardsDuration = _rewardsDuration;
        emit RewardsDurationUpdated(rewardsDuration);
    }

    function setLockUpTime() external onlyParamSetter notLockedThenLock(Functions.SetLockUpTime) {
        lockUpTime = lockUpTimePre;
    }

    function setLockUpTimePre(uint128 _lockUpTime) external onlyParamSetter notStop(Functions.SetLockUpTime) {
        require(_lockUpTime <= 30 days && _lockUpTime >= 5 days, "lock time should between 5 days and 30 days");
        lockUpTimePre = _lockUpTime;
    }

    function transferTimeLocker(address newTimeLocker) public onlyTimeLocker notLockedThenLock(Functions.TransferTimeLocker) {
        require(newTimeLocker != address(0), "new time locker is the zero address");
        timeLocker = newTimeLocker;
    }

    function transferRewardSetter(address newParamSetter) public onlyParamSetter {
        require(newParamSetter != address(0), "new reward setter is the zero address");
        paramSetter = newParamSetter;
    }

    function setEmergencyAddr(address newEmergencyAddr) external onlyParamSetter notLockedThenLock(Functions.SetEmergencyAddr) {
        require(newEmergencyAddr != address(0), "new Emergency is the zero address");
        emergencyAddr = newEmergencyAddr;
    }

    function recoverHFI() external onlyOwner updateReward(address(0)) {
        uint256 balance = hfiToken.balanceOf(address(this));
        uint256 userAssets;
        if (block.timestamp < periodFinish) {
            userAssets = _totalSupply.add(totalReward.sub(totalClaimed)).add(rewardRate.mul(block.timestamp.sub(periodFinish)));
        } else {
            userAssets = _totalSupply.add(totalReward.sub(totalClaimed));
        }
        require(balance > userAssets, "No assets left");
        hfiToken.safeTransfer(emergencyAddr, balance.sub(userAssets));
    }

    function recoverToken(address tokenAddr, uint256 amount) external onlyOwner {
        require(tokenAddr != address(hfiToken), "Can not be hfi token");
        IERC20 token = IERC20(tokenAddr);
        uint balance = token.balanceOf(address(this));
        require(amount <= balance, "No assets left");
        token.safeTransfer(emergencyAddr, amount);
    }

    function activeSwitch(Functions _fn) public onlyTimeLocker {
        unlockFunction(_fn);
        unlockFunctionPre(_fn);
    }

    function unlockFunction(Functions _fn) public onlyTimeLocker {
        timeLock[_fn] = block.timestamp.add(_TIMELOCK);
        emit UnLockFunction(_fn);
    }

    function lockFunction(Functions _fn) public onlyTimeLocker {
        timeLock[_fn] = 0;
        emit LockFunction(_fn);
    }

    function unlockFunctionPre(Functions _fn) internal onlyTimeLocker {
        stopLock[_fn] = block.timestamp.add(_TIMELOCK_PRE);
    }

    function lockFunctionPre(Functions _fn) public onlyTimeLocker {
        stopLock[_fn] = 0;
    }
    /* ========== MODIFIERS ========== */

    modifier notLockedThenLock(Functions _fn) {
        require(timeLock[_fn] != 0 && timeLock[_fn] <= block.timestamp, "Function is timeLocked");
        _;
        timeLock[_fn] = 0;
    }

    modifier notStop(Functions _fn) {
        require(stopLock[_fn] >= block.timestamp, "Function is stopped");
        _;
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
        require(proxyAddr == msg.sender, "caller is not the proxy");
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
