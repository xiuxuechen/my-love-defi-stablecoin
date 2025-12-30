// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployMLSC} from "../../../script/DeployMLSC.s.sol";
import {MyLoveStableCoin} from "../../../src/MyLoveStableCoin.sol";
import {MLSCEngine} from "../../../src/MLSCEngine.sol";
import {ERC20Mock} from "../../mocks/ERC20Mock.sol";
import {HelperConfig} from "../../../script/HelperConfig.s.sol";
import {ContinueOnRevertHandler} from "./ContinueOnRevertHandler.t.sol";

contract ContinueOnRevertInvariantsTest is StdInvariant, Test {
    DeployMLSC public deployer;
    MyLoveStableCoin public mlsc;
    MLSCEngine public engine;
    HelperConfig public config;
    ContinueOnRevertHandler public handler;

    address public wethUsdPriceFeed;
    address public wbtcUsdPriceFeed;
    address public weth;
    address public wbtc;
    uint256 public deployerKey;

    function setUp() public {
        deployer = new DeployMLSC();
        (mlsc, engine, config) = deployer.run();
        (wethUsdPriceFeed, wbtcUsdPriceFeed, weth, wbtc, deployerKey) = config
            .activeNetworkConfig();
        handler = new ContinueOnRevertHandler(engine, mlsc, config);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupplyDollars()
        public
        view
    {
        uint256 totalMintedMlsc = mlsc.totalSupply();

        uint256 totalWethDeposited = ERC20Mock(weth).balanceOf(address(engine));
        uint256 totalWbtcDeposited = ERC20Mock(wbtc).balanceOf(address(engine));

        uint256 wethValueInUsd = engine.getCollateralUsdPrice(
            weth,
            totalWethDeposited
        );
        uint256 wbtcValueInUsd = engine.getCollateralUsdPrice(
            wbtc,
            totalWbtcDeposited
        );

        console.log("wethValue:", wethValueInUsd);
        console.log("wbtcValue:", wbtcValueInUsd);
        console.log("mintIsCalled:", handler.mintIsCalled());

        assert((wethValueInUsd + wbtcValueInUsd) >= totalMintedMlsc);
    }
}
