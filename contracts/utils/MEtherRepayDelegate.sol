pragma solidity >=0.5.16;

import "../MToken/MEther.sol";

contract MEtherRepayDelegate {
    MEther public mEther;

    constructor(MEther mEther_) public {
        mEther = mEther_;
    }

    /**
     * @notice msg.sender sends Ether to repay an account's borrow in the cEther market
     * @dev The provided Ether is applied towards the borrow balance, any excess is refunded
     * @param borrower The address of the borrower account to repay on behalf of
     * @return The initial borrows before the repay
     */
    function repayBehalf(address borrower) public payable {
        return repayBehalfExplicit(borrower, mEther);
    }

    /**
     * @notice msg.sender sends Ether to repay an account's borrow in a cEther market
     * @dev The provided Ether is applied towards the borrow balance, any excess is refunded
     * @param borrower The address of the borrower account to repay on behalf of
     * @param mEther_ The address of the cEther contract to repay in
     * @return The initial borrows before the repay
     */
    function repayBehalfExplicit(address borrower, MEther mEther_)
        public
        payable
    {
        uint256 received = msg.value;
        uint256 borrows = mEther_.borrowBalanceCurrent(borrower);
        if (received > borrows) {
            mEther_.repayBorrowBehalf.value(borrows)(borrower);
            msg.sender.transfer(received - borrows);
        } else {
            mEther_.repayBorrowBehalf.value(received)(borrower);
        }
    }
}
