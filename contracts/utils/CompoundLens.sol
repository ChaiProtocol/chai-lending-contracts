// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.5.16;
pragma experimental ABIEncoderV2;

import "../ChToken/ChErc20.sol";
import "../ChToken/ChToken.sol";
import "../interfaces/PriceOracle.sol";
import "../interfaces/EIP20Interface.sol";

interface CompoundLensInterface {
    function markets(address) external view returns (bool, uint);
    function liquidationThreshold(address) external view returns (uint);
    function liquidationIncentive(address) external view returns (uint);
    function oracle() external view returns (PriceOracle);
    function getAccountLiquidity(address) external view returns (uint, uint, uint);
    function getAssetsIn(address) external view returns (ChToken[] memory);
    function claimReward(address) external;
    function rewardAccrued(address) external view returns (uint);
}


contract CompoundLens {
    struct ChTokenMetadata {
        address chToken;
        uint exchangeRateCurrent;
        uint supplyRatePerBlock;
        uint borrowRatePerBlock;
        uint reserveFactorMantissa;
        uint totalBorrows;
        uint totalReserves;
        uint totalSupply;
        uint totalCash;
        bool isListed;
        uint collateralFactorMantissa;
        address underlyingAssetAddress;
        uint cTokenDecimals;
        uint underlyingDecimals;
        uint liquidationThreshold;
        uint liquidationIncentive;
    }

    function cTokenMetadata(ChToken chToken) public returns (ChTokenMetadata memory) {
        uint exchangeRateCurrent = chToken.exchangeRateCurrent();
        CompoundLensInterface comptroller = CompoundLensInterface(address(chToken.comptroller()));
        (bool isListed, uint collateralFactorMantissa) = comptroller.markets(address(chToken));
        address underlyingAssetAddress;
        uint underlyingDecimals;

        if (compareStrings(chToken.symbol(), "cETH")) {
            underlyingAssetAddress = address(0);
            underlyingDecimals = 18;
        } else {
            ChErc20 cErc20 = ChErc20(address(chToken));
            underlyingAssetAddress = cErc20.underlying();
            underlyingDecimals = EIP20Interface(cErc20.underlying()).decimals();
        }

        return ChTokenMetadata({
            chToken: address(chToken),
            exchangeRateCurrent: exchangeRateCurrent,
            supplyRatePerBlock: chToken.supplyRatePerBlock(),
            borrowRatePerBlock: chToken.borrowRatePerBlock(),
            reserveFactorMantissa: chToken.reserveFactorMantissa(),
            totalBorrows: chToken.totalBorrows(),
            totalReserves: chToken.totalReserves(),
            totalSupply: chToken.totalSupply(),
            totalCash: chToken.getCash(),
            isListed: isListed,
            collateralFactorMantissa: collateralFactorMantissa,
            underlyingAssetAddress: underlyingAssetAddress,
            cTokenDecimals: chToken.decimals(),
            underlyingDecimals: underlyingDecimals,
            liquidationThreshold: comptroller.liquidationThreshold(address(chToken)),
            liquidationIncentive: comptroller.liquidationIncentive(address(chToken))
        });
    }

    function cTokenMetadataAll(ChToken[] calldata cTokens) external returns (ChTokenMetadata[] memory) {
        uint cTokenCount = cTokens.length;
        ChTokenMetadata[] memory res = new ChTokenMetadata[](cTokenCount);
        for (uint i = 0; i < cTokenCount; i++) {
            res[i] = cTokenMetadata(cTokens[i]);
        }
        return res;
    }

    struct ChTokenBalances {
        address chToken;
        uint balanceOf;
        uint borrowBalanceCurrent;
        uint balanceOfUnderlying;
        uint tokenBalance;
        uint tokenAllowance;
    }

    function cTokenBalances(ChToken chToken, address payable account) public returns (ChTokenBalances memory) {
        uint balanceOf = chToken.balanceOf(account);
        uint borrowBalanceCurrent = chToken.borrowBalanceCurrent(account);
        uint balanceOfUnderlying = chToken.balanceOfUnderlying(account);
        uint tokenBalance;
        uint tokenAllowance;

        if (compareStrings(chToken.symbol(), "cETH")) {
            tokenBalance = account.balance;
            tokenAllowance = account.balance;
        } else {
            ChErc20 cErc20 = ChErc20(address(chToken));
            EIP20Interface underlying = EIP20Interface(cErc20.underlying());
            tokenBalance = underlying.balanceOf(account);
            tokenAllowance = underlying.allowance(account, address(chToken));
        }

        return ChTokenBalances({
            chToken: address(chToken),
            balanceOf: balanceOf,
            borrowBalanceCurrent: borrowBalanceCurrent,
            balanceOfUnderlying: balanceOfUnderlying,
            tokenBalance: tokenBalance,
            tokenAllowance: tokenAllowance
        });
    }

    function cTokenBalancesAll(ChToken[] calldata cTokens, address payable account) external returns (ChTokenBalances[] memory) {
        uint cTokenCount = cTokens.length;
        ChTokenBalances[] memory res = new ChTokenBalances[](cTokenCount);
        for (uint i = 0; i < cTokenCount; i++) {
            res[i] = cTokenBalances(cTokens[i], account);
        }
        return res;
    }

    struct ChTokenUnderlyingPrice {
        address chToken;
        uint underlyingPrice;
    }

    function cTokenUnderlyingPrice(ChToken chToken) public view returns (ChTokenUnderlyingPrice memory) {
        CompoundLensInterface comptroller = CompoundLensInterface(address(chToken.comptroller()));
        PriceOracle priceOracle = comptroller.oracle();

        return ChTokenUnderlyingPrice({
            chToken: address(chToken),
            underlyingPrice: priceOracle.getUnderlyingPrice(chToken)
        });
    }

    function cTokenUnderlyingPriceAll(ChToken[] calldata cTokens) external view returns (ChTokenUnderlyingPrice[] memory) {
        uint cTokenCount = cTokens.length;
        ChTokenUnderlyingPrice[] memory res = new ChTokenUnderlyingPrice[](cTokenCount);
        for (uint i = 0; i < cTokenCount; i++) {
            res[i] = cTokenUnderlyingPrice(cTokens[i]);
        }
        return res;
    }

    struct AccountLimits {
        ChToken[] markets;
        uint liquidity;
        uint shortfall;
    }

    function getAccountLimits(CompoundLensInterface comptroller, address account) public view returns (AccountLimits memory) {
        (uint errorCode, uint liquidity, uint shortfall) = comptroller.getAccountLiquidity(account);
        require(errorCode == 0);

        return AccountLimits({
            markets: comptroller.getAssetsIn(account),
            liquidity: liquidity,
            shortfall: shortfall
        });
    }

    struct CompBalanceMetadataExt {
        uint balance;
        uint votes;
        address delegate;
        uint allocated;
    }

    function compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
    }
}
