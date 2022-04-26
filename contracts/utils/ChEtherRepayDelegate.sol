pragma solidity ^0.5.16;

import "../ChToken/ChEther.sol";

contract ChEtherRepayDelegate {
    ChEther public chEther;

    constructor(ChEther chEther_) public {
        chEther = chEther_;
    }

    /**
     * @notice msg.sender sends Ether to repay an account's borrow in the cEther market
     * @dev The provided Ether is applied towards the borrow balance, any excess is refunded
     * @param borrower The address of the borrower account to repay on behalf of
     * @return The initial borrows before the repay
     */
    function repayBehalf(address borrower) public payable {
        return repayBehalfExplicit(borrower, chEther);
    }

    /**
     * @notice msg.sender sends Ether to repay an account's borrow in a cEther market
     * @dev The provided Ether is applied towards the borrow balance, any excess is refunded
     * @param borrower The address of the borrower account to repay on behalf of
     * @param chEther_ The address of the cEther contract to repay in
     * @return The initial borrows before the repay
     */
    function repayBehalfExplicit(address borrower, ChEther chEther_)
        public
        payable
    {
        uint256 received = msg.value;
        uint256 borrows = chEther_.borrowBalanceCurrent(borrower);
        if (received > borrows) {
            chEther_.repayBorrowBehalf.value(borrows)(borrower);
            msg.sender.transfer(received - borrows);
        } else {
            chEther_.repayBorrowBehalf.value(received)(borrower);
        }
    }
}
