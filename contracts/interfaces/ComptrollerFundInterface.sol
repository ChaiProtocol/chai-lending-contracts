// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.5.16;

interface ComptrollerFundInterface {
    function transferTo(
        address _token,
        address _receiver,
        uint256 _amount
    ) external;
}