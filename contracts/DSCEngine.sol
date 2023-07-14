// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "./DecentralizedStableCoin.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "hardhat/console.sol";

/**
 * @title DecentralizedStableCoin
 * @author Bhimgouda Patil
 * 
 * 
 * The system is designed to be as minimal as possible and have the tokens maintain
 * a 1 token == $1 peg.
 * 
 * This stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algorithmically stable
 * 
 * It is similar to DAI but without any governance, no fees, and was only backed by wETH and wBTC.
 * 
 * @notice Our DSC system should always be "overcollateralized". At no point should the value of
 * all collateral be less than or equal to the $ backed value of all the DSC.
 * 
 * @notice This contract is the core of the DSC System. It handles all the logic for 
 * minting and redeeming DSC, as well as depositing & withdrawing collateral.
 * 
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    //////////////////////////////
    //// Errors           ///////
    ////////////////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 _healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    //////////////////////////////
    //// State Variables  ///////
    ////////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 50% of deposited Collateral 
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant HEALTH_FACTOR_PRECISION = 1e5;
    uint256 private constant MIN_HEALTH_FACTOR = 1e5;  
    uint256 private constant LIQUIDATION_BONUS = 10;

    mapping(address => address) private s_priceFeeds;
    address[] public s_collateralTokens;

    mapping(address => mapping(address => uint256)) private s_collateralDeposited;         // 1e18

    mapping(address => uint256) private s_DSCMinted;              // 1e18

    DecentralizedStableCoin private immutable i_dsc;

    //////////////////////////////
    //// Events         /////////
    ////////////////////////////
    event CollateralDeposited(address indexed user, address indexed tokenCollateralAddress, uint256 indexed amountCollateral);
    event MintedDsc(address indexed user, uint256 dscMinted);

    event CollateralRedeemed(address indexed from, address to, address indexed token, uint256 indexed amount);

    //////////////////////////////
    //// Modifiers        ///////
    ////////////////////////////

    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    //////////////////////////////
    //// Functions        ///////
    ////////////////////////////

    //////////////////////////////
    //// External Functions  ///////
    ////////////////////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /**
     * 
     * @param tokenCollateralAddress  Address of token that is being deposited as Collateral
     * @param amountCollateral The amount of collateral token
     * @param amountDscToMint The amount of decentralized stablecoin to mint
     */
    function depositCollateralAndMintDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToMint) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @notice follows CEI pattern
     * @param tokenCollateralAddress Address of token that is being deposited as Collateral
     * @param amountCollateral The amount of collateral token
     * 
    */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral) public moreThanZero(amountCollateral) isAllowedToken(tokenCollateralAddress) nonReentrant {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;

        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) revert DSCEngine__TransferFailed();

        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
    }

    /**
     * @notice follows CEI
     * @param amountDscToMint - 1e18 The amount of decentralized stablecoin to mint 
     * @notice they must have collateral value than the minimum threshold
     * 
     * 
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) revert DSCEngine__MintFailed();

        emit MintedDsc(msg.sender, amountDscToMint);
    }

    /**
     * 
     * @param tokenCollateralAddress The collateral Token Address to redeem
     * @param amountCollateral The amount of collateral token to redeem
     * @param amountDscToBurn The amount of DSC token to burn
     * This function burns DSC and redeems underlying collateral in one transaction
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // Redeem collateral already checks if health factor is not broken
    }

    // in order to redeem collateral:
    // 1. Health factor must be over 1 After collateral pulled
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDSC(msg.sender, msg.sender, amount);
    }

    /**
     * 
     * @param collateral The ERC20 collateral address to liquidate from the user 
     * @param user The user who has broken the health factor. Their healthfactor should be below MIN_HEALTH_FACTOR
     * @param debtToCover (1e18) The amount of DSC you want to burn to improve the user's health factor
     * @notice You can partially liquidate a user
     * @notice You will get a liquidation Bonus for restoring their health factor
     * @notice This function assumes the protocol will be roughly 200% 
        overcollateralized in order for this to work
       @notice A known bug would be if the protocol were 100% or less collateralized then we 
       wouldn't be able to incentivize the liquidators.
       For Example, if the price of the collateral plummeted before anyone could be liquidated

     * Follows CEI: Checks, effects, Interaction
     */ 
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
        isAllowedToken(collateral)
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }

        uint256 collateralAmountFromDebt = getCollateralTokenFromUsd(collateral, debtToCover);
        uint256 collateralBonusAmount = (collateralAmountFromDebt * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION; // amount * 10/100
        uint256 totalCollateralRedeem = collateralAmountFromDebt + collateralBonusAmount;
        _redeemCollateral(collateral, totalCollateralRedeem, user, msg.sender);
        _burnDSC(msg.sender, user, debtToCover);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            // No improvement in health factor
            revert DSCEngine__HealthFactorNotImproved(); 
        }

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * 
     * @param user Address of the user for whom you want to check the health factor
     */
    function getHealthFactor(address user) external view returns(uint256) {
        return _healthFactor(user);
    }

    /////////////////////////////////////////
    //// Public & External View Functions  ///////
    ////////////////////////////////////////

    function getCollateralTokenFromUsd(address collateral, uint256 usdValue) internal view returns(uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[collateral]);
        (, int price, , ,) = priceFeed.latestRoundData();
        uint256 precisePrice = uint256(price) * ADDITIONAL_FEED_PRECISION;
        return usdValue * PRECISION / precisePrice;
    }
 
    function getAccountCollateralValue(address user) public view returns(uint256 tokenCollateralValueInUsd) {
        // Loop through each collateral token, get the amount they have deposited, and map it to
        // the price, to get USD value

        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address collateralToken = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][collateralToken];
            tokenCollateralValueInUsd += getUsdValue(collateralToken, amount);
        }
    }

    function getUsdValue(address token, uint256 amount) public view returns(uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int price, , ,) = priceFeed.latestRoundData();
        return (uint256(price) * ADDITIONAL_FEED_PRECISION * amount) / PRECISION;
    }

    ////////////////////////////////////////////
    //// Internal & Private View Functions  ///////
    //////////////////////////////////////////

    function _getAccountInformation(address user) private view returns(uint256 totalDscMinted, uint256 collateralValueInUsd) {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to) private {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _burnDSC(address from, address onBehalfOf, uint256 amount) private {
        s_DSCMinted[onBehalfOf] -= amount;
        bool success = i_dsc.transferFrom(from, address(this), amount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amount);
    }

    /**
     * Returns how close to liquidation a user is
     * If a user goes below 1, then they can get liquidated
     */
    function _healthFactor(address user) private view returns(uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        if (totalDscMinted == 0 && collateralValueInUsd == 0) return MIN_HEALTH_FACTOR; // Edge Case 1

        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        if (totalDscMinted == 0) return collateralAdjustedForThreshold * HEALTH_FACTOR_PRECISION / PRECISION; // Edge Case 2
 
        return (collateralAdjustedForThreshold * HEALTH_FACTOR_PRECISION) / totalDscMinted;   
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }
}
