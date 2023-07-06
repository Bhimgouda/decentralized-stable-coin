const {expect, assert} = require("chai")
const {ethers, network, getNamedAccounts, deployments} = require("hardhat")
const {developmentChains} = require("../helper-hardhat.config");
const { utils } = require("ethers");

!developmentChains.includes(network.name)
    ? describe.skip()
    : describe("Tests for Pool", function(){
        let dscEngine;
        let dscEngineUser;
        let deployer
        let user

        let wethAddress

        let wethAmount


        beforeEach(async function(){
            deployer = (await getNamedAccounts()).deployer
            user = (await getNamedAccounts()).user
            wethAmount = utils.parseEther("15").toString()
            
            await deployments.fixture(["all"])
            
            dscEngine = await ethers.getContract("DSCEngine", deployer)
            dscEngineUser = await ethers.getContract("DSCEngine", user)
            
            dsc = await ethers.getContract("DecentralizedStableCoin", deployer)

            wethAddress = await dscEngine.s_collateralTokens(0)
            
            // Minting and Approving weth from ERC20 Mock for DSCEngine
            const wethContractUser = await ethers.getContractAt("ERC20Mock", wethAddress, user)
            await wethContractUser.mint(user, wethAmount)
            await wethContractUser.approve(dscEngine.address, wethAmount)
        })
        
        
        //////////////////////////////
        //// USD Price Tests  ///////
        ////////////////////////////
        
        it("Get correct USD Value", async function(){
            const expectedAmount = utils.parseEther("15000").toString() // As initial answer/price 1000
            
            const actualUsd = await dscEngine.getUsdValue(wethAddress, wethAmount)
            
            expect(actualUsd).to.equal(expectedAmount)
        })

        /////////////////////////////////////////
        //// Deposit Collateral Tests    ///////
        ////////////////////////////////////////

        it("Reverts if collateral is Zero", async function(){
            await expect(dscEngineUser.depositCollateral(wethAddress, "0")).to.be.revertedWith("DSCEngine__NeedsMoreThanZero()")
        })

        it("Should deposit collateral", async function(){
            const dscAmount = utils.parseEther("5")
            await expect(dscEngineUser.depositCollateralAndMintDsc(wethAddress, wethAmount, dscAmount)).to.emit(dscEngineUser, "MintedDsc").withArgs(user, dscAmount)
        })

    })

