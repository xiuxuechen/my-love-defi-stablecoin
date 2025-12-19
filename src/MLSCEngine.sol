// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MyLoveStableCoin} from "./MyLoveStableCoin.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

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
    mapping(address user => mapping(address token => uint256 amount)) public sCollateralDeposited;

    /// @dev 抵押人 => 稳定币数量
    mapping(address user => uint256 amount) private sMLSCMinted;

    /// @dev 抵押物类型
    address[] private sCollateralTokenTypes;

    /**
     * ---------------------事件-----------------------
     */
    /// @dev 抵押物被存入
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

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
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address stableCoinAddress) {
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
     * --------------------公共调用函数---------------------
     */

    /**
     * @dev 存入抵押物
     * @param tokenCollateralAddress 抵押物类型
     * @param amountCollateral 抵押物数量
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
    {
        sCollateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert MLSCEngine__TransferFailed();
        }
    }

    /**
     * @dev 铸造稳定币
     * @param amountMlscToMint 稳定币数量
     */
    function mintDsc(uint256 amountMlscToMint) public moreThanZero(amountMlscToMint) nonReentrant {
        sMLSCMinted[msg.sender] += amountMlscToMint;
        bool minted = I_COIN.mint(msg.sender, amountMlscToMint);
        if (minted != true) {
            revert MLSCEngine__MintFailed();
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
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    /**
     * @dev 获取账户抵押物信息
     * @param user 用户地址
     * @return 账户中已铸的稳定币数量
     * @return 账户中抵押物价值(USD)
     */
    function _getAccountInformation(address user) internal view returns (uint256, uint256) {
        uint256 totalDscMinted = sMLSCMinted[user];
        uint256 collateralValueInUsd = getUserCollateralValueInUsd(user);
        return (totalDscMinted, collateralValueInUsd);
    }

    /**
     * @dev 获取用户抵押物总价值(USD)
     * @param user 用户地址
     * @return 用户抵押物总价值(USD)
     */
    function getUserCollateralValueInUsd(address user) public view returns (uint256) {
        uint256 totalCollateralValueInUsd;
        for (uint256 i = 0; i < sCollateralTokenTypes.length; i++) {
            address token = sCollateralTokenTypes[i];
            uint256 userCollateralAmount = sCollateralDeposited[user][token];
            uint256 collateralPrice = getCollateralPrice(token, userCollateralAmount);
            totalCollateralValueInUsd += collateralPrice;
        }
        return totalCollateralValueInUsd;
    }

    /**
     * @dev 获取单种抵押物价值(USD)
     * @param token 抵押物类型
     * @param amount 抵押物数量
     * @return 抵押物价值(USD)
     */
    function getCollateralPrice(address token, uint256 amount) public view returns (uint256) {
        address priceFeedAddress = sPriceFeeds[token];
        AggregatorV3Interface priceFeed = AggregatorV3Interface(priceFeedAddress);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return (uint256(price) * ADDITIONAL_FEED_PRECISION * amount) / PRECISION;
    }
}
