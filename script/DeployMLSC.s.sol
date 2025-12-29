// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {MyLoveStableCoin} from "../src/MyLoveStableCoin.sol";
import {MLSCEngine} from "../src/MLSCEngine.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployMLSC is Script {
    MyLoveStableCoin public mlsc;
    MLSCEngine public mlscEngine;

    function run() external returns (MyLoveStableCoin, MLSCEngine, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig();
        (address wethPriceFeed, address wbtcPriceFeed, address weth, address wbtc, uint256 deployerKey) =
            helperConfig.activeNetworkConfig();

        vm.startBroadcast(deployerKey);

        mlsc = new MyLoveStableCoin();
        address[] memory tokenAddresses = new address[](2);
        tokenAddresses[0] = weth;
        tokenAddresses[1] = wbtc;
        address[] memory priceFeedAddresses = new address[](2);
        priceFeedAddresses[0] = wethPriceFeed;
        priceFeedAddresses[1] = wbtcPriceFeed;
        mlscEngine = new MLSCEngine(tokenAddresses, priceFeedAddresses, address(mlsc));
        mlsc.transferOwnership(address(mlscEngine));
        vm.stopBroadcast();
        return (mlsc, mlscEngine, helperConfig);
    }
}
