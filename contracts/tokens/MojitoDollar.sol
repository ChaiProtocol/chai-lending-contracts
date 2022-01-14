//SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MojitoDollar is ERC20, Ownable {
    using SafeMath for uint256;

    event MinterUpdated(address _minter);
    event MaxCapChanged(uint256 _maxCap);

    uint256 public maxCap;
    address public minter;

    modifier onlyMinter() {
        require(minter == _msgSender(), "!minter");
        _;
    }

    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _maxCap
    ) ERC20(_name, _symbol) {
        maxCap = _maxCap;
    }

    //=========================================
    //  MINTERS PRIVILEGES
    //=========================================

    function mintTo(address _to, uint256 _amount) public onlyMinter {
        require(totalSupply().add(_amount) <= maxCap, "> maxCap");
        _mint(_to, _amount);
    }
    
    function burnFrom(address _from, uint256 _amount) public onlyMinter {
        _burn(_from, _amount);
    }

    //=========================================
    //  RESTRICTED FUNCTIONS 
    //=========================================

    function setMinter(address _newMinter) public onlyOwner {
        require(_newMinter != address(0), "invalid address");
        minter = _newMinter;
        emit MinterUpdated(_newMinter);
    }

    function setMaxCap(uint256 _maxCap) public onlyOwner {
        maxCap = _maxCap;
        emit MaxCapChanged(_maxCap);
    }
}
