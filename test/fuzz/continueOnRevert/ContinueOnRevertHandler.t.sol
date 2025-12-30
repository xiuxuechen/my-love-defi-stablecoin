// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {MyLoveStableCoin} from "../../../src/MyLoveStableCoin.sol";
import {MLSCEngine} from "../../../src/MLSCEngine.sol";
import {ERC20Mock} from "../../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../../mocks/MockV3Aggregator.sol";
import {HelperConfig} from "../../../script/HelperConfig.s.sol";
import {ContinueOnRevertHandler} from "./ContinueOnRevertHandler.t.sol";

contract ContinueOnRevertHandler is Test {
    MLSCEngine public mlscEngine;
    MyLoveStableCoin public mlsc;
    MockV3Aggregator public ethUsdPriceFeed;
    MockV3Aggregator public btcUsdPriceFeed;
    ERC20Mock public wethMock;
    ERC20Mock public wbtcMock;

    uint256 public mintIsCalled;
    address[] public depositCollateralCalledUsers;

    uint96 public constant MAX_DEPOSIT_SIZE = type(uint96).max;

    constructor(
        MLSCEngine _mlscEngine,
        MyLoveStableCoin _mlsc,
        HelperConfig _helperConfig
    ) {
        mlscEngine = _mlscEngine;
        mlsc = _mlsc;
        (
            address wethUsdPriceFeed,
            address wbtcUsdPriceFeed,
            address weth,
            address wbtc,

        ) = _helperConfig.activeNetworkConfig();

        ethUsdPriceFeed = MockV3Aggregator(wethUsdPriceFeed);
        btcUsdPriceFeed = MockV3Aggregator(wbtcUsdPriceFeed);
        wethMock = ERC20Mock(weth);
        wbtcMock = ERC20Mock(wbtc);
    }

    function mintAndDepositCollateral(
        uint256 collateralSeed,
        uint256 amountCollateral
    ) public {
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        //必须给handler造钱，因为是handler调用的mlscEngine，否则mlscEngine去转钱会因为handler没有钱报错
        collateral.mint(address(this), amountCollateral);
        collateral.approve(address(mlscEngine), amountCollateral);
        mlscEngine.depositCollateral(address(collateral), amountCollateral);

        depositCollateralCalledUsers.push(msg.sender);
    }

    function mintDsc(uint256 amountDsc, uint256 collateralSeed) public {
        if (depositCollateralCalledUsers.length == 0) {
            return;
        }
        address sender = depositCollateralCalledUsers[
            collateralSeed % depositCollateralCalledUsers.length
        ];
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = mlscEngine
            .getAccountInformation(sender);
        //这里用int256是为了避免uint256运算时出现下溢情况导致的revert
        //计算可借的mlsc数量（健康度不能<1）
        //可借的mlsc数量 = 抵押物价值(USD) / 2 - 账户中已铸的mlsc数量
        int256 maxMlscToMint = (int256(collateralValueInUsd) / 2) -
            int256(totalDscMinted);
        if (maxMlscToMint <= 0) {
            return;
        }
        amountDsc = uint256(bound(amountDsc, 0, uint256(maxMlscToMint)));
        vm.startPrank(sender);
        mlscEngine.mintDsc(amountDsc);
        vm.stopPrank();
        mintIsCalled++;
    }

    function redeemCollateralForDsc(
        uint256 collateralSeed,
        uint256 amountCollateral
    ) public {
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        mlscEngine.redeemCollateralForDsc(address(collateral), 1, 1);
    }

    function _getCollateralFromSeed(
        uint256 collateralSeed
    ) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return wethMock;
        } else {
            return wbtcMock;
        }
    }
}
