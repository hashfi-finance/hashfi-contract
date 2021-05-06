pragma solidity ^0.7.0;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract HFIToken is ERC20, Ownable {
    using SafeMath for uint256;

    uint256 public cap;

    constructor(string memory name, string memory symbol, uint256 cap_) public ERC20(name, symbol){
        cap = cap_;
    }

    function mint(address receiver, uint amount) public onlyOwner {
        _mint(receiver, amount);
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal view override(ERC20) {
        if (from == address(0)) {
            require(totalSupply().add(amount) <= cap, "totalSupply exceeds cap");
        }
    }
}
