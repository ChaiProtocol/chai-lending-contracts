// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IWETH.sol";

library WethUtils {
    using SafeERC20 for IWETH;

    IWETH public constant weth = IWETH(0xDeadDeAddeAddEAddeadDEaDDEAdDeaDDeAD0000);

    function isWeth(address token) internal pure returns (bool) {
        return address(weth) == token;
    }

    function wrap(uint256 amount) internal {
        weth.deposit{value: amount}();
    }

    function unwrap(uint256 amount) internal {
        weth.withdraw(amount);
    }

    function unwrapTo(uint256 amount, address to) internal {
        weth.withdraw(amount);
        payable(to).transfer(amount);
    }

    function transfer(address to, uint256 amount) internal {
        weth.safeTransfer(to, amount);
    }
}
