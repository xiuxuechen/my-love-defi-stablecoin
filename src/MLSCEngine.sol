// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OracleLib} from "./libraries/OracleLib.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MyLoveStableCoin} from "./MyLoveStableCoin.sol";
import {
    AggregatorV3Interface
} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract MLSCEngine is ReentrancyGuard {
    /**
     * ----------------------异常------------------------
     */
    error MLSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch();
    error MLSCEngine__NeedsMoreThanZero();
    error MLSCEngine__TokenNotAllowed(address token);
    error MLSCEngine__TransferFailed();
    error MLSCEngine__MintFailed();
    error MLSCEngine__BreaksHealthFactor(uint256 healthFactorValue);
    error MLSCEngine__HealthFactorOk();
    error MLSCEngine__HealthFactorNotImproved();

    using OracleLib for AggregatorV3Interface;

    /**
     * --------------------常量----------------------
     */
    //标准精度
    uint256 private constant PRECISION = 1e18;
    //清算阈值
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    //清算奖金
    uint256 private constant LIQUIDATION_BONUS = 10;
    //清算精度
    uint256 private constant LIQUIDATION_PRECISION = 100;
    //补充精度
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    //稳定币精度
    uint256 private constant FEED_PRECISION = 1e8;

    /**
     * --------------------状态变量----------------------
     */

    /// @dev 稳定币
    MyLoveStableCoin private immutable I_COIN;

    /// @dev 抵押物类型 => 价格 映射
    mapping(address collateralToken => address priceFeed) private sPriceFeeds;

    /// @dev 抵押人 => 抵押物类型 => 抵押物数量
    mapping(address user => mapping(address token => uint256 amount))
        public sCollateralDeposited;

    /// @dev 抵押人 => 稳定币数量
    mapping(address user => uint256 amount) private sMLSCMinted;

    /// @dev 抵押物类型
    address[] private sCollateralTokenTypes;

    /**
     * ---------------------事件-----------------------
     */
    /// @dev 抵押物被存入
    event CollateralDeposited(
        address indexed user,
        address indexed token,
        uint256 indexed amount
    );
    /// @dev 抵押物被赎回
    event CollateralRedeemed(
        address indexed token,
        address indexed from,
        address indexed to,
        uint256 amount
    );

    /**
     * --------------------装饰器----------------------
     */
    /// @dev 确保大于0
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert MLSCEngine__NeedsMoreThanZero();
        }
        _;
    }
    /// @dev 确保是允许的代币
    modifier isAllowedToken(address token) {
        if (sPriceFeeds[token] == address(0)) {
            revert MLSCEngine__TokenNotAllowed(token);
        }
        _;
    }

    /**
     * --------------------构造函数----------------------
     */
    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address stableCoinAddress
    ) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert MLSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            sPriceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            sCollateralTokenTypes.push(tokenAddresses[i]);
        }
        I_COIN = MyLoveStableCoin(stableCoinAddress);
    }

    /**
     * --------------------外部调用函数----------------------
     */

    /**
     * @dev 存入抵押物并铸造稳定币
     * @param tokenCollateralAddress 抵押物类型
     * @param amountCollateral 抵押物数量
     * @param amountMlscToMint 稳定币数量
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountMlscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountMlscToMint);
    }

    /**
     * @dev 用户自己赎回抵押物并销毁稳定币
     * @param tokenCollateralAddress 抵押物类型
     * @param amountCollateralToRedeem 抵押物数量
     * @param amountMlscToBurn 稳定币数量
     */
    function redeemCollateralForDsc(
        address tokenCollateralAddress,
        uint256 amountCollateralToRedeem,
        uint256 amountMlscToBurn
    )
        external
        moreThanZero(amountCollateralToRedeem)
        isAllowedToken(tokenCollateralAddress)
    {
        _burnDsc(amountMlscToBurn, msg.sender, address(this));
        _redeemCollateral(
            tokenCollateralAddress,
            amountCollateralToRedeem,
            msg.sender,
            msg.sender
        );
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @dev 清算用户
     * @param collateralToken 抵押物类型
     * @param userToLiquidate 待清算用户
     * @param debtToCover 待清算mlsc的数量
     */
    function liquidate(
        address collateralToken,
        address userToLiquidate,
        uint256 debtToCover
    )
        external
        moreThanZero(debtToCover)
        isAllowedToken(collateralToken)
        nonReentrant
    {
        uint256 startingHealthFactor = _healthFactor(userToLiquidate);
        if (startingHealthFactor >= PRECISION) {
            revert MLSCEngine__HealthFactorOk();
        }
        // 获取清算抵押物价值
        uint256 tokenAmount = getMlscPrice(collateralToken, debtToCover);
        // 清算奖励，清算抵押物价值的10%
        uint256 bonusCollateral = (tokenAmount * LIQUIDATION_BONUS) /
            LIQUIDATION_PRECISION;
        // 转移被清算用户的抵押物和清算奖励给清算人
        _redeemCollateral(
            collateralToken,
            tokenAmount + bonusCollateral,
            userToLiquidate,
            msg.sender
        );
        // 销毁被清算用户的mlsc，并转移被清算用户的mlsc给清算人
        _burnDsc(debtToCover, userToLiquidate, msg.sender);

        //以下按正常场景用不上，放在这就是不怕一万就怕万一
        // 确保清算人的健康因子被提升
        uint256 endingHealthFactor = _healthFactor(userToLiquidate);
        if (endingHealthFactor <= startingHealthFactor) {
            revert MLSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(userToLiquidate);
    }

    /**
     * --------------------公共调用函数---------------------
     */

    /**
     * @dev 存入抵押物
     * @param tokenCollateralAddress 抵押物类型
     * @param amountCollateral 抵押物数量
     */
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
    {
        sCollateralDeposited[msg.sender][
            tokenCollateralAddress
        ] += amountCollateral;
        IERC20(tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            amountCollateral
        );
        emit CollateralDeposited(
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );
    }

    /**
     * @dev 铸造稳定币
     * @param amountMlscToMint 稳定币数量
     */
    function mintDsc(
        uint256 amountMlscToMint
    ) public moreThanZero(amountMlscToMint) nonReentrant {
        sMLSCMinted[msg.sender] += amountMlscToMint;
        bool minted = I_COIN.mint(msg.sender, amountMlscToMint);
        if (minted != true) {
            revert MLSCEngine__MintFailed();
        }
    }

    /**
     * @dev 获取用户抵押物总价值(USD)
     * @param user 用户地址
     * @return 用户抵押物总价值(USD)
     */
    function getUserCollateralValueInUsd(
        address user
    ) public view returns (uint256) {
        uint256 totalCollateralValueInUsd;
        for (uint256 i = 0; i < sCollateralTokenTypes.length; i++) {
            address token = sCollateralTokenTypes[i];
            uint256 userCollateralAmount = sCollateralDeposited[user][token];
            uint256 collateralPrice = getCollateralUsdPrice(
                token,
                userCollateralAmount
            );
            totalCollateralValueInUsd += collateralPrice;
        }
        return totalCollateralValueInUsd;
    }

    /**
     * @dev 获取单种抵押物价值(单位：USD)
     * @param token 抵押物类型
     * @param amount 抵押物数量
     * @return 抵押物价值(单位：USD)
     */
    function getCollateralUsdPrice(
        address token,
        uint256 amount
    ) public view returns (uint256) {
        address priceFeedAddress = sPriceFeeds[token];
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            priceFeedAddress
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return
            (uint256(price) * ADDITIONAL_FEED_PRECISION * amount) / PRECISION;
    }

    /**
     * @dev 获取单种抵押物价值(单位：ETH)
     * @param token 抵押物类型
     * @param usdAmountInWei MLSC数量
     * @return 抵押物价值(单位：ETH)
     */
    function getMlscPrice(
        address token,
        uint256 usdAmountInWei
    ) public view returns (uint256) {
        address priceFeedAddress = sPriceFeeds[token];
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            priceFeedAddress
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();
        // 价值MLSC = usd价格 / mlsc价格
        //这里的usdAmountInWei传的其实是稳定币数量，但因稳定币跟美元锚定关系，当作1稳定币=1美元，故直接当价格计算
        return
            ((usdAmountInWei * PRECISION)) /
            (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    /**
     * @dev 获取账户抵押物信息
     * @param user 用户地址
     * @return 账户中已铸的稳定币数量
     * @return 账户中抵押物价值(USD)
     */
    function getAccountInformation(
        address user
    ) public view returns (uint256, uint256) {
        uint256 totalDscMinted = sMLSCMinted[user];
        uint256 collateralValueInUsd = getUserCollateralValueInUsd(user);
        return (totalDscMinted, collateralValueInUsd);
    }

    /**
     * --------------------私有函数---------------------
     */

    /**
     * @dev 销毁用户mlsc稳定币
     * @param amount 销毁mlsc稳定币数量
     * @param burnUser 被销毁用户
     * @param to 主动清算用户
     */
    function _burnDsc(
        uint256 amount,
        address burnUser,
        address to
    ) private moreThanZero(amount) {
        sMLSCMinted[burnUser] -= amount;
        bool success = I_COIN.transferFrom(burnUser, to, amount);
        if (!success) {
            revert MLSCEngine__TransferFailed();
        }
        I_COIN.burn(amount);
    }

    /**
     * @dev 赎回抵押物
     * @param tokenCollateralAddress 抵押物类型
     * @param amountCollateral 抵押物数量
     * @param from 赎回用户
     * @param to 获取抵押物用户
     */
    function _redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        address from,
        address to
    ) private {
        sCollateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(
            tokenCollateralAddress,
            from,
            to,
            amountCollateral
        );
        bool success = IERC20(tokenCollateralAddress).transfer(
            to,
            amountCollateral
        );
        if (!success) {
            revert MLSCEngine__TransferFailed();
        }
    }

    /**
     * --------------------内部函数---------------------
     */

    /**
     * @dev 判断用户抵押物健康度
     * @param user 用户地址
     */
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < PRECISION) {
            revert MLSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    /**
     * @dev 获取用户抵押物健康度
     * @param user 用户地址
     * @return 用户抵押物健康度
     */
    function _healthFactor(address user) internal view returns (uint256) {
        (
            uint256 totalDscMinted,
            uint256 collateralValueInUsd
        ) = getAccountInformation(user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    /**
     * @dev 计算用户抵押物健康度
     * @param totalDscMinted 账户中已铸的稳定币数量
     * @param collateralValueInUsd 账户中抵押物价值(USD)
     * @return 用户抵押物健康度
     */
    function _calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collateralValueInUsd
    ) internal pure returns (uint256) {
        if (totalDscMinted == 0) return type(uint256).max;
        //这里是只认50%的抵押物防止抵押物价值波动
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd *
            LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function getCollateralTokenPriceFeed(
        address token
    ) external view returns (address) {
        return sPriceFeeds[token];
    }

    function getCollateralDeposited(
        address user,
        address token
    ) external view returns (uint256) {
        return sCollateralDeposited[user][token];
    }

    function getMLSCMinted(address user) external view returns (uint256) {
        return sMLSCMinted[user];
    }
}
