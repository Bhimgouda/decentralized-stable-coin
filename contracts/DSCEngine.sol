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
 * The system is designed to be as minimal as possible, and have the tokens maintain
 * a 1 token == $1 peg.
 * 
 * This stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algorithmically stable
 * 
 * It is smilar to DAI but without any Gonvernance, no fees, and was only backed by wETH and wBTC
 * 
 * @notice Our DSC system should always be "overcollateralized". At no point, should the value of
 * of all collateral <= the $ backed value of all the DSC.
 * 
 * @notice This contract is the core of the DSC System. It handles all the logic for 
 * minting and redeeming DSC, as well as depositing & withdrawing collateral
 * 
 * @notice This contract is VERY loosely based on MakerDAO DSS (DAI) system.
*/
contract DSCEngine is ReentrancyGuard{
    //////////////////////////////
    //// Errors           ///////
    ////////////////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 _healthFactor);
    error DSCEngine__MintFailed();

    //////////////////////////////
    //// State Variables  ///////
    ////////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 50% of deposited Collateral 
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;


    mapping(address collateralToken => address s_priceFeeds) private s_priceFeeds;
    address[] public s_collateralTokens;

    mapping(address user => mapping(address collateralToken => uint256 amount)) private s_collateralDeposited;         // in Wei - 18 Decimals

    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;

    DecentralizedStableCoin private immutable i_dsc;

    //////////////////////////////
    //// Events         /////////
    ////////////////////////////
    event CollateralDeposited(address indexed user, address indexed tokenCollateralAddress, uint256 indexed amountCollateral);
    event MintedDsc(address indexed user, uint256 dscMinted);

    event CollateralRedeemed(address indexed user, address indexed token, uint256 indexed amount);

    //////////////////////////////
    //// Modifiers        ///////
    ////////////////////////////

    modifier moreThanZero(uint256 amount){
        if(amount <= 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token){
        if(s_priceFeeds[token] == address(0)){
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
        if(tokenAddresses.length != priceFeedAddresses.length){
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        for (uint256 i = 0; i<tokenAddresses.length; i++){
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
        if(!success) revert DSCEngine__TransferFailed();

        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
    }

    /**
     * @notice follows CEI
     * @param amountDscToMint The amount of decentralized stablecoin to mint
     * @notice they must have collateral value than the minimum threshold
     * 
     * 
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if(!minted) revert DSCEngine__MintFailed();

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
     public moreThanZero(amountCollateral) nonReentrant 
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(msg.sender, amountCollateral);
        if(!success){
            revert DSCEngine__TransferFailed();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function burnDsc(uint256 amount) public moreThanZero(amount)  {
        s_DSCMinted[msg.sender] -= amount;
        bool success = i_dsc.transferFrom(msg.sender, address(this), amount);
        if(!success){
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amount);
    }

    function liquidate() external {}

    function getHealthFactor() external view{}

    /////////////////////////////////////////
    //// Public & External View Functions  ///////
    ////////////////////////////////////////

    function getAccountCollateralValue(address user) public view returns(uint256 tokenCollateralValueInUsd){
        // Loop through each collateral token, get the amount they have deposited, and map it to
        // the price, to get USD value

        for(uint256 i=0; i<s_collateralTokens.length; i++ ){
            address collateralToken = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][collateralToken];
            tokenCollateralValueInUsd += getUsdValue(collateralToken, amount);
        }
    }

    function getUsdValue(address token, uint256 amount) public view returns(uint256){
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int price, , ,) = priceFeed.latestRoundData();
        return ((uint256(price)*ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    ////////////////////////////////////////////
    //// Internal & Private View Functions  ///////
    //////////////////////////////////////////

    function _getAccountInformation(address user) private view returns(uint256 totalDscMinted, uint256 collateralValueInUsd){
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * Returns how close to liquidation a user is
     * If a user goes below 1, then they can get liquidated
     */
    function _healthFactor(address user) private view returns(uint256){
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold) / totalDscMinted;   // Doubt (According to me)
    }

    function _revertIfHealthFactorIsBroken(address user) internal view{
        uint256 userHealthFactor = _healthFactor(user);
        if(userHealthFactor < MIN_HEALTH_FACTOR){
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }
}
