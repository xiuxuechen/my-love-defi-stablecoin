// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {MyLoveStableCoin} from "../../src/MyLoveStableCoin.sol";
import {MLSCEngine} from "../../src/MLSCEngine.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ContinueOnRevertHandler} from "./ContinueOnRevertHandler.t.sol";

contract ContinueOnRevertHandler is Test {
    MLSCEngine public mlscEngine;
    MyLoveStableCoin public mlsc;
    MockV3Aggregator public ethUsdPriceFeed;
    MockV3Aggregator public btcUsdPriceFeed;
    ERC20Mock public wethMock;
    ERC20Mock public wbtcMock;

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
        collateral.mint(msg.sender, amountCollateral);
        mlscEngine.depositCollateral(address(collateral), amountCollateral);
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
