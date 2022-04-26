pragma solidity ^0.5.16;

interface RewardMinterInterface {
    function mint(address user, uint256 amount) external;
}
