// SPDX-License-Identifier: UNLICENSED

pragma solidity >=0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract ComptrollerFund is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // CONTRACTS
    address public comptroller;

    /* ========== MODIFIER ========== */

    modifier onlyComptroller() {
        require(comptroller == _msgSender(), "Only Comptroller can request transfer");
        _;
    }

    /* ========== VIEWS ================ */

    function balance(address _token) external view returns (uint256) {
        return IERC20(_token).balanceOf(address(this));
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function transferTo(
        address _token,
        address _receiver,
        uint256 _amount
    ) external onlyComptroller {
        require(_receiver != address(0), "Invalid address");
        if (_amount > 0) {
            uint8 missing_decimals = 18 - ERC20(_token).decimals();
            IERC20(_token).safeTransfer(_receiver, _amount.div(10**missing_decimals));
        }
    }

    function setComptroller(address _newComptroller) external onlyOwner {
        require(_newComptroller != address(0), "invalid address");
        comptroller = _newComptroller;
        emit ComptrollerUpdated(_newComptroller);
    }

    event ComptrollerUpdated(address _newComptroller);
}