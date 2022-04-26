// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.5.16;


contract DelegateComptrollerAdminStorage {
    /**
    * @notice Administrator for this contract
    */
    address public admin;

    /**
    * @notice Pending administrator for this contract
    */
    address public pendingAdmin;

    /**
    * @notice Active brains of DelegateComptroller
    */
    address public comptrollerImplementation;

    /**
    * @notice Pending brains of DelegateComptroller
    */
    address public pendingComptrollerImplementation;
}
