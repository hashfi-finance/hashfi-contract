// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import './interfaces/ISwapPair.sol';
import './interfaces/IERC20Detail.sol';
import "@openzeppelin/contracts/access/Ownable.sol";
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

interface IStakingRewards {
    function getReward(address) external;
}

contract Query is Ownable {
    address public ethSTStakingRewards;
    address public hfiStakingRewards;
    address public lpEthSTStakingRewards;
    address public lpHFIStakingRewards;

    constructor() public {}

    function setPools(
        address _ethSTStakingRewards,
        address _hfiStakingRewards,
        address _lpEthSTStakingRewards,
        address _lpHFIStakingRewards
    ) public onlyOwner {
        require(
            _ethSTStakingRewards != address(0) &&
            _hfiStakingRewards != address(0) &&
            _lpEthSTStakingRewards != address(0) &&
            _lpHFIStakingRewards != address(0)
        );
        ethSTStakingRewards = _ethSTStakingRewards;
        hfiStakingRewards = _hfiStakingRewards;
        lpEthSTStakingRewards = _lpEthSTStakingRewards;
        lpHFIStakingRewards = _lpHFIStakingRewards;
    }

    function getAllRewards() external {
        require(
            ethSTStakingRewards != address(0) &&
            hfiStakingRewards != address(0) &&
            lpEthSTStakingRewards != address(0) &&
            lpHFIStakingRewards != address(0)
        );
        IStakingRewards(ethSTStakingRewards).getReward(msg.sender);
        IStakingRewards(hfiStakingRewards).getReward(msg.sender);
        IStakingRewards(lpEthSTStakingRewards).getReward(msg.sender);
        IStakingRewards(lpHFIStakingRewards).getReward(msg.sender);
    }

    function getSwapPairReserve(address _pair) public view returns (address token0, address token1, uint8 decimals0, uint8 decimals1, uint reserve0, uint reserve1, uint totalSupply) {
        totalSupply = ISwapPair(_pair).totalSupply();
        token0 = ISwapPair(_pair).token0();
        token1 = ISwapPair(_pair).token1();
        decimals0 = IERC20Detail(token0).decimals();
        decimals1 = IERC20Detail(token1).decimals();
        (reserve0, reserve1,) = ISwapPair(_pair).getReserves();
    }
}