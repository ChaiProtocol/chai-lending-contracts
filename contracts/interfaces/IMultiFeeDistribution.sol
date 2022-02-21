// SPDX-License-Identifier: MIT

pragma solidity >=0.5.16;

interface IMultiFeeDistribution {
    function addReward(address rewardsToken) external;
    function mint(address user, uint256 amount) external;
}
