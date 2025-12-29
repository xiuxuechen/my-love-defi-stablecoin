// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {DeployMLSC} from "../../script/DeployMLSC.s.sol";
import {MyLoveStableCoin} from "../../src/MyLoveStableCoin.sol";
import {MLSCEngine} from "../../src/MLSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {
    IERC20Errors
} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract MLSCEngineTest is Test {
    DeployMLSC public deployer;
    MyLoveStableCoin public mlsc;
    MLSCEngine public engine;
    HelperConfig public config;

    address public wethUsdPriceFeed;
    address public wbtcUsdPriceFeed;
    address public weth;
    address public wbtc;
    uint256 public deployerKey;

    address public user = address(1);

    uint256 public constant STARTING_USER_BALANCE = 10 ether;

    function setUp() public {
        deployer = new DeployMLSC();
        (mlsc, engine, config) = deployer.run();
        (wethUsdPriceFeed, wbtcUsdPriceFeed, weth, wbtc, deployerKey) = config
            .activeNetworkConfig();
        if (block.chainid == vm.envUint("LOCAL_CHAIN_ID")) {
            vm.deal(user, STARTING_USER_BALANCE);
        }
        ERC20Mock(weth).mint(user, STARTING_USER_BALANCE);
        ERC20Mock(wbtc).mint(user, STARTING_USER_BALANCE);
    }

    /**
     * @dev 测试构造函数
     */
    function testConstructor() public {
        assertEq(engine.getCollateralTokenPriceFeed(weth), wethUsdPriceFeed);
        assertEq(engine.getCollateralTokenPriceFeed(wbtc), wbtcUsdPriceFeed);
    }

    /**
     * @dev 测试获取抵押物价值(USD)是否正确
     */
    function testCollateralPrice() public {
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30000e18;
        uint256 usdAmount = engine.getCollateralUsdPrice(weth, ethAmount);
        assertEq(usdAmount, expectedUsd);
    }

    /**
     * @dev 测试存入0抵押物正常回滚
     */
    function testDepositCollateralZero() public {
        vm.startPrank(user);
        vm.expectRevert(MLSCEngine.MLSCEngine__NeedsMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    /**
     * @dev 测试用户未授权正常回滚
     */
    function testDepositCollateralDontHaveApproval() public {
        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector,
                address(engine),
                0,
                10 ether
            )
        );
        engine.depositCollateral(weth, 10 ether);
        vm.stopPrank();
    }

    /**
     * @dev 测试存入抵押物emit正常
     */
    function testDepositCollateralEmit() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), 10 ether);
        vm.expectEmit(true, true, true, false, address(engine));
        emit MLSCEngine.CollateralDeposited(user, weth, 10 ether);
        engine.depositCollateral(weth, 10 ether);
        vm.stopPrank();
    }

    /**
     * @dev 测试存入抵押物正常
     */
    function testDepositCollateralSuccess() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), 10 ether);
        engine.depositCollateral(weth, 10 ether);
        uint256 depositedAmount = engine.getCollateralDeposited(user, weth);
        vm.stopPrank();
        assertEq(depositedAmount, 10 ether);
    }

    function testDepositCollateralAndMintDsc() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), 10 ether);
        engine.depositCollateralAndMintDsc(weth, 10 ether, 10);
        uint256 mintMlscCoinNum = engine.getMLSCMinted(user);
        vm.stopPrank();
        assertEq(mintMlscCoinNum, 10);
    }
}
