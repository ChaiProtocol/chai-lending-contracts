pragma solidity ^0.5.16;

contract ComptrollerInterface {
    /// @notice Indicator that this is a Comptroller contract (for inspection)
    bool public constant isComptroller = true;

    /*** Assets You Are In ***/

    function enterMarkets(address[] calldata chTokens)
        external
        returns (uint256[] memory);

    function exitMarket(address chToken) external returns (uint256);

    /*** Policy Hooks ***/

    function mintAllowed(
        address chToken,
        address minter,
        uint256 mintAmount
    ) external returns (uint256);

    function mintVerify(
        address chToken,
        address minter,
        uint256 mintAmount,
        uint256 mintTokens
    ) external;

    function redeemAllowed(
        address chToken,
        address redeemer,
        uint256 redeechTokens
    ) external returns (uint256);

    function redeemVerify(
        address chToken,
        address redeemer,
        uint256 redeemAmount,
        uint256 redeechTokens
    ) external;

    function borrowAllowed(
        address chToken,
        address borrower,
        uint256 borrowAmount
    ) external returns (uint256);

    function borrowVerify(
        address chToken,
        address borrower,
        uint256 borrowAmount
    ) external;

    function repayBorrowAllowed(
        address chToken,
        address payer,
        address borrower,
        uint256 repayAmount
    ) external returns (uint256);

    function repayBorrowVerify(
        address chToken,
        address payer,
        address borrower,
        uint256 repayAmount,
        uint256 borrowerIndex
    ) external;

    function liquidateBorrowAllowed(
        address chTokenBorrowed,
        address chTokenCollateral,
        address liquidator,
        address borrower,
        uint256 repayAmount
    ) external returns (uint256);

    function liquidateBorrowVerify(
        address chTokenBorrowed,
        address chTokenCollateral,
        address liquidator,
        address borrower,
        uint256 repayAmount,
        uint256 seizeTokens
    ) external;

    function seizeAllowed(
        address chTokenCollateral,
        address chTokenBorrowed,
        address liquidator,
        address borrower,
        uint256 seizeTokens
    ) external returns (uint256);

    function seizeVerify(
        address chTokenCollateral,
        address chTokenBorrowed,
        address liquidator,
        address borrower,
        uint256 seizeTokens
    ) external;

    function transferAllowed(
        address chToken,
        address src,
        address dst,
        uint256 transfeChTokens
    ) external returns (uint256);

    function transferVerify(
        address chToken,
        address src,
        address dst,
        uint256 transfeChTokens
    ) external;

    /*** Liquidity/Liquidation Calculations ***/

    function liquidateCalculateSeizeTokens(
        address chTokenBorrowed,
        address chTokenCollateral,
        uint256 repayAmount
    ) external view returns (uint256, uint256);

    function getProfitController() external view returns(address);
}
