pragma solidity >=0.5.16;

import "./MErc20Delegate.sol";
import "../common/SafeMath.sol";

interface IDollar {
    function burnFrom(address _address, uint256 _amount) external;
    function mintTo(address _address, uint256 _amount) external;
    function totalSupply() external view returns (uint256);
    function maxCap() external view returns (uint256);
}

/**
 * @title Mojito's MStable
 * @notice MToken which wraps stable coin
 * @author Mojito developers
 */
contract MMojitoDollar is MErc20Delegate {
    using SafeMath for uint256;

    function mint(uint256) external returns (uint256) {
        return
            fail(
                Error.TOKEN_MINT_REDEEM_NOT_ALLOWED,
                FailureInfo.MINT_COMPTROLLER_REJECTION
            );
    }

    function redeem(uint256) external returns (uint256) {
        return
            fail(
                Error.TOKEN_MINT_REDEEM_NOT_ALLOWED,
                FailureInfo.REDEEM_COMPTROLLER_REJECTION
            );
    }

    // mint and redeem underlying token instead of transfer
    function doTransferOut(address payable to, uint256 amount) internal {
        IDollar mjd = IDollar(underlying);
        mjd.mintTo(to, amount);
    }

    function doTransferIn(address from, uint256 amount)
        internal
        returns (uint256)
    {
        IDollar(underlying).burnFrom(from, amount);
        return amount;
    }

    function getCashPrior() internal view returns (uint256) {
        IDollar mjd = IDollar(underlying);
        uint256 maxCap = mjd.maxCap();
        uint256 supply = mjd.totalSupply();

        uint256 cash = supply > maxCap ? 0 : maxCap.sub(supply);
        return cash;
    }
}
