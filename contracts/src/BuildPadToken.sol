// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract BuildPadToken is ERC20, Ownable {
    string public tokenURI;
    
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 supply_,
        string memory uri_,
        address recipient_
    ) ERC20(name_, symbol_) Ownable(msg.sender) {
        tokenURI = uri_;
        _mint(recipient_, supply_ * 10**18);
    }
    
    function setTokenURI(string memory uri_) external onlyOwner {
        tokenURI = uri_;
    }
    
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
