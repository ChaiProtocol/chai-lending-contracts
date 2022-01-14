pragma solidity >=0.5.16;
import "../common/ExponentialNoError.sol";
import "../MToken/MToken.sol";

interface RewardComptrollerInterface {
    function markets(address) external view returns (bool, uint256);

    function getAllMarkets() external view returns (MToken[] memory);

    function rewardAccrued(address) external view returns (uint256);

    function rewardSupplyState(address) external view returns (uint224, uint32);

    function rewardBorrowState(address) external view returns (uint224, uint32);

    function rewardSpeeds(address) external view returns (uint256);

    function rewardSupplierIndex(address, address)
        external
        view
        returns (uint256);

    function rewardBorrowerIndex(address, address)
        external
        view
        returns (uint256);

    function rewardInitialIndex() external view returns (uint256);
}

// RewardEstimator contract is used to estimate the pending unclaimed reward of an user
// It simulates the way that Comptroller calculate the rewards when users claim

contract RewardEstimator is ExponentialNoError {
    RewardComptrollerInterface public comptroller_;

    constructor(address _controller) public {
        comptroller_ = RewardComptrollerInterface(_controller);
    }

    function calculateReward(address holder) public view returns (uint256) {
        return calculateReward(comptroller_, holder);
    }

    function calculateReward(
        RewardComptrollerInterface controller,
        address holder
    ) public view returns (uint256) {
        return calculateReward(controller, holder, controller.getAllMarkets());
    }

    function calculateReward(
        RewardComptrollerInterface controller,
        address holder,
        MToken[] memory mTokens
    ) public view returns (uint256) {
        uint256 rewardAccrued = controller.rewardAccrued(holder);
        for (uint256 i = 0; i < mTokens.length; i++) {
            MToken mToken = mTokens[i];

            (bool isListed, ) = controller.markets(address(mToken));
            if (!isListed) {
                continue;
            }

            Exp memory borrowIndex = Exp({mantissa: mToken.borrowIndex()});
            uint256 borrowIndexMantissa = calculateRewardBorrowIndex(
                controller,
                address(mToken),
                borrowIndex
            );
            rewardAccrued = add_(
                rewardAccrued,
                calculateBorrowerReward(
                    controller,
                    address(mToken),
                    holder,
                    borrowIndexMantissa
                )
            );

            uint256 supplyIndexMantissa = calculateRewardSupplyIndex(
                controller,
                address(mToken)
            );
            rewardAccrued = add_(
                rewardAccrued,
                calculateSupplierReward(
                    controller,
                    address(mToken),
                    holder,
                    supplyIndexMantissa
                )
            );
        }

        return rewardAccrued;
    }

    function calculateRewardSupplyIndex(
        RewardComptrollerInterface controller,
        address mToken
    ) internal view returns (uint256) {
        (uint256 supplyStateIndex, uint256 supplyStateBlock) = controller
            .rewardSupplyState(mToken);
        uint256 supplySpeed = controller.rewardSpeeds(mToken);
        uint256 blockNumber = block.number;
        uint256 deltaBlocks = sub_(blockNumber, supplyStateBlock);
        if (deltaBlocks > 0 && supplySpeed > 0) {
            uint256 supplyTokens = MToken(mToken).totalSupply();
            uint256 rewardAccrued = mul_(deltaBlocks, supplySpeed);
            Double memory ratio = supplyTokens > 0
                ? fraction(rewardAccrued, supplyTokens)
                : Double({mantissa: 0});
            Double memory index = add_(
                Double({mantissa: supplyStateIndex}),
                ratio
            );
            return safe224(index.mantissa, "new index exceeds 224 bits");
        } else if (deltaBlocks > 0) {
            return safe224(supplyStateIndex, "new index exceeds 224 bits");
        }
    }

    function calculateSupplierReward(
        RewardComptrollerInterface controller,
        address mToken,
        address supplier,
        uint256 supplyIndexMantissa
    ) internal view returns (uint256 supplierAccrued) {
        Double memory supplyIndex = Double({mantissa: supplyIndexMantissa});
        Double memory supplierIndex = Double({
            mantissa: controller.rewardSupplierIndex(mToken, supplier)
        });

        if (supplierIndex.mantissa == 0 && supplyIndex.mantissa > 0) {
            supplierIndex.mantissa = controller.rewardInitialIndex();
        }

        if (supplyIndex.mantissa < supplierIndex.mantissa) {
            return 0;
        }
        Double memory deltaIndex = sub_(supplyIndex, supplierIndex);
        uint256 supplieMTokens = MToken(mToken).balanceOf(supplier);
        return mul_(supplieMTokens, deltaIndex);
    }

    function calculateRewardBorrowIndex(
        RewardComptrollerInterface controller,
        address mToken,
        Exp memory marketBorrowIndex
    ) internal view returns (uint256) {
        (uint256 borrowStateIndex, uint256 borrowStateBlock) = controller
            .rewardBorrowState(mToken);
        uint256 borrowSpeed = controller.rewardSpeeds(mToken);
        uint256 blockNumber = block.number;
        uint256 deltaBlocks = sub_(blockNumber, uint256(borrowStateBlock));

        if (deltaBlocks > 0 && borrowSpeed > 0) {
            uint256 borrowAmount = div_(
                MToken(mToken).totalBorrows(),
                marketBorrowIndex
            );
            uint256 rewardAccrued = mul_(deltaBlocks, borrowSpeed);
            Double memory ratio = borrowAmount > 0
                ? fraction(rewardAccrued, borrowAmount)
                : Double({mantissa: 0});
            Double memory index = add_(
                Double({mantissa: borrowStateIndex}),
                ratio
            );
            return safe224(index.mantissa, "new index exceeds 224 bits");
        } else if (deltaBlocks > 0) {
            return marketBorrowIndex.mantissa;
        }
    }

    function calculateBorrowerReward(
        RewardComptrollerInterface controller,
        address mToken,
        address borrower,
        uint256 borrowIndexMantissa
    ) internal view returns (uint256 borrowerAccrued) {
        Double memory borrowIndex = Double({mantissa: borrowIndexMantissa});
        Double memory borrowerIndex = Double({
            mantissa: controller.rewardBorrowerIndex(mToken, borrower)
        });

        if (borrowerIndex.mantissa > 0) {
            if (borrowIndex.mantissa < borrowerIndex.mantissa) {
                return 0;
            }
            Double memory deltaIndex = sub_(borrowIndex, borrowerIndex);
            uint256 borrowerAmount = div_(
                MToken(mToken).borrowBalanceStored(borrower),
                Exp(borrowIndexMantissa)
            );
            return mul_(borrowerAmount, deltaIndex);
        }
    }
}
