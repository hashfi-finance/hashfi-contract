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

contract ETHSTStakingRewards is IStakingPool, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */

    enum Functions {
        TransferTimeLocker,
        SetRewardRateGear2,
        SetRewardRateThreshold,
        SetReserveAddr,
        SetEmergencyAddr,
        SetRewardsDuration
    }
    uint256 private constant _TIMELOCK = 2 days;
    uint256 private constant _TIMELOCK_PRE = 1 hours;
    mapping(Functions => uint256) public timeLock;
    mapping(Functions => uint256) public stopLock;
    //  The right of updating periodFinish ending time
    uint256 public upPerFinEndTime;

    IERC20 public rewardsToken;
    IERC20 public stakingToken;
    uint256 public periodFinish = 0;
    uint256 public curPeriodReward = 0;
    uint256 public rewardRate = 0;
    uint256 public rewardsDuration = 1 days - 30 minutes;
    uint256 public rewardsDurationPre;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public totalReward;
    uint256 public totalClaimed;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    uint256 public rewardRateMultipler = 100; // 100%
    uint256 public reserveFund = 0;
    uint256 public rewardRateGear2 = 67; // 67% 
    uint256 public rewardRateGear2Pre;
    uint256 public rewardRateThreshold = 6; // 60%
    uint256 public rewardRateThresholdPre;

    address public timeLocker;
    address public paramSetter;
    address public reserveAddr;
    address public emergencyAddr;
    address public proxyAddr;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _rewardsToken,
        address _stakingToken,
        address _timeLocker,
        address _paramSetter,
        address _reserveAddr,
        address _emergencyAddr,
        address _proxyAddr,
        uint256 _upPerFinEndTime
    ) public {
        require(
            _rewardsToken != address(0) &&
            _stakingToken != address(0) &&
            _timeLocker != address(0) &&
            _paramSetter != address(0) &&
            _reserveAddr != address(0) &&
            _emergencyAddr != address(0) &&
            _proxyAddr != address(0)
        );
        rewardsToken = IERC20(_rewardsToken);
        stakingToken = IERC20(_stakingToken);
        timeLocker = _timeLocker;
        paramSetter = _paramSetter;
        reserveAddr = _reserveAddr;
        emergencyAddr = _emergencyAddr;
        proxyAddr = _proxyAddr;
        upPerFinEndTime = _upPerFinEndTime;
    }

    receive() external payable {
        payable(emergencyAddr).transfer(address(this).balance);
    }

    /* ========== INTERNAL ========== */
    function checkSTStakeRate() internal {
        if (stakingToken.totalSupply().mul(rewardRateThreshold).div(10) > _totalSupply) {
            rewardRateMultipler = rewardRateGear2;
            // 67%
        } else {
            rewardRateMultipler = 100;
            // 100%
        }
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
            lastTimeRewardApplicable()
            .sub(lastUpdateTime)
            .mul(rewardRate)
            .mul(rewardRateMultipler)
            .mul(1e18) // for revoiding floating
            .div(100)  // multipler -> percent
            .div(_totalSupply)
        );
    }

    function earned(address account) public override view returns (uint256) {
        return _balances[account].mul(rewardPerToken().sub(userRewardPerTokenPaid[account])).div(1e18).add(rewards[account]);
    }

    function getCurRewardRate() public override view returns (uint256) {
        return rewardRate.mul(rewardRateMultipler).div(100);
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
        require(amount <= _balances[msg.sender], "Balance not enough");
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
            totalClaimed = totalClaimed.add(reward);
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function getReward(address rewardOwner_) public nonReentrant onlyProxy notPaused updateReward(rewardOwner_) {
        uint256 reward = rewards[rewardOwner_];
        if (reward > 0) {
            rewards[rewardOwner_] = 0;
            totalClaimed = totalClaimed.add(reward);
            rewardsToken.safeTransfer(rewardOwner_, reward);
            emit RewardPaid(rewardOwner_, reward);
        }
    }

    function exit() external override {
        withdraw(_balances[msg.sender]);
        getReward();
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function transferTimeLocker(address newTimeLocker) public onlyTimeLocker notLockedThenLock(Functions.TransferTimeLocker) {
        require(newTimeLocker != address(0), "new time locker is the zero address");
        timeLocker = newTimeLocker;
    }

    function transferParamSetter(address newParamSetter) public onlyParamSetter {
        require(newParamSetter != address(0), "new param setter is the zero address");
        paramSetter = newParamSetter;
    }

    function setRewardRateGear2() external onlyParamSetter notLockedThenLock(Functions.SetRewardRateGear2) {
        require(rewardRateGear2 != rewardRateGear2Pre, "rewardRateGear2 has the same value");
        rewardRateGear2 = rewardRateGear2Pre;
    }

    function setRewardRateGear2Pre(uint256 gear2) external onlyParamSetter notStop(Functions.SetRewardRateGear2) {
        rewardRateGear2Pre = gear2;
    }

    function setRewardRateThreshold() external onlyParamSetter notLockedThenLock(Functions.SetRewardRateThreshold) {
        require(rewardRateThresholdPre != rewardRateThreshold, "rewardRateThreshold has the same value");
        rewardRateThreshold = rewardRateThresholdPre;
    }

    function setRewardRateThresholdPre(uint256 threshold) external onlyParamSetter notStop(Functions.SetRewardRateThreshold) {
        rewardRateThresholdPre = threshold;
    }

    function setReserveAddr(address newReserveAddr) external onlyParamSetter notLockedThenLock(Functions.SetReserveAddr) {
        reserveAddr = newReserveAddr;
    }

    function setEmergencyAddr(address newEmergencyAddr) external onlyParamSetter notLockedThenLock(Functions.SetEmergencyAddr) {
        emergencyAddr = newEmergencyAddr;
    }

    function transferReserveFund(uint256 amount) external onlyOwner {
        require(amount <= reserveFund, "Reserve fund not enough");
        uint balance = rewardsToken.balanceOf(address(this));
        require(reserveFund <= balance, "Balance not enough");
        if (amount > 0) {
            rewardsToken.safeTransfer(reserveAddr, amount);
            reserveFund = reserveFund.sub(amount);
        }
    }

    function recoverReward() external onlyOwner updateReward(address(0)){
        uint256 balance = rewardsToken.balanceOf(address(this)).sub(reserveFund);
        uint256 userAssets;
        if (block.timestamp < periodFinish) {
            userAssets = totalReward.sub(totalClaimed).add(getCurRewardRate().mul(block.timestamp.sub(periodFinish)));
        } else {
            userAssets = totalReward.sub(totalClaimed);
        }
        require(balance > userAssets, "No more reward token left");
        rewardsToken.safeTransfer(emergencyAddr, balance.sub(userAssets));
    }

    function recoverStaking() external onlyOwner updateReward(address(0)){
        uint256 balance = stakingToken.balanceOf(address(this));
        require(balance > _totalSupply,"no more staking token left");
        stakingToken.safeTransfer(emergencyAddr, balance.sub(_totalSupply));
    }

    function recoverToken(address tokenAddr, uint256 amount) external onlyOwner {
        require(tokenAddr != address(stakingToken) && tokenAddr != address(rewardsToken), "Can not be stake and reward token");
        IERC20 token = IERC20(tokenAddr);
        uint256 balance = token.balanceOf(address(this));
        require(amount <= balance, "No assets left");
        token.safeTransfer(emergencyAddr, amount);
    }

    // Caution, the `reward` need to be numerically accurate with the actual deposited fund
    function notifyRewardAmount(uint256 reward) external onlyOwner updateReward(address(0)) {
        require(block.timestamp >= periodFinish, "Current period not finished");
        rewardRate = reward.div(rewardsDuration);

        uint256 unclaimedReward = totalReward.sub(totalClaimed);
        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of rewardRate in the earned and rewardsPerToken functions;
        // Reward must be less than 2^256 / 10^18 to avoid overflow.
        uint256 balance = rewardsToken.balanceOf(address(this));
        balance = balance.sub(reserveFund).sub(unclaimedReward);
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

    function setRewardsDurationPre(uint256 _rewardsDuration) external onlyParamSetter notStop(Functions.SetRewardsDuration) {
        rewardsDurationPre = _rewardsDuration;
    }

    function setRewardsDuration() external onlyParamSetter notLockedThenLock(Functions.SetRewardsDuration) {
        require(
            block.timestamp > periodFinish,
            "Previous rewards period must be complete before changing the duration for the new period"
        );
        require(rewardsDuration != rewardsDurationPre, "rewardsDuration has the same value");
        rewardsDuration = rewardsDurationPre;
        emit RewardsDurationUpdated(rewardsDuration);
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
        require(timeLocker == _msgSender(), "caller is not the time locker");
        _;
    }

    modifier onlyParamSetter() {
        require(paramSetter == _msgSender(), "caller is not the param setter");
        _;
    }

    modifier onlyProxy() {
        require(proxyAddr == _msgSender(), "caller is not the proxy");
        _;
    }

    modifier updateReward(address account) {
        // Caution, need to be tested carefully
        if (_totalSupply == 0) {
            reserveFund = reserveFund.add(
                lastTimeRewardApplicable()
                .sub(lastUpdateTime)
                .mul(rewardRate)
            );
        } else {
            if (rewardRateMultipler == rewardRateGear2) {
                uint256 diffBase = 100;
                reserveFund = reserveFund.add(
                    lastTimeRewardApplicable()
                    .sub(lastUpdateTime)
                    .mul(rewardRate)
                    .mul(diffBase.sub(rewardRateMultipler))
                    .div(100)  // multipler -> percent
                );
            }
            totalReward = totalReward.add(
                lastTimeRewardApplicable().sub(lastUpdateTime).mul(rewardRate).mul(rewardRateMultipler).div(100)
            );
        }
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
        // check reward rate after staking or withdrawing
        checkSTStakeRate();
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
