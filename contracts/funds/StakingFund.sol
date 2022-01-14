// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IFund.sol";

contract StakingFund is Ownable, IFund {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // CONTRACTS
    mapping(address => bool) public pools;

    /* ========== MODIFIER ========== */

    modifier onlyPools() {
        require(pools[_msgSender()], "Only pool can request transfer");
        _;
    }

    /* ========== VIEWS ================ */

    function balance(address _token) public view returns (uint256) {
        return IERC20(_token).balanceOf(address(this));
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function transferTo(
        address _token,
        address _receiver,
        uint256 _amount
    ) public override onlyPools {
        require(_receiver != address(0), "Invalid address");
        if (_amount > 0) {
            uint8 missing_decimals = 18 - ERC20(_token).decimals();
            IERC20(_token).safeTransfer(_receiver, _amount.div(10**missing_decimals));
        }
    }

    // Add new Pool
    function addPool(address pool_address) public onlyOwner {
        require(!pools[pool_address], "pool existed");
        pools[pool_address] = true;
        emit PoolAdded(pool_address);
    }

    // Remove a pool
    function removePool(address pool_address) public onlyOwner {
        require(!pools[pool_address], "pool not existed ");
        delete pools[pool_address];
        emit PoolRemoved(pool_address);
    }

    event PoolAdded(address pool);
    event PoolRemoved(address pool);
}