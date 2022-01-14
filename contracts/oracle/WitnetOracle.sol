// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;
import "@openzeppelin/contracts/access/Ownable.sol";
import "./IERC2362.sol";

/**
 * @title Mojito's price oracle, rely on various witnet price feed
 * @author Mojito developers
 */
contract WitnetOracle is Ownable {
    enum PriceSource {
        FixedValue,
        Witnet
    }

    struct TokenConfig {
        PriceSource source;
        uint256 fixedPrice;
        address witnetFeed;
        bytes32 assetId;
        uint256 baseUnit; // 10 ^ underlying token decimals
        uint256 priceUnit; // 10 ^ price decimals
    }

    mapping(address => TokenConfig) public getTokenConfigByMToken;
    bytes32 private constant EMPTY_STRING = keccak256(abi.encodePacked(""));

    event TokenConfigChanged(
        address indexed token,
        PriceSource source,
        uint256 fixedPrice,
        address witnetFeed,
        bytes32 assetId
    );

    function getUnderlyingPrice(address _mToken)
        external
        view
        returns (uint256)
    {
        TokenConfig storage config = getTokenConfigByMToken[address(_mToken)];
        // Comptroller needs prices in the format: ${raw price} * 1e(36 - baseUnit)
        // Since the prices in this view have it own decimals, we must scale them by 1e(36 - priceUnit - baseUnit)
        return ((1e36 / config.priceUnit) * getPrice(config)) / config.baseUnit;
    }

    function configToken(
        address _mToken,
        PriceSource _source,
        uint256 _fixedPrice,
        uint256 _underlyingDecimals,
        address _witnetPriceFeed,
        uint256 _priceFeedDecimals,
        string memory _assetId
    ) external onlyOwner {
        bytes32 assetId = keccak256(abi.encodePacked(_assetId));
        if (_source == PriceSource.FixedValue) {
            require(_fixedPrice != 0, "priceValueRequired");
            require(_witnetPriceFeed == address(0), "priceFeedNotAllowed");
            require(assetId == EMPTY_STRING, "assetIdNotAllowed");
        }

        if (_source == PriceSource.Witnet) {
            require(_fixedPrice == 0, "priceValueNotAllowed");
            require(_witnetPriceFeed != address(0), "priceFeedRequired");
            require(assetId != EMPTY_STRING, "assetIdRequired");
        }

        TokenConfig memory config = TokenConfig({
            source: _source,
            witnetFeed: _witnetPriceFeed,
            fixedPrice: _fixedPrice,
            assetId: assetId,
            baseUnit: 10**_underlyingDecimals,
            priceUnit: 10**_priceFeedDecimals
        });

        getTokenConfigByMToken[_mToken] = config;
        emit TokenConfigChanged(
            _mToken,
            _source,
            _fixedPrice,
            _witnetPriceFeed,
            assetId
        );
    }

    function getPrice(TokenConfig memory _config)
        private
        view
        returns (uint256)
    {
        if (_config.source == PriceSource.Witnet) {
            IERC2362 feed = IERC2362(_config.witnetFeed);
            (int256 value, , ) = feed.valueFor(_config.assetId);
            return uint256(value);
        }
        if (_config.source == PriceSource.FixedValue) {
            return _config.fixedPrice;
        }

        revert("Invalid token config");
    }
}
