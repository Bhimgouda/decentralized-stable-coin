const {network, ethers} = require("hardhat");
const {developmentChains, networkConfig} = require("../helper-hardhat.config")
const {verify} = require("../utils/verify")
const deployMocks = require("../scripts/deploy-mocks")

// hre = hardhat runtime environment gives all this arguments to deploy scripts

module.exports = async ({getNamedAccounts, deployments}) => {
    const {deploy, log, get} = deployments
    const {deployer} = await getNamedAccounts()
    const {name: networkName} = network;

    let priceFeedAddresses;
    let collateralTokenAddresses;
    if(developmentChains.includes(networkName)){
        const {MockV3AggregatorBtc, MockV3AggregatorEth, mockWETH, mockWBTC} = await deployMocks({getNamedAccounts, deployments})

        priceFeedAddresses = [MockV3AggregatorEth, MockV3AggregatorBtc]
        collateralTokenAddresses = [mockWETH, mockWBTC]
    } else if(networkName === "sepolia"){
        const wethAddress = "0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9"
        const wbtcAddress = ""

        collateralTokenAddresses = [wbtcAddress, wbtcAddress]

        const ethUsdPriceFeedAddress = "0x694AA1769357215DE4FAC081bf1f309aDC325306"
        const btcUsdPriceFeedAddress = "0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43"
        priceFeedAddresses = [ethUsdPriceFeedAddress, btcUsdPriceFeedAddress]
    }
    
    const DecentralizedStableCoin = await deploy("DecentralizedStableCoin", {
        from: deployer,
        args: [],
        log: true,
        waitConfirmations: network.config.blockConfirmations || 1
    });
    
    const dscEngineArgs = [collateralTokenAddresses, priceFeedAddresses, DecentralizedStableCoin.address]

    const DSCEngine = await deploy("DSCEngine", {
        from: deployer,
        args: dscEngineArgs,
        log: true,
        waitConfirmations: network.config.blockConfirmations || 1
    })

    const dsc = await ethers.getContract("DecentralizedStableCoin", deployer)
    const tx = await dsc.transferOwnership(DSCEngine.address)
    await tx.wait(1)

}

module.exports.tags = ["all", "main", "dsc"]
