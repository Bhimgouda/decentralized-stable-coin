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
    } else{
        // Changes on production
    }

    
    const DecentralizedStableCoin = await deploy("DecentralizedStableCoin", {
        from: deployer,
        args: [],
        log: true,
        waitConfirmations: network.config.blockConfirmations || 1
    });
    
    const dscEngineArgs = [priceFeedAddresses, collateralTokenAddresses, DecentralizedStableCoin.address]

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
