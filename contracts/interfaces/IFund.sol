// SPDX-License-Identifier: UNLICENSED

pragma solidity >=0.8.0;

interface IFund {
    function transferTo(
        address _token,
        address _receiver,
        uint256 _amount
    ) external;
}