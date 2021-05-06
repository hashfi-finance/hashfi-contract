pragma solidity ^0.7.0;

// Uniswap Standard Pair
// e.g. https://etherscan.io/address/0x9da4c85487840c7b4903f46f600bea23d7c49bdc#code
interface ISwapPair {
    function totalSupply() external view returns (uint256);

    function token0() external view returns (address);

    function token1() external view returns (address);

    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}
