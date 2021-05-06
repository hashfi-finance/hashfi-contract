// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

contract ETHSTToken is ERC20 {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    enum Functions {
        Mint,
        AddMinter
    }
    uint256 private constant _TIMELOCK = 1 days;
    mapping(Functions => uint256) public timeLock;

    uint256 public cap;
    address public governance;
    address public timeLocker;
    mapping(address => bool) public minters;

    constructor(string memory name, string memory symbol, address timeLocker_, uint256 cap_) public ERC20(name, symbol) {
        require(timeLocker_ != address(0));
        minters[msg.sender] = true;
        governance = msg.sender;
        timeLocker = timeLocker_;
        cap = cap_;
    }

    function mint(address account, uint256 amount) public notLockedThenLock(Functions.Mint) {
        require(minters[msg.sender], "!minter");
        _mint(account, amount);
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal view override(ERC20) {
        if (from == address(0)) {
            require(totalSupply().add(amount) <= cap, "totalSupply exceeds cap");
        }
    }

    function setGovernance(address _governance) public onlyGovernance{
        governance = _governance;
    }

    function addMinter(address _minter) public onlyGovernance notLockedThenLock(Functions.AddMinter) {
        minters[_minter] = true;
    }

    function removeMinter(address _minter) public onlyGovernance{
        minters[_minter] = false;
    }

    function unlockFunction(Functions _fn) public onlyTimeLocker {
        timeLock[_fn] = block.timestamp.add(_TIMELOCK);
        emit UnLockFunction(_fn);
    }

    function lockFunction(Functions _fn) public onlyTimeLocker {
        timeLock[_fn] = 0;
        emit LockFunction(_fn);
    }

    function transferTimeLocker(address timeLocker_) public onlyTimeLocker {
        require(timeLocker_ != address(0), "can't transfer to address(0)");
        timeLocker = timeLocker_;
    }

    modifier notLockedThenLock(Functions _fn) {
        require(timeLock[_fn] != 0 && timeLock[_fn] <= block.timestamp, "Function is timeLocked");
        _;
        timeLock[_fn] = 0;
    }
    modifier onlyTimeLocker() {
        require(timeLocker == msg.sender, "!timeLocker");
        _;
    }
    modifier onlyGovernance() {
        require(governance == msg.sender, "!governance");
        _;
    }

    event LockFunction(Functions indexed fn);
    event UnLockFunction(Functions indexed fn);
}