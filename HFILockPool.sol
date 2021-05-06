pragma solidity ^0.7.0;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

contract HFILockPool is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct Pool {
        uint256 balance;
        //  unlock time of this balance
        uint256 unlockTime;
    }

    IERC20 public HFIToken;

    //  user address => Pool
    mapping(address => Pool[]) public pools;
    //  user address => Pool length
    mapping(address => uint256) public fundLength;
    //  user address => total amount
    mapping(address => uint256) public userTotalAmount;
    uint256 public totalAmount;

    constructor(address HFIToken_) public {
        HFIToken = IERC20(HFIToken_);
    }

    function setFund(address user, uint256 balance_, uint256 unlockTime_) public onlyOwner {
        require(user != address(0), "ERROR: user can not be address(0)");
        require(balance_ > 0, "ERROR: amount is zero");
        require(unlockTime_ > block.timestamp, "ERROR: lock time must bigger than now");
        pools[user].push(Pool({balance : balance_, unlockTime : unlockTime_}));
        fundLength[user] = pools[user].length;
        userTotalAmount[user] = userTotalAmount[user].add(balance_);
        totalAmount = totalAmount.add(balance_);
        require(HFIToken.balanceOf(address(this)) >= totalAmount,"ERROR: balance is not enough");
    }

    function useFund(uint256 index) public {
        require(index < fundLength[msg.sender], "ERROR: index out of Bounds");
        require(block.timestamp >= pools[msg.sender][index].unlockTime, "ERROR: The time hasn't come yet");
        require(pools[msg.sender][index].balance <= HFIToken.balanceOf(address(this)), "ERROR: balance is not enough");
        uint256 balance_ = pools[msg.sender][index].balance;
        if (balance_ != 0) {
            pools[msg.sender][index].balance = 0;
            userTotalAmount[msg.sender] = userTotalAmount[msg.sender].sub(balance_);
            totalAmount = totalAmount.sub(balance_);
            HFIToken.safeTransfer(msg.sender, balance_);
        }
    }

    function recoverHFI() public onlyOwner {
        uint256 balance = HFIToken.balanceOf(address(this));
        require(balance > totalAmount, "No assets left");
        HFIToken.safeTransfer(owner(), balance.sub(totalAmount));
    }
}