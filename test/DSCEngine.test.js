const {expect, assert} = require("chai")
const {ethers, network, getNamedAccounts, deployments} = require("hardhat")
const {developmentChains} = require("../helper-hardhat.config");
const { utils } = require("ethers");

!developmentChains.includes(network.name)
    ? describe.skip()
    : describe("Tests for Decentralized Stable Coin", function(){
        let dscEngine;
        let dscEngineUser;
        let deployer
        let user

        let dsc
        let dscUser

        let wethAddress
        let wethAmount = utils.parseEther("20")
        
        let dscAmount = utils.parseEther("10000");

        let priceFeedAggregator;

        beforeEach(async function(){
            deployer = (await getNamedAccounts()).deployer
            user = (await getNamedAccounts()).user
            
            await deployments.fixture(["all"])
            
            dscEngine = await ethers.getContract("DSCEngine", deployer)
            dscEngineUser = await ethers.getContract("DSCEngine", user)
            
            dsc = await ethers.getContract("DecentralizedStableCoin", deployer)
            dscUser = await ethers.getContract("DecentralizedStableCoin", user)
            
            // Initializing Weth
            wethAddress = await dscEngine.s_collateralTokens(0)
            
            // Minting and Approving weth from ERC20 Mock for DSCEngine
            const wethContractUser = await ethers.getContractAt("ERC20Mock", wethAddress, user)
            await wethContractUser.mint(user, wethAmount)
            await wethContractUser.approve(dscEngine.address, wethAmount)

            priceFeedAggregator = await ethers.getContractAt("MockV3Aggregator", "0x5fbdb2315678afecb367f032d93f642f64180aa3", user);
            await priceFeedAggregator.updateAnswer(utils.parseUnits("1000", 8));
        })
        
        
        //////////////////////////////
        //// USD Price Tests  ///////
        ////////////////////////////
        
        it("Get correct USD Value", async function(){
            const expectedAmount = utils.parseEther("20000").toString() // As initial answer/price 1000
            
            const actualUsd = await dscEngine.getUsdValue(wethAddress, wethAmount)
            
            expect(actualUsd).to.equal(expectedAmount)
        })

        /////////////////////////////////////////////////
        //// Deposit Collateral And Mint DSC Tests    ///////
        ////////////////////////////////////////////////

        it("Reverts if collateral is Zero", async function(){
            await expect(dscEngineUser.depositCollateralAndMintDsc(wethAddress, "0", dscAmount)).to.be.revertedWith("DSCEngine__NeedsMoreThanZero()")
        })

        it("Reverts if DSC to be minted is Zero", async function(){
            await expect(dscEngineUser.depositCollateralAndMintDsc(wethAddress, wethAmount, "0")).to.be.revertedWith("DSCEngine__NeedsMoreThanZero()")
        })

        it("Should deposit collateral And Mint DSC", async function(){
            const validDscAmount = utils.parseEther("10000")
            await expect(dscEngineUser.depositCollateralAndMintDsc(wethAddress, wethAmount, validDscAmount)).to.emit(dscEngineUser, "MintedDsc").withArgs(user, validDscAmount)

            expect(await dscUser.balanceOf(user)).to.equal(validDscAmount);
        })

        it("should revert for being under-collateralized", async function(){
            const invalidDscAmount = utils.parseEther("10001") // As only 10,000 DSC can be minted for 20,000 worth of ETH
            await expect(dscEngineUser.depositCollateralAndMintDsc(wethAddress, wethAmount, invalidDscAmount)).to.be.revertedWith("DSCEngine__BreaksHealthFactor")
        })

        it("health factor should be accurate", async function(){
            const validDscAmount = utils.parseEther("1901") // As only 10,000 DSC can be minted for 20,000 worth of ETH
            const expectedHealthFactor = "526038"
            expect(await dscEngineUser.depositCollateralAndMintDsc(wethAddress, wethAmount, validDscAmount))

            expect((await dscEngineUser.getHealthFactor(user)).toString()).to.equal(expectedHealthFactor)
        })

        it("Health Factor Edge Case", async function(){
            const expectedHealthFactor = "1000000000"
            expect(await dscEngineUser.depositCollateral(wethAddress, wethAmount))

            expect((await dscEngineUser.getHealthFactor(user)).toString()).to.equal(expectedHealthFactor)
        })


        /////////////////////////////////////////////////
        //// Burn DSC And Redeem Collateral    //////////
        ////////////////////////////////////////////////


        describe("tests for redeeming Collateral", function (){

            beforeEach(async function(){
                // Depositing Collateral
                await dscEngineUser.depositCollateralAndMintDsc(wethAddress, wethAmount, dscAmount);

                // Approving dscEngine when redeeming
                await dscUser.approve(dscEngine.address, dscAmount)
            })

            it("should return the all the collateral", async ()=>{
                await expect(dscEngineUser.redeemCollateralForDsc(wethAddress, wethAmount, dscAmount)).to.emit(dscEngine, "CollateralRedeemed");
            })

            it("should not get Collateral that is in use", async()=>{
                await expect(dscEngineUser.redeemCollateralForDsc(wethAddress, wethAmount, utils.parseEther("2"))).to.be.revertedWith("DSCEngine__BreaksHealthFactor")
            })

            it("Should get Collateral that is not in use", async()=>{
                await expect( dscEngineUser.redeemCollateral(wethAddress, utils.parseEther("19.99"))).to.emit(dscEngine, "CollateralRedeemed");
            })

            
            ////////////////////////////////
            //// Liquidation Tests    /////
            ///////////////////////////////

            describe("Tests of liquidation", function(){
                const randomDscAmount = utils.parseEther("5000")
                
                beforeEach(async function(){
                    
                    // Making the liquidator Account Ready (Deployer is the liquidator here)
                    const wethContract = await ethers.getContractAt("ERC20Mock", wethAddress, deployer)
                    await wethContract.mint(deployer, wethAmount)
                    await wethContract.approve(dscEngine.address, wethAmount)
                    
                    const validDscAmount = utils.parseEther("10000")
                    
                    await dscEngine.depositCollateralAndMintDsc(wethAddress, wethAmount, randomDscAmount)
                    await dsc.approve(dscEngine.address, randomDscAmount)

                    // ETH colleateral Price has dropped by 50%
                    await priceFeedAggregator.updateAnswer(utils.parseUnits("900", 8));
                })
                
                it("The USD price of ETH(collateral) should be updated", async ()=>{
                    const expectedPrice = "18000.0"
                    const actualUsd = utils.formatEther(await dscEngineUser.getUsdValue(wethAddress, wethAmount))
                    expect(actualUsd).to.equal(expectedPrice)
                })

                it("Health factor of the user must be 0.9", async()=>{
                    const healthFactor = (await dscEngineUser.getHealthFactor(user)).toString()
                    expect(healthFactor).to.equal("90000")
                })

                it("should revert liquidation if users health factor is ok", async()=>{
                    const amountDscToBurn = utils.parseEther("1000")  // 0.9 of minted as health factor is 0.9
                    await dscEngineUser.burnDsc(amountDscToBurn)

                    // Now the health factor restores to 1 and Liquidation should be reverted
                    await expect(dscEngine.liquidate(wethAddress, user, randomDscAmount)).to.be.revertedWith("DSCEngine__HealthFactorOk")
                })

                it("Get the total collateral with the bonus collateral", async()=>{
                    // 

                    expect(await dscEngine.liquidate(wethAddress, user, randomDscAmount)).to.emit("DSCEngine", "CollateralRedeemed")
                })
            })

        })

        
    })

