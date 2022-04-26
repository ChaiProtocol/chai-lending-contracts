pragma solidity >=0.5.16;

import "../ChToken/ChToken.sol";
import "../common/ErrorReporter.sol";
import "../interfaces/PriceOracle.sol";
import "../interfaces/ComptrollerInterface.sol";
import "../interfaces/RewardMinterInterface.sol";
import "./ComptrollerStorage.sol";
import "./DelegateComptroller.sol";

/**
 * @title Chai's Comptroller Contract
 * @author Chai developers
 */
contract Comptroller is
    ComptrollerStorage,
    ComptrollerInterface,
    ComptrollerErrorReporter,
    ExponentialNoError
{
    /// @notice Emitted when an admin supports a market
    event MarketListed(ChToken chToken);

    /// @notice Emitted when an account enters a market
    event MarketEntered(ChToken chToken, address account);

    /// @notice Emitted when an account exits a market
    event MarketExited(ChToken chToken, address account);

    /// @notice Emitted when close factor is changed by admin
    event NewCloseFactor(
        uint256 oldCloseFactorMantissa,
        uint256 newCloseFactorMantissa
    );

    /// @notice Emitted when a collateral factor is changed by admin
    event NewCollateralFactor(
        ChToken chToken,
        uint256 oldCollateralFactorMantissa,
        uint256 newCollateralFactorMantissa
    );

    /// @notice Emitted when liquidation incentive is changed by admin
    event NewLiquidationIncentive(
        address chToken,
        uint256 oldLiquidationIncentiveMantissa,
        uint256 newLiquidationIncentiveMantissa
    );

    /// @notice Emitted when price oracle is changed
    event NewPriceOracle(
        PriceOracle oldPriceOracle,
        PriceOracle newPriceOracle
    );

    /// @notice Emitted when pause guardian is changed
    event NewPauseGuardian(address oldPauseGuardian, address newPauseGuardian);

    /// @notice Emitted when an action is paused globally
    event ActionPaused(string action, bool pauseState);

    /// @notice Emitted when an action is paused on a market
    event ActionPaused(ChToken chToken, string action, bool pauseState);

    /// @notice Emitted when a new REWARD speed is calculated for a market
    event RewardSpeedUpdated(ChToken indexed chToken, uint256 newSpeed);

    /// @notice Emitted when REWARD is distributed to a supplier
    event DistributedSupplierReward(
        ChToken indexed chToken,
        address indexed supplier,
        uint256 rewardDelta,
        uint256 rewardSupplyIndex
    );

    /// @notice Emitted when REWARD is distributed to a borrower
    event DistributedBorrowerReward(
        ChToken indexed chToken,
        address indexed borrower,
        uint256 rewardDelta,
        uint256 rewardBorrowIndex
    );

    /// @notice Emitted when borrow cap for a chToken is changed
    event NewBorrowCap(ChToken indexed chToken, uint256 newBorrowCap);

    /// @notice Emitted when borrow cap guardian is changed
    event NewBorrowCapGuardian(
        address oldBorrowCapGuardian,
        address newBorrowCapGuardian
    );

    // /// @notice Emitted when REWARD is granted by admin
    // event RewardGranted(address recipient, uint256 amount);

    /// @notice Emitted when new liquidation threshold is set by admin
    event NewLiquidationThreshold(
        address chToken,
        uint256 oldValue,
        uint256 newValue
    );

    /// @notice Emitted when new profit controller is set by admin
    event NewProfitController(address oldController, address newController);

    /// @notice The initial REWARD index for a market
    uint224 public constant rewardInitialIndex = 1e36;

    // closeFactorMantissa must be strictly greater than this value
    uint256 internal constant closeFactorMinMantissa = 0.05e18; // 0.05

    // closeFactorMantissa must not exceed this value
    uint256 internal constant closeFactorMaxMantissa = 0.9e18; // 0.9

    // No collateralFactorMantissa may exceed this value
    uint256 internal constant collateralFactorMaxMantissa = 0.9e18; // 0.9

    constructor() public {
        admin = msg.sender;
    }

    /*** Assets You Are In ***/

    /**
     * @notice Returns the assets an account has entered
     * @param account The address of the account to pull assets for
     * @return A dynamic list with the assets the account has entered
     */
    function getAssetsIn(address account)
        external
        view
        returns (ChToken[] memory)
    {
        ChToken[] memory assetsIn = accountAssets[account];

        return assetsIn;
    }

    /**
     * @notice Returns whether the given account is entered in the given asset
     * @param account The address of the account to check
     * @param chToken The chToken to check
     * @return True if the account is in the asset, otherwise false.
     */
    function checkMembership(address account, ChToken chToken)
        external
        view
        returns (bool)
    {
        return markets[address(chToken)].accountMembership[account];
    }

    /**
     * @notice Add assets to be included in account liquidity calculation
     * @param chTokens The list of addresses of the chToken markets to be enabled
     * @return Success indicator for whether each corresponding market was entered
     */
    function enterMarkets(address[] memory chTokens)
        public
        returns (uint256[] memory)
    {
        uint256 len = chTokens.length;

        uint256[] memory results = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            ChToken chToken = ChToken(chTokens[i]);

            results[i] = uint256(addToMarketInternal(chToken, msg.sender));
        }

        return results;
    }

    /**
     * @notice Add the market to the borrower's "assets in" for liquidity calculations
     * @param chToken The market to enter
     * @param borrower The address of the account to modify
     * @return Success indicator for whether the market was entered
     */
    function addToMarketInternal(ChToken chToken, address borrower)
        internal
        returns (Error)
    {
        Market storage marketToJoin = markets[address(chToken)];

        if (!marketToJoin.isListed) {
            // market is not listed, cannot join
            return Error.MARKET_NOT_LISTED;
        }

        if (marketToJoin.accountMembership[borrower] == true) {
            // already joined
            return Error.NO_ERROR;
        }

        // survived the gauntlet, add to list
        // NOTE: we store these somewhat redundantly as a significant optimization
        //  this avoids having to iterate through the list for the most common use cases
        //  that is, only when we need to perform liquidity checks
        //  and not whenever we want to check if an account is in a particular market
        marketToJoin.accountMembership[borrower] = true;
        accountAssets[borrower].push(chToken);

        emit MarketEntered(chToken, borrower);

        return Error.NO_ERROR;
    }

    /**
     * @notice Removes asset from sender's account liquidity calculation
     * @dev Sender must not have an outstanding borrow balance in the asset,
     *  or be providing necessary collateral for an outstanding borrow.
     * @param chTokenAddress The address of the asset to be removed
     * @return Whether or not the account successfully exited the market
     */
    function exitMarket(address chTokenAddress) external returns (uint256) {
        ChToken chToken = ChToken(chTokenAddress);
        /* Get sender tokensHeld and amountOwed underlying from the chToken */
        (uint256 oErr, uint256 tokensHeld, uint256 amountOwed, ) = chToken
            .getAccountSnapshot(msg.sender);
        require(oErr == 0, "exitMarket: getAccountSnapshot failed"); // semi-opaque error code

        /* Fail if the sender has a borrow balance */
        if (amountOwed != 0) {
            return
                fail(
                    Error.NONZERO_BORROW_BALANCE,
                    FailureInfo.EXIT_MARKET_BALANCE_OWED
                );
        }

        /* Fail if the sender is not permitted to redeem all of their tokens */
        uint256 allowed = redeemAllowedInternal(
            chTokenAddress,
            msg.sender,
            tokensHeld
        );
        if (allowed != 0) {
            return
                failOpaque(
                    Error.REJECTION,
                    FailureInfo.EXIT_MARKET_REJECTION,
                    allowed
                );
        }

        Market storage marketToExit = markets[address(chToken)];

        /* Return true if the sender is not already ‘in’ the market */
        if (!marketToExit.accountMembership[msg.sender]) {
            return uint256(Error.NO_ERROR);
        }

        /* Set chToken account membership to false */
        delete marketToExit.accountMembership[msg.sender];

        /* Delete chToken from the account’s list of assets */
        // load into memory for faster iteration
        ChToken[] memory userAssetList = accountAssets[msg.sender];
        uint256 len = userAssetList.length;
        uint256 assetIndex = len;
        for (uint256 i = 0; i < len; i++) {
            if (userAssetList[i] == chToken) {
                assetIndex = i;
                break;
            }
        }

        // We *must* have found the asset in the list or our redundant data structure is broken
        assert(assetIndex < len);

        // copy last item in list to location of item to be removed, reduce length by 1
        ChToken[] storage storedList = accountAssets[msg.sender];
        storedList[assetIndex] = storedList[storedList.length - 1];
        storedList.length--;

        emit MarketExited(chToken, msg.sender);

        return uint256(Error.NO_ERROR);
    }

    /*** Policy Hooks ***/

    /**
     * @notice Checks if the account should be allowed to mint tokens in the given market
     * @param chToken The market to verify the mint against
     * @param minter The account which would get the minted tokens
     * @param mintAmount The amount of underlying being supplied to the market in exchange for tokens
     * @return 0 if the mint is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function mintAllowed(
        address chToken,
        address minter,
        uint256 mintAmount
    ) external returns (uint256) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!mintGuardianPaused[chToken], "mint is paused");

        // Shh - currently unused
        minter;
        mintAmount;

        if (!markets[chToken].isListed) {
            return uint256(Error.MARKET_NOT_LISTED);
        }

        // Keep the flywheel moving
        updateRewardSupplyIndex(chToken);
        distributeSupplierReward(chToken, minter);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates mint and reverts on rejection. May emit logs.
     * @param chToken Asset being minted
     * @param minter The address minting the tokens
     * @param actualMintAmount The amount of the underlying asset being minted
     * @param mintTokens The number of tokens being minted
     */
    function mintVerify(
        address chToken,
        address minter,
        uint256 actualMintAmount,
        uint256 mintTokens
    ) external {
        // Shh - currently unused
        chToken;
        minter;
        actualMintAmount;
        mintTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to redeem tokens in the given market
     * @param chToken The market to verify the redeem against
     * @param redeemer The account which would redeem the tokens
     * @param redeechTokens The number of chTokens to exchange for the underlying asset in the market
     * @return 0 if the redeem is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function redeemAllowed(
        address chToken,
        address redeemer,
        uint256 redeechTokens
    ) external returns (uint256) {
        uint256 allowed = redeemAllowedInternal(chToken, redeemer, redeechTokens);
        if (allowed != uint256(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updateRewardSupplyIndex(chToken);
        distributeSupplierReward(chToken, redeemer);

        return uint256(Error.NO_ERROR);
    }

    function redeemAllowedInternal(
        address chToken,
        address redeemer,
        uint256 redeechTokens
    ) internal view returns (uint256) {
        if (!markets[chToken].isListed) {
            return uint256(Error.MARKET_NOT_LISTED);
        }

        /* If the redeemer is not 'in' the market, then we can bypass the liquidity check */
        if (!markets[chToken].accountMembership[redeemer]) {
            return uint256(Error.NO_ERROR);
        }

        /* Otherwise, perform a hypothetical liquidity check to guard against shortfall */
        (
            Error err,
            ,
            uint256 shortfall,

        ) = getHypotheticalAccountLiquidityInternal(
                redeemer,
                ChToken(chToken),
                redeechTokens,
                0
            );
        if (err != Error.NO_ERROR) {
            return uint256(err);
        }
        if (shortfall > 0) {
            return uint256(Error.INSUFFICIENT_LIQUIDITY);
        }

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates redeem and reverts on rejection. May emit logs.
     * @param chToken Asset being redeemed
     * @param redeemer The address redeeming the tokens
     * @param redeemAmount The amount of the underlying asset being redeemed
     * @param redeechTokens The number of tokens being redeemed
     */
    function redeemVerify(
        address chToken,
        address redeemer,
        uint256 redeemAmount,
        uint256 redeechTokens
    ) external {
        // Shh - currently unused
        chToken;
        redeemer;

        // Require tokens is zero or amount is also zero
        if (redeechTokens == 0 && redeemAmount > 0) {
            revert("redeechTokens zero");
        }
    }

    /**
     * @notice Checks if the account should be allowed to borrow the underlying asset of the given market
     * @param chToken The market to verify the borrow against
     * @param borrower The account which would borrow the asset
     * @param borrowAmount The amount of underlying the account would borrow
     * @return 0 if the borrow is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function borrowAllowed(
        address chToken,
        address borrower,
        uint256 borrowAmount
    ) external returns (uint256) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!borrowGuardianPaused[chToken], "borrow is paused");

        if (!markets[chToken].isListed) {
            return uint256(Error.MARKET_NOT_LISTED);
        }

        if (!markets[chToken].accountMembership[borrower]) {
            // only chTokens may call borrowAllowed if borrower not in market
            require(msg.sender == chToken, "sender must be chToken");

            // attempt to add borrower to the market
            Error err = addToMarketInternal(ChToken(msg.sender), borrower);
            if (err != Error.NO_ERROR) {
                return uint256(err);
            }

            // it should be impossible to break the important invariant
            assert(markets[chToken].accountMembership[borrower]);
        }

        if (oracle.getUnderlyingPrice(ChToken(chToken)) == 0) {
            return uint256(Error.PRICE_ERROR);
        }

        uint256 borrowCap = borrowCaps[chToken];
        // Borrow cap of 0 corresponds to unlimited borrowing
        if (borrowCap != 0) {
            uint256 totalBorrows = ChToken(chToken).totalBorrows();
            uint256 nextTotalBorrows = add_(totalBorrows, borrowAmount);
            require(nextTotalBorrows < borrowCap, "market borrow cap reached");
        }

        (
            Error err,
            ,
            uint256 shortfall,

        ) = getHypotheticalAccountLiquidityInternal(
                borrower,
                ChToken(chToken),
                0,
                borrowAmount
            );
        if (err != Error.NO_ERROR) {
            return uint256(err);
        }
        if (shortfall > 0) {
            return uint256(Error.INSUFFICIENT_LIQUIDITY);
        }

        // Keep the flywheel moving
        Exp memory borrowIndex = Exp({mantissa: ChToken(chToken).borrowIndex()});
        updateRewardBorrowIndex(chToken, borrowIndex);
        distributeBorrowerReward(chToken, borrower, borrowIndex);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates borrow and reverts on rejection. May emit logs.
     * @param chToken Asset whose underlying is being borrowed
     * @param borrower The address borrowing the underlying
     * @param borrowAmount The amount of the underlying asset requested to borrow
     */
    function borrowVerify(
        address chToken,
        address borrower,
        uint256 borrowAmount
    ) external {
        // Shh - currently unused
        chToken;
        borrower;
        borrowAmount;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to repay a borrow in the given market
     * @param chToken The market to verify the repay against
     * @param payer The account which would repay the asset
     * @param borrower The account which would borrowed the asset
     * @param repayAmount The amount of the underlying asset the account would repay
     * @return 0 if the repay is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function repayBorrowAllowed(
        address chToken,
        address payer,
        address borrower,
        uint256 repayAmount
    ) external returns (uint256) {
        // Shh - currently unused
        payer;
        borrower;
        repayAmount;

        if (!markets[chToken].isListed) {
            return uint256(Error.MARKET_NOT_LISTED);
        }

        // Keep the flywheel moving
        Exp memory borrowIndex = Exp({mantissa: ChToken(chToken).borrowIndex()});
        updateRewardBorrowIndex(chToken, borrowIndex);
        distributeBorrowerReward(chToken, borrower, borrowIndex);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates repayBorrow and reverts on rejection. May emit logs.
     * @param chToken Asset being repaid
     * @param payer The address repaying the borrow
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function repayBorrowVerify(
        address chToken,
        address payer,
        address borrower,
        uint256 actualRepayAmount,
        uint256 borrowerIndex
    ) external {
        // Shh - currently unused
        chToken;
        payer;
        borrower;
        actualRepayAmount;
        borrowerIndex;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the liquidation should be allowed to occur
     * @param chTokenBorrowed Asset which was borrowed by the borrower
     * @param chTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param repayAmount The amount of underlying being repaid
     */
    function liquidateBorrowAllowed(
        address chTokenBorrowed,
        address chTokenCollateral,
        address liquidator,
        address borrower,
        uint256 repayAmount
    ) external returns (uint256) {
        // Shh - currently unused
        liquidator;

        if (
            !markets[chTokenBorrowed].isListed ||
            !markets[chTokenCollateral].isListed
        ) {
            return uint256(Error.MARKET_NOT_LISTED);
        }

        /* The borrower must have shortfall in order to be liquidatable */
        (Error err, , , uint256 shortfall) = getAccountLiquidityInternal(
            borrower
        );
        if (err != Error.NO_ERROR) {
            return uint256(err);
        }
        if (shortfall == 0) {
            return uint256(Error.INSUFFICIENT_SHORTFALL);
        }

        /* The liquidator may not repay more than what is allowed by the closeFactor */
        uint256 borrowBalance = ChToken(chTokenBorrowed).borrowBalanceStored(
            borrower
        );
        uint256 maxClose = mul_ScalarTruncate(
            Exp({mantissa: closeFactorMantissa}),
            borrowBalance
        );
        if (repayAmount > maxClose) {
            return uint256(Error.TOO_MUCH_REPAY);
        }

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates liquidateBorrow and reverts on rejection. May emit logs.
     * @param chTokenBorrowed Asset which was borrowed by the borrower
     * @param chTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function liquidateBorrowVerify(
        address chTokenBorrowed,
        address chTokenCollateral,
        address liquidator,
        address borrower,
        uint256 actualRepayAmount,
        uint256 seizeTokens
    ) external {
        // Shh - currently unused
        chTokenBorrowed;
        chTokenCollateral;
        liquidator;
        borrower;
        actualRepayAmount;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the seizing of assets should be allowed to occur
     * @param chTokenCollateral Asset which was used as collateral and will be seized
     * @param chTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeAllowed(
        address chTokenCollateral,
        address chTokenBorrowed,
        address liquidator,
        address borrower,
        uint256 seizeTokens
    ) external returns (uint256) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!seizeGuardianPaused, "seize is paused");

        // Shh - currently unused
        seizeTokens;

        if (
            !markets[chTokenCollateral].isListed ||
            !markets[chTokenBorrowed].isListed
        ) {
            return uint256(Error.MARKET_NOT_LISTED);
        }

        if (
            ChToken(chTokenCollateral).comptroller() !=
            ChToken(chTokenBorrowed).comptroller()
        ) {
            return uint256(Error.COMPTROLLER_MISMATCH);
        }

        // Keep the flywheel moving
        updateRewardSupplyIndex(chTokenCollateral);
        distributeSupplierReward(chTokenCollateral, borrower);
        distributeSupplierReward(chTokenCollateral, liquidator);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates seize and reverts on rejection. May emit logs.
     * @param chTokenCollateral Asset which was used as collateral and will be seized
     * @param chTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeVerify(
        address chTokenCollateral,
        address chTokenBorrowed,
        address liquidator,
        address borrower,
        uint256 seizeTokens
    ) external {
        // Shh - currently unused
        chTokenCollateral;
        chTokenBorrowed;
        liquidator;
        borrower;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to transfer tokens in the given market
     * @param chToken The market to verify the transfer against
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transfeChTokens The number of chTokens to transfer
     * @return 0 if the transfer is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function transferAllowed(
        address chToken,
        address src,
        address dst,
        uint256 transfeChTokens
    ) external returns (uint256) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!transferGuardianPaused, "transfer is paused");

        // Currently the only consideration is whether or not
        //  the src is allowed to redeem this many tokens
        uint256 allowed = redeemAllowedInternal(chToken, src, transfeChTokens);
        if (allowed != uint256(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updateRewardSupplyIndex(chToken);
        distributeSupplierReward(chToken, src);
        distributeSupplierReward(chToken, dst);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates transfer and reverts on rejection. May emit logs.
     * @param chToken Asset being transferred
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transfeChTokens The number of chTokens to transfer
     */
    function transferVerify(
        address chToken,
        address src,
        address dst,
        uint256 transfeChTokens
    ) external {
        // Shh - currently unused
        chToken;
        src;
        dst;
        transfeChTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /*** Liquidity/Liquidation Calculations ***/

    /**
     * @dev Local vars for avoiding stack-depth limits in calculating account liquidity.
     *  Note that `chTokenBalance` is the number of chTokens the account owns in the market,
     *  whereas `borrowBalance` is the amount of underlying that the account has borrowed.
     */
    struct AccountLiquidityLocalVars {
        uint256 sumCollateral;
        uint256 sumBorrowPlusEffects;
        uint256 sumLiquidationThreshold;
        uint256 sumLiquidationBorrowEffect;
        uint256 chTokenBalance;
        uint256 borrowBalance;
        uint256 exchangeRateMantissa;
        uint256 oraclePriceMantissa;
        uint256 borrowLimit;
        Exp collateralFactor;
        Exp exchangeRate;
        Exp oraclePrice;
        Exp liquidationThreshold;
        Exp tokensToDenom;
        Exp liquidationDenom;
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code (semi-opaque),
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidity(address account)
        public
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        (
            Error err,
            uint256 liquidity,
            uint256 shortfall,
            uint256 liquidationShortfall
        ) = getHypotheticalAccountLiquidityInternal(account, ChToken(0), 0, 0);

        return (uint256(err), liquidity, shortfall, liquidationShortfall);
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code,
                account liquidity in excess of borrow limit,
                account shortfall below borrow limit,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidityInternal(address account)
        internal
        view
        returns (
            Error,
            uint256,
            uint256,
            uint256
        )
    {
        return
            getHypotheticalAccountLiquidityInternal(account, ChToken(0), 0, 0);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param chTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeechTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @return (possible error code (semi-opaque),
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidity(
        address account,
        address chTokenModify,
        uint256 redeechTokens,
        uint256 borrowAmount
    )
        public
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        (
            Error err,
            uint256 liquidity,
            uint256 borrowShortfall,
            uint256 shortfall
        ) = getHypotheticalAccountLiquidityInternal(
                account,
                ChToken(chTokenModify),
                redeechTokens,
                borrowAmount
            );
        return (uint256(err), liquidity, borrowShortfall, shortfall);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param chTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeechTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @dev Note that we calculate the exchangeRateStored for each collateral chToken using stored data,
     *  without calculating accumulated interest.
     * @return (possible error code,
     *          hypothetical account liquidity in excess of borrow limit,
     *          hypothetical account shortfall below borrow limit,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidityInternal(
        address account,
        ChToken chTokenModify,
        uint256 redeechTokens,
        uint256 borrowAmount
    )
        internal
        view
        returns (
            Error,
            uint256, // liquidity = borrow limit - borrow
            uint256, // borrow short = borrow - borrow limit
            uint256 // liquidation short = borrow - collateral value
        )
    {
        AccountLiquidityLocalVars memory vars; // Holds all our calculation results
        uint256 oErr;

        // For each asset the account is in
        ChToken[] memory assets = accountAssets[account];
        for (uint256 i = 0; i < assets.length; i++) {
            ChToken asset = assets[i];

            // Read the balances and exchange rate from the chToken
            (
                oErr,
                vars.chTokenBalance,
                vars.borrowBalance,
                vars.exchangeRateMantissa
            ) = asset.getAccountSnapshot(account);
            if (oErr != 0) {
                // semi-opaque error code, we assume NO_ERROR == 0 is invariant between upgrades
                return (Error.SNAPSHOT_ERROR, 0, 0, 0);
            }
            vars.collateralFactor = Exp({
                mantissa: markets[address(asset)].collateralFactorMantissa
            });
            vars.exchangeRate = Exp({mantissa: vars.exchangeRateMantissa});
            vars.liquidationThreshold = Exp({
                mantissa: liquidationThreshold[address(asset)]
            });

            // Get the normalized price of the asset
            vars.oraclePriceMantissa = oracle.getUnderlyingPrice(asset);
            if (vars.oraclePriceMantissa == 0) {
                return (Error.PRICE_ERROR, 0, 0, 0);
            }
            vars.oraclePrice = Exp({mantissa: vars.oraclePriceMantissa});

            // Pre-compute a conversion factor from tokens -> ether (normalized price value)
            vars.tokensToDenom = mul_(
                mul_(vars.collateralFactor, vars.exchangeRate),
                vars.oraclePrice
            );

            // sumCollateral += tokensToDenom * chTokenBalance
            vars.sumCollateral = mul_ScalarTruncateAddUInt(
                vars.tokensToDenom,
                vars.chTokenBalance,
                vars.sumCollateral
            );

            // multiplier from tokens to liquidation threshold (in wei)
            vars.liquidationDenom = mul_(
                mul_(vars.liquidationThreshold, vars.exchangeRate),
                vars.oraclePrice
            );
            
            // liquidationTrheshold += liquidationDenom * chTokenBalance
            vars.sumLiquidationThreshold = mul_ScalarTruncateAddUInt(
                vars.liquidationDenom,
                vars.chTokenBalance,
                vars.sumLiquidationThreshold
            );

            // sumBorrowPlusEffects += oraclePrice * borrowBalance
            vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(
                vars.oraclePrice,
                vars.borrowBalance,
                vars.sumBorrowPlusEffects
            );

            // sumLiquidationBorrowEffect += oraclePrice * borrowBalance
            vars.sumLiquidationBorrowEffect = mul_ScalarTruncateAddUInt(
                vars.oraclePrice,
                vars.borrowBalance,
                vars.sumLiquidationBorrowEffect
            );

            // Calculate effects of interacting with chTokenModify
            if (asset == chTokenModify) {
                // redeem effect
                // sumBorrowPlusEffects += tokensToDenom * redeechTokens
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(
                    vars.tokensToDenom,
                    redeechTokens,
                    vars.sumBorrowPlusEffects
                );

                vars.sumLiquidationBorrowEffect = mul_ScalarTruncateAddUInt(
                    vars.liquidationDenom,
                    redeechTokens,
                    vars.sumLiquidationBorrowEffect
                );

                // borrow effect
                // sumBorrowPlusEffects += oraclePrice * borrowAmount
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(
                    vars.oraclePrice,
                    borrowAmount,
                    vars.sumBorrowPlusEffects
                );

                vars.sumLiquidationBorrowEffect = mul_ScalarTruncateAddUInt(
                    vars.oraclePrice,
                    borrowAmount,
                    vars.sumLiquidationBorrowEffect
                );
            }
        }

        uint256 liquidationShortfall = vars.sumLiquidationThreshold >
            vars.sumLiquidationBorrowEffect
            ? 0
            : vars.sumLiquidationBorrowEffect - vars.sumLiquidationThreshold;

        // These are safe, as the underflow condition is checked first
        if (vars.sumCollateral > vars.sumBorrowPlusEffects) {
            return (
                Error.NO_ERROR,
                vars.sumCollateral - vars.sumBorrowPlusEffects,
                0,
                liquidationShortfall
            );
        } else {
            return (
                Error.NO_ERROR,
                0,
                vars.sumBorrowPlusEffects - vars.sumCollateral,
                liquidationShortfall
            );
        }
    }

    /**
     * @notice Calculate number of tokens of collateral asset to seize given an underlying amount
     * @dev Used in liquidation (called in chToken.liquidateBorrowFresh)
     * @param chTokenBorrowed The address of the borrowed chToken
     * @param chTokenCollateral The address of the collateral chToken
     * @param actualRepayAmount The amount of chTokenBorrowed underlying to convert into chTokenCollateral tokens
     * @return (errorCode, number of chTokenCollateral tokens to be seized in a liquidation)
     */
    function liquidateCalculateSeizeTokens(
        address chTokenBorrowed,
        address chTokenCollateral,
        uint256 actualRepayAmount
    ) external view returns (uint256, uint256) {
        /* Read oracle prices for borrowed and collateral markets */
        uint256 priceBorrowedMantissa = oracle.getUnderlyingPrice(
            ChToken(chTokenBorrowed)
        );
        uint256 priceCollateralMantissa = oracle.getUnderlyingPrice(
            ChToken(chTokenCollateral)
        );
        if (priceBorrowedMantissa == 0 || priceCollateralMantissa == 0) {
            return (uint256(Error.PRICE_ERROR), 0);
        }

        /*
         * Get the exchange rate and calculate the number of collateral tokens to seize:
         *  seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
         *  seizeTokens = seizeAmount / exchangeRate
         *   = actualRepayAmount * (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
         */
        uint256 exchangeRateMantissa = ChToken(chTokenCollateral)
            .exchangeRateStored(); // Note: reverts on error
        uint256 seizeTokens;
        Exp memory numerator;
        Exp memory denominator;
        Exp memory ratio;

        uint256 liquidationIncentiveMantissa = liquidationIncentive[address(chTokenCollateral)];
        numerator = mul_(
            Exp({mantissa: liquidationIncentiveMantissa}),
            Exp({mantissa: priceBorrowedMantissa})
        );
        denominator = mul_(
            Exp({mantissa: priceCollateralMantissa}),
            Exp({mantissa: exchangeRateMantissa})
        );
        ratio = div_(numerator, denominator);

        seizeTokens = mul_ScalarTruncate(ratio, actualRepayAmount);

        return (uint256(Error.NO_ERROR), seizeTokens);
    }

    /*** Admin Functions ***/

    /**
     * @notice Sets a new price oracle for the comptroller
     * @dev Admin function to set a new price oracle
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setPriceOracle(PriceOracle newOracle) public returns (uint256) {
        // Check caller is admin
        if (msg.sender != admin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.SET_PRICE_ORACLE_OWNER_CHECK
                );
        }

        // Track the old oracle for the comptroller
        PriceOracle oldOracle = oracle;

        // Set comptroller's oracle to newOracle
        oracle = newOracle;

        // Emit NewPriceOracle(oldOracle, newOracle)
        emit NewPriceOracle(oldOracle, newOracle);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Sets the closeFactor used when liquidating borrows
     * @dev Admin function to set closeFactor
     * @param newCloseFactorMantissa New close factor, scaled by 1e18
     * @return uint 0=success, otherwise a failure
     */
    function _setCloseFactor(uint256 newCloseFactorMantissa)
        external
        returns (uint256)
    {
        // Check caller is admin
        if (msg.sender != admin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.SET_COLLATERAL_FACTOR_OWNER_CHECK
                );
        }

        uint256 oldCloseFactorMantissa = closeFactorMantissa;
        closeFactorMantissa = newCloseFactorMantissa;
        emit NewCloseFactor(oldCloseFactorMantissa, closeFactorMantissa);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Sets the collateralFactor for a market
     * @dev Admin function to set per-market collateralFactor
     * @param chToken The market to set the factor on
     * @param newCollateralFactorMantissa The new collateral factor, scaled by 1e18
     * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
     */
    function _setCollateralFactor(
        ChToken chToken,
        uint256 newCollateralFactorMantissa
    ) external returns (uint256) {
        // Check caller is admin
        if (msg.sender != admin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.SET_COLLATERAL_FACTOR_OWNER_CHECK
                );
        }

        // Verify market is listed
        Market storage market = markets[address(chToken)];
        if (!market.isListed) {
            return
                fail(
                    Error.MARKET_NOT_LISTED,
                    FailureInfo.SET_COLLATERAL_FACTOR_NO_EXISTS
                );
        }

        Exp memory newCollateralFactorExp = Exp({
            mantissa: newCollateralFactorMantissa
        });

        // Check collateral factor <= 0.9
        Exp memory highLimit = Exp({mantissa: collateralFactorMaxMantissa});
        if (lessThanExp(highLimit, newCollateralFactorExp)) {
            return
                fail(
                    Error.INVALID_COLLATERAL_FACTOR,
                    FailureInfo.SET_COLLATERAL_FACTOR_VALIDATION
                );
        }

        // If collateral factor != 0, fail if price == 0
        if (
            newCollateralFactorMantissa != 0 &&
            oracle.getUnderlyingPrice(chToken) == 0
        ) {
            return
                fail(
                    Error.PRICE_ERROR,
                    FailureInfo.SET_COLLATERAL_FACTOR_WITHOUT_PRICE
                );
        }

        // liquidation threshold always higher than collateral factor
        uint256 currentLiquidationThreshold = liquidationThreshold[
            address(chToken)
        ];
        if (currentLiquidationThreshold < newCollateralFactorMantissa) {
            liquidationThreshold[address(chToken)] = newCollateralFactorMantissa;

            emit NewLiquidationThreshold(
                address(chToken),
                currentLiquidationThreshold,
                newCollateralFactorMantissa
            );
        }

        // Set market's collateral factor to new collateral factor, remember old value
        uint256 oldCollateralFactorMantissa = market.collateralFactorMantissa;
        market.collateralFactorMantissa = newCollateralFactorMantissa;

        // Emit event with asset, old collateral factor, and new collateral factor
        emit NewCollateralFactor(
            chToken,
            oldCollateralFactorMantissa,
            newCollateralFactorMantissa
        );

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Sets liquidationIncentive
     * @dev Admin function to set liquidationIncentive
     * @param chToken Address of market where incentive to be set
     * @param newLiquidationIncentiveMantissa New liquidationIncentive scaled by 1e18
     * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
     */
    function _setLiquidationIncentive(address chToken, uint256 newLiquidationIncentiveMantissa)
        external
        returns (uint256)
    {
        // Check caller is admin
        if (msg.sender != admin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.SET_LIQUIDATION_INCENTIVE_OWNER_CHECK
                );
        }
        

        // Save current value for use in log
        uint256 oldLiquidationIncentiveMantissa = liquidationIncentive[chToken];

        // Set liquidation incentive to new incentive
        liquidationIncentive[chToken] = newLiquidationIncentiveMantissa;

        // Emit event with old incentive, new incentive
        emit NewLiquidationIncentive(
            chToken,
            oldLiquidationIncentiveMantissa,
            newLiquidationIncentiveMantissa
        );

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Add the market to the markets mapping and set it as listed
     * @dev Admin function to set isListed and add support for the market
     * @param chToken The address of the market (token) to list
     * @return uint 0=success, otherwise a failure. (See enum Error for details)
     */
    function _supportMarket(ChToken chToken) external returns (uint256) {
        if (msg.sender != admin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.SUPPORT_MARKET_OWNER_CHECK
                );
        }

        if (markets[address(chToken)].isListed) {
            return
                fail(
                    Error.MARKET_ALREADY_LISTED,
                    FailureInfo.SUPPORT_MARKET_EXISTS
                );
        }

        chToken.isChToken(); // Sanity check to make sure its really a ChToken

        markets[address(chToken)] = Market({
            isListed: true,
            collateralFactorMantissa: 0
        });

        _addMarketInternal(address(chToken));

        emit MarketListed(chToken);

        return uint256(Error.NO_ERROR);
    }

    function _addMarketInternal(address chToken) internal {
        for (uint256 i = 0; i < allMarkets.length; i++) {
            require(allMarkets[i] != ChToken(chToken), "market already added");
        }
        allMarkets.push(ChToken(chToken));
    }

    /**
     * @notice Set the given borrow caps for the given chToken markets. Borrowing that brings total borrows to or above borrow cap will revert.
     * @dev Admin or borrowCapGuardian function to set the borrow caps. A borrow cap of 0 corresponds to unlimited borrowing.
     * @param chTokens The addresses of the markets (tokens) to change the borrow caps for
     * @param newBorrowCaps The new borrow cap values in underlying to be set. A value of 0 corresponds to unlimited borrowing.
     */
    function _setMarketBorrowCaps(
        ChToken[] calldata chTokens,
        uint256[] calldata newBorrowCaps
    ) external {
        require(
            msg.sender == admin || msg.sender == borrowCapGuardian,
            "only admin or borrow cap guardian can set borrow caps"
        );

        uint256 numMarkets = chTokens.length;
        uint256 numBorrowCaps = newBorrowCaps.length;

        require(
            numMarkets != 0 && numMarkets == numBorrowCaps,
            "invalid input"
        );

        for (uint256 i = 0; i < numMarkets; i++) {
            borrowCaps[address(chTokens[i])] = newBorrowCaps[i];
            emit NewBorrowCap(chTokens[i], newBorrowCaps[i]);
        }
    }

    /**
     * @notice Admin function to change the Borrow Cap Guardian
     * @param newBorrowCapGuardian The address of the new Borrow Cap Guardian
     */
    function _setBorrowCapGuardian(address newBorrowCapGuardian) external {
        require(msg.sender == admin, "only admin can set borrow cap guardian");

        // Save current value for inclusion in log
        address oldBorrowCapGuardian = borrowCapGuardian;

        // Store borrowCapGuardian with value newBorrowCapGuardian
        borrowCapGuardian = newBorrowCapGuardian;

        // Emit NewBorrowCapGuardian(OldBorrowCapGuardian, NewBorrowCapGuardian)
        emit NewBorrowCapGuardian(oldBorrowCapGuardian, newBorrowCapGuardian);
    }

    /**
     * @notice Admin function to change the Pause Guardian
     * @param newPauseGuardian The address of the new Pause Guardian
     * @return uint 0=success, otherwise a failure. (See enum Error for details)
     */
    function _setPauseGuardian(address newPauseGuardian)
        public
        returns (uint256)
    {
        if (msg.sender != admin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.SET_PAUSE_GUARDIAN_OWNER_CHECK
                );
        }

        // Save current value for inclusion in log
        address oldPauseGuardian = pauseGuardian;

        // Store pauseGuardian with value newPauseGuardian
        pauseGuardian = newPauseGuardian;

        // Emit NewPauseGuardian(OldPauseGuardian, NewPauseGuardian)
        emit NewPauseGuardian(oldPauseGuardian, pauseGuardian);

        return uint256(Error.NO_ERROR);
    }

    function _setMintPaused(ChToken chToken, bool state) public returns (bool) {
        require(
            markets[address(chToken)].isListed,
            "cannot pause a market that is not listed"
        );
        require(
            msg.sender == pauseGuardian || msg.sender == admin,
            "only pause guardian and admin can pause"
        );
        require(msg.sender == admin || state == true, "only admin can unpause");

        mintGuardianPaused[address(chToken)] = state;
        emit ActionPaused(chToken, "Mint", state);
        return state;
    }

    function _setBorrowPaused(ChToken chToken, bool state) public returns (bool) {
        require(
            markets[address(chToken)].isListed,
            "cannot pause a market that is not listed"
        );
        require(
            msg.sender == pauseGuardian || msg.sender == admin,
            "only pause guardian and admin can pause"
        );
        require(msg.sender == admin || state == true, "only admin can unpause");

        borrowGuardianPaused[address(chToken)] = state;
        emit ActionPaused(chToken, "Borrow", state);
        return state;
    }

    function _setTransferPaused(bool state) public returns (bool) {
        require(
            msg.sender == pauseGuardian || msg.sender == admin,
            "only pause guardian and admin can pause"
        );
        require(msg.sender == admin || state == true, "only admin can unpause");

        transferGuardianPaused = state;
        emit ActionPaused("Transfer", state);
        return state;
    }

    function _setSeizePaused(bool state) public returns (bool) {
        require(
            msg.sender == pauseGuardian || msg.sender == admin,
            "only pause guardian and admin can pause"
        );
        require(msg.sender == admin || state == true, "only admin can unpause");

        seizeGuardianPaused = state;
        emit ActionPaused("Seize", state);
        return state;
    }

    function _become(DelegateComptroller unitroller) public {
        require(
            msg.sender == unitroller.admin(),
            "only unitroller admin can change brains"
        );
        require(
            unitroller._acceptImplementation() == 0,
            "change not authorized"
        );
    }

    /**
     * @notice Checks caller is admin, or this contract is becoming the new implementation
     */
    function adminOrInitializing() internal view returns (bool) {
        return msg.sender == admin || msg.sender == comptrollerImplementation;
    }

    /*** Reward Distribution ***/

    /**
     * @notice Set REWARD speed for a single market
     * @param chToken The market whose REWARD speed to update
     * @param rewardSpeed New REWARD speed for market
     */
    function setRewardSpeedInternal(ChToken chToken, uint256 rewardSpeed)
        internal
    {
        uint256 currentRewardSpeed = rewardSpeeds[address(chToken)];
        if (currentRewardSpeed != 0) {
            // note that REWARD speed could be set to 0 to halt liquidity rewards for a market
            Exp memory borrowIndex = Exp({mantissa: chToken.borrowIndex()});
            updateRewardSupplyIndex(address(chToken));
            updateRewardBorrowIndex(address(chToken), borrowIndex);
        } else if (rewardSpeed != 0) {
            // Add the REWARD market
            Market storage market = markets[address(chToken)];
            require(market.isListed == true, "market is not listed");

            if (rewardSupplyState[address(chToken)].index == 0) {
                rewardSupplyState[address(chToken)] = RewardMarketState({
                    index: rewardInitialIndex,
                    block: safe32(
                        getBlockNumber(),
                        "block number exceeds 32 bits"
                    )
                });
            }

            if (rewardBorrowState[address(chToken)].index == 0) {
                rewardBorrowState[address(chToken)] = RewardMarketState({
                    index: rewardInitialIndex,
                    block: safe32(
                        getBlockNumber(),
                        "block number exceeds 32 bits"
                    )
                });
            }
        }

        if (currentRewardSpeed != rewardSpeed) {
            rewardSpeeds[address(chToken)] = rewardSpeed;
            emit RewardSpeedUpdated(chToken, rewardSpeed);
        }
    }

    /**
     * @notice Accrue REWARD to the market by updating the supply index
     * @param chToken The market whose supply index to update
     */
    function updateRewardSupplyIndex(address chToken) internal {
        RewardMarketState storage supplyState = rewardSupplyState[chToken];
        uint256 supplySpeed = rewardSpeeds[chToken];
        uint256 blockNumber = getBlockNumber();
        uint256 deltaBlocks = sub_(blockNumber, uint256(supplyState.block));
        if (deltaBlocks > 0 && supplySpeed > 0) {
            uint256 supplyTokens = ChToken(chToken).totalSupply();
            uint256 rewardAccrued = mul_(deltaBlocks, supplySpeed);
            Double memory ratio = supplyTokens > 0
                ? fraction(rewardAccrued, supplyTokens)
                : Double({mantissa: 0});
            Double memory index = add_(
                Double({mantissa: supplyState.index}),
                ratio
            );
            rewardSupplyState[chToken] = RewardMarketState({
                index: safe224(index.mantissa, "new index exceeds 224 bits"),
                block: safe32(blockNumber, "block number exceeds 32 bits")
            });
        } else if (deltaBlocks > 0) {
            supplyState.block = safe32(
                blockNumber,
                "block number exceeds 32 bits"
            );
        }
    }

    /**
     * @notice Accrue REWARD to the market by updating the borrow index
     * @param chToken The market whose borrow index to update
     */
    function updateRewardBorrowIndex(
        address chToken,
        Exp memory marketBorrowIndex
    ) internal {
        RewardMarketState storage borrowState = rewardBorrowState[chToken];
        uint256 borrowSpeed = rewardSpeeds[chToken];
        uint256 blockNumber = getBlockNumber();
        uint256 deltaBlocks = sub_(blockNumber, uint256(borrowState.block));
        if (deltaBlocks > 0 && borrowSpeed > 0) {
            uint256 borrowAmount = div_(
                ChToken(chToken).totalBorrows(),
                marketBorrowIndex
            );
            uint256 rewardAccrued = mul_(deltaBlocks, borrowSpeed);
            Double memory ratio = borrowAmount > 0
                ? fraction(rewardAccrued, borrowAmount)
                : Double({mantissa: 0});
            Double memory index = add_(
                Double({mantissa: borrowState.index}),
                ratio
            );
            rewardBorrowState[chToken] = RewardMarketState({
                index: safe224(index.mantissa, "new index exceeds 224 bits"),
                block: safe32(blockNumber, "block number exceeds 32 bits")
            });
        } else if (deltaBlocks > 0) {
            borrowState.block = safe32(
                blockNumber,
                "block number exceeds 32 bits"
            );
        }
    }

    /**
     * @notice Calculate REWARD accrued by a supplier and possibly transfer it to them
     * @param chToken The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute REWARD to
     */
    function distributeSupplierReward(address chToken, address supplier)
        internal
    {
        RewardMarketState storage supplyState = rewardSupplyState[chToken];
        Double memory supplyIndex = Double({mantissa: supplyState.index});
        Double memory supplierIndex = Double({
            mantissa: rewardSupplierIndex[chToken][supplier]
        });
        rewardSupplierIndex[chToken][supplier] = supplyIndex.mantissa;

        if (supplierIndex.mantissa == 0 && supplyIndex.mantissa > 0) {
            supplierIndex.mantissa = rewardInitialIndex;
        }

        Double memory deltaIndex = sub_(supplyIndex, supplierIndex);
        uint256 supplieChTokens = ChToken(chToken).balanceOf(supplier);
        uint256 supplierDelta = mul_(supplieChTokens, deltaIndex);
        uint256 supplierAccrued = add_(rewardAccrued[supplier], supplierDelta);
        rewardAccrued[supplier] = supplierAccrued;
        emit DistributedSupplierReward(
            ChToken(chToken),
            supplier,
            supplierDelta,
            supplyIndex.mantissa
        );
    }

    /**
     * @notice Calculate REWARD accrued by a borrower and possibly transfer it to them
     * @dev Borrowers will not begin to accrue until after the first interaction with the protocol.
     * @param chToken The market in which the borrower is interacting
     * @param borrower The address of the borrower to distribute REWARD to
     */
    function distributeBorrowerReward(
        address chToken,
        address borrower,
        Exp memory marketBorrowIndex
    ) internal {
        RewardMarketState storage borrowState = rewardBorrowState[chToken];
        Double memory borrowIndex = Double({mantissa: borrowState.index});
        Double memory borrowerIndex = Double({
            mantissa: rewardBorrowerIndex[chToken][borrower]
        });
        rewardBorrowerIndex[chToken][borrower] = borrowIndex.mantissa;

        if (borrowerIndex.mantissa > 0) {
            Double memory deltaIndex = sub_(borrowIndex, borrowerIndex);
            uint256 borrowerAmount = div_(
                ChToken(chToken).borrowBalanceStored(borrower),
                marketBorrowIndex
            );
            uint256 borrowerDelta = mul_(borrowerAmount, deltaIndex);
            uint256 borrowerAccrued = add_(
                rewardAccrued[borrower],
                borrowerDelta
            );
            rewardAccrued[borrower] = borrowerAccrued;
            emit DistributedBorrowerReward(
                ChToken(chToken),
                borrower,
                borrowerDelta,
                borrowIndex.mantissa
            );
        }
    }

    /**
     * @notice Claim all the reward accrued by holder in all markets
     * @param holder The address to claim REWARD for
     */
    function claimReward(address holder) public {
        return claimReward(holder, allMarkets);
    }

    /**
     * @notice Claim all the reward accrued by holder in the specified markets
     * @param holder The address to claim REWARD for
     * @param chTokens The list of markets to claim REWARD in
     */
    function claimReward(address holder, ChToken[] memory chTokens) public {
        address[] memory holders = new address[](1);
        holders[0] = holder;
        claimReward(holders, chTokens, true, true);
    }

    /**
     * @notice Claim all reward accrued by the holders
     * @param holders The addresses to claim REWARD for
     * @param chTokens The list of markets to claim REWARD in
     * @param borrowers Whether or not to claim REWARD earned by borrowing
     * @param suppliers Whether or not to claim REWARD earned by supplying
     */
    function claimReward(
        address[] memory holders,
        ChToken[] memory chTokens,
        bool borrowers,
        bool suppliers
    ) public {
        for (uint256 i = 0; i < chTokens.length; i++) {
            ChToken chToken = chTokens[i];
            require(markets[address(chToken)].isListed, "market must be listed");
            if (borrowers == true) {
                Exp memory borrowIndex = Exp({mantissa: chToken.borrowIndex()});
                updateRewardBorrowIndex(address(chToken), borrowIndex);
                for (uint256 j = 0; j < holders.length; j++) {
                    distributeBorrowerReward(
                        address(chToken),
                        holders[j],
                        borrowIndex
                    );
                    rewardAccrued[holders[j]] = grantRewardInternal(
                        holders[j],
                        rewardAccrued[holders[j]]
                    );
                }
            }
            if (suppliers == true) {
                updateRewardSupplyIndex(address(chToken));
                for (uint256 j = 0; j < holders.length; j++) {
                    distributeSupplierReward(address(chToken), holders[j]);
                    rewardAccrued[holders[j]] = grantRewardInternal(
                        holders[j],
                        rewardAccrued[holders[j]]
                    );
                }
            }
        }
    }

    /**
     * @notice Mint REWARD to the user
     * @dev Note: Revert if mint failed.
     * @param user The address of the user to transfer REWARD to
     * @param amount The amount of REWARD to (possibly) transfer
     * @return The amount of REWARD which was NOT transferred to the user
     */
    function grantRewardInternal(address user, uint256 amount)
        internal
        returns (uint256)
    {
        if (amount == 0) {
            return 0;
        }
        RewardMinterInterface rewardDistributor = RewardMinterInterface(getRewardDistributor());
        rewardDistributor.mint(user, amount);
        return 0;
    }

    /*** Reward Distribution Admin ***/

    /**
     * @notice Set REWARD speed for a single market
     * @param chToken The market whose REWARD speed to update
     * @param rewardSpeed New REWARD speed for market
     */
    function _setRewardSpeed(ChToken chToken, uint256 rewardSpeed) public {
        require(adminOrInitializing(), "only admin can set reward speed");
        setRewardSpeedInternal(chToken, rewardSpeed);
    }

    /**
     * @notice Return all of the markets
     * @dev The automatic getter may be used to access an individual market.
     * @return The list of market addresses
     */
    function getAllMarkets() public view returns (ChToken[] memory) {
        return allMarkets;
    }

    function getBlockNumber() public view returns (uint256) {
        return block.number;
    }

    /**
     * @notice Return the address of the reward distributor contract
     * @return the address of the reward distributor contract
     */
    function getRewardDistributor() public pure returns (address) {
        return 0x0000000000000000000000000000000000000000;
    }

    /**
     * @notice Return address profit controller
     * @return profitController
     */
    function getProfitController() public view returns(address) {
        return profitController;
    }

    function _setLiquidationThreshold(
        address chToken,
        uint256 _liquidationThreshold
    ) public returns (uint256) {
        if (msg.sender != admin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.SET_LIQUIDATION_THRESHOLD_ADMIN_CHECK
                );
        }

        if (!markets[chToken].isListed) {
            return
                fail(
                    Error.MARKET_NOT_LISTED,
                    FailureInfo.SET_LIQUIDATION_THRESHOLD_VALIDATION
                );
        }

        if (
            _liquidationThreshold > 1e18 ||
            _liquidationThreshold < markets[chToken].collateralFactorMantissa
        ) {
            return
                fail(
                    Error.BAD_INPUT,
                    FailureInfo.SET_LIQUIDATION_THRESHOLD_VALIDATION
                );
        }

        uint256 oldValue = liquidationThreshold[chToken];
        liquidationThreshold[chToken] = _liquidationThreshold;

        emit NewLiquidationThreshold(chToken, oldValue, _liquidationThreshold);
    }

    function _setProfitController(address newProfitController)
        public
        returns (uint256)
    {
        if (msg.sender != admin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.SET_PROFIT_CONTROLLER_ADMIN_CHECK
                );
        }

        address oldValue = profitController;
        profitController = newProfitController;

        emit NewProfitController(oldValue, newProfitController);
    }
}
