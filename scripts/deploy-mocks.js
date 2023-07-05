const {network, ethers} = require("hardhat");
const {developmentChains, networkConfig} = require("../helper-hardhat.config")
const {verify} = require("../utils/verify")

// hre = hardhat runtime environment gives all this arguments to deploy scripts

module.exports = async ({getNamedAccounts, deployments}) => {
    const {deploy, log, get} = deployments
    const {deployer} = await getNamedAccounts()
    const {name: networkName} = network;


    if(developmentChains.includes(networkName)){
        const MockV3AggregatorEth = await deploy("MockV3Aggregator", {
            from: deployer,
            args: [8, 1937e8],
            log: true,
            waitConfirmations: network.config.blockConfirmations || 1
        })
    
        const MockV3AggregatorBtc = await deploy("MockV3Aggregator", {
            from: deployer,
            args: [8, 31000e8],
            log: true,
            waitConfirmations: network.config.blockConfirmations || 1
        })
    
        const mockWETH = await deploy("ERC20Mock", {
            from: deployer,
            args: ["WrappedEther", "WETH", deployer, ethers.utils.parseEther("1000")],
            log: true,
            waitConfirmations: network.config.blockConfirmations || 1
        })
    
        const mockWBTC = await deploy("ERC20Mock", {
            from: deployer,
            args: ["WrappedBitcoin", "WBTC", deployer, ethers.utils.parseEther("1000")],
            log: true,
            waitConfirmations: network.config.blockConfirmations || 1
        })

        return {
            MockV3AggregatorBtc : MockV3AggregatorBtc.address,
            MockV3AggregatorEth : MockV3AggregatorEth.address,
            mockWETH : mockWETH.address,
            mockWBTC: mockWBTC.address 
        }
    }
}
