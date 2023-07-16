// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {ERC20Mock} from "test/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;

    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;

    address USER = makeAddr("user");
    address LIQUIDATE_CALLER = makeAddr("liquidator user");

    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 1e10 ether;
    uint256 constant AMMOUNT_MINTED_DSC = 1e18 * 10000; // 5e18
    uint256 constant UNDERCOLLATERALIZED_ETH_PRICE = 1200e8; //default is 2000 $ = 2000e8    300.000000000000000030
    uint256 amountToMint = 100 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth,,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE * 2000);
    }

    ////////////////////////////
    //      Contructor        //
    ////////////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }
    ////////////////////////////
    //      Price Feed        //
    ////////////////////////////

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);

        assertEq(expectedUsd, actualUsd);
    }

    function testsRevertsIfCollateralZero() public {
        uint256 usdAmount = 100 ether;

        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    ////////////////////////////
    //  Deposit collateral    //
    ////////////////////////////

    function testRevertIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedTokenValue = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);

        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedTokenValue);
    }

    ////////////////////////////
    //       Mint Dsc         //
    ////////////////////////////

    function testCanMintDsc() public depositedCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(amountToMint);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, amountToMint);
    }

    function testIfMintDscRevertsIfHealthFactorIsBroken() public depositedCollateral {
        vm.startPrank(USER);

        //user deposited 10 eth
        //user mints 9.99 eth
        //health is 10000.00000000000000500

        amountToMint = dsce.getAccountCollateralValue(USER);
        vm.expectRevert(DSCEngine.DSCEngine__BreaksHealthFactor.selector);

        dsce.mintDsc(amountToMint); //in usd

        vm.stopPrank();
    }

    function testcanDepositCollateralAndMintDsc() public {
        vm.startPrank(USER);

        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_COLLATERAL / 3);
        vm.stopPrank();

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);

        assertEq(totalDscMinted, AMOUNT_COLLATERAL / 3);
        assertEq(dsce.getTokenAmountFromUsd(weth, collateralValueInUsd), AMOUNT_COLLATERAL);
    }
    ////////////////////////////
    //       Liquidate        //
    ////////////////////////////

    modifier depositedCollateralAndMintedDsc(address user) {
        vm.startPrank(user);

        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        // 1 eth * 200% > 2000$
        // 20 eth / 2000 = 40 000 / 2000 = 20 ---> collateral
        // 10 ----> mintedDsc
        dsce.depositCollateralAndMintDsc(weth, (AMOUNT_COLLATERAL * 2) / 2000, AMOUNT_COLLATERAL - 1); //collateral is in eth

        vm.stopPrank();
        _;
    }

    function testIfInsolventCanBeLiquidated() public depositedCollateralAndMintedDsc(USER) {
        //become undercollateralized (reduce collateral value)
        (bool success,) =
            ethUsdPriceFeed.call(abi.encodeWithSignature("updateAnswer(int256)", UNDERCOLLATERALIZED_ETH_PRICE));
        assert(success);

        //create second user
        ERC20Mock(weth).mint(LIQUIDATE_CALLER, STARTING_ERC20_BALANCE);

        vm.startPrank(LIQUIDATE_CALLER);

        dsc.approve(address(dsce), AMOUNT_COLLATERAL); //let engine get dsc
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL * 1e5); //let engine get collateral
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL * 1e5);

        dsce.mintDsc(AMOUNT_COLLATERAL * 1e2);

        //Liquidate
        console.log("dsc liq", dsce.getDscValue(LIQUIDATE_CALLER));
        console.log("collateral liq", dsce.getAccountCollateralValue(LIQUIDATE_CALLER));
        console.log("health liq", dsce.getHealthFactor(LIQUIDATE_CALLER));

        dsce.liquidate(weth, USER, AMOUNT_COLLATERAL - 1); // not running because USER doesnt have enough collateral

        vm.stopPrank();

        //check if became liquidated
    }
}
