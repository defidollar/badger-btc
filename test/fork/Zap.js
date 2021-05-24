const _ = require('lodash');
const { expect } = require("chai");
const { BigNumber } = ethers

const deployer = require('../deployer')
const {
    constants: { _1e8, _1e18, NULL },
    impersonateAccount
} = require('../utils');

const badgerMultiSig = '0xB65cef03b9B89f99517643226d76e286ee999e77'
const ibbtcMetaSig = '0xCF7346A5E41b0821b80D5B3fdc385EEB6Dc59F44'

describe('Zap (mainnet-fork)', function() {
    before('setup contracts', async function() {
        signers = await ethers.getSigners()
        alice = signers[0].address

        await network.provider.request({
            method: "hardhat_reset",
            params: [{
                forking: {
                    jsonRpcUrl: `https://eth-mainnet.alchemyapi.io/v2/${process.env.ALCHEMY}`,
                    blockNumber: 12495510
                }
            }]
        })

        const config = require('../../deployments/mainnet.json')
        ;([ badgerPeak, wbtcPeak, bBTC, core, Zap ] = await Promise.all([
            ethers.getContractAt('BadgerSettPeak', config.badgerPeak),
            ethers.getContractAt('BadgerYearnWbtcPeak', config.byvWbtcPeak),
            ethers.getContractAt('bBTC', config.bBtc),
            ethers.getContractAt('Core', config.core),
            ethers.getContractFactory('Zap')
        ]))
        zap = await Zap.deploy()
    })

    it('admin whitelists', async function() {
        await impersonateAccount(badgerMultiSig)
        for (let i = 0; i < 3; i++) {
            const pool = await badgerPeak.pools(i)
            const sett = await ethers.getContractAt('ISett', pool.sett)
            await sett.connect(ethers.provider.getSigner(badgerMultiSig)).approveContractAccess(zap.address)
        }

        await impersonateAccount(ibbtcMetaSig)
        await web3.eth.sendTransaction({ from: alice, to: ibbtcMetaSig, value: _1e18 })
        await badgerPeak.connect(ethers.provider.getSigner(ibbtcMetaSig)).approveContractAccess(zap.address)
        await wbtcPeak.connect(ethers.provider.getSigner(ibbtcMetaSig)).approveContractAccess(zap.address)
        await core.connect(ethers.provider.getSigner(ibbtcMetaSig)).setGuestList(NULL)
    })

    it('mint with renbtc', async function() {
        let amount = _1e8.mul(9)
        const ren = await deployer.getRenbtc(alice, amount)
        await ren.approve(zap.address, amount)

        amount = amount.div(3)

        const calcMint = await zap.calcMint(ren.address, amount)
        const calcMintWithRen = await zap.calcMintWithRen(amount)
        expect(calcMint).to.deep.eq(calcMintWithRen)
        // console.log(calcMint, calcMintWithRen)

        let prev = await bBTC.balanceOf(alice)
        await zap.mint(ren.address, amount, 0 /* crvRenWBTC */, 0 /* renbtc idx */, 0)
        let now = await bBTC.balanceOf(alice)
        let minted = parseFloat(now.sub(prev).toString()) / 1e18
        expect(minted > 2.9).to.be.true

        prev = now
        await zap.mint(ren.address, amount, 1 /* crvRenWSBTC */, 0 /* renbtc idx */, 0)
        now = await bBTC.balanceOf(alice)
        minted = parseFloat(now.sub(prev).toString()) / 1e18
        expect(minted > 2.9).to.be.true

        prev = now
        await zap.mint(ren.address, amount, 2 /* tbtc/sbtcCrv */, 1 /* renbtc idx */, 0)
        now = await bBTC.balanceOf(alice)
        minted = parseFloat(now.sub(prev).toString()) / 1e18
        expect(minted > 2.9).to.be.true

        const ibbtc = parseFloat(now.toString()) / 1e18
        expect(ibbtc > 8.9).to.be.true
    })

    it('mint with wbtc', async function() {
        let amount = _1e8.mul(12)
        const wbtc = await deployer.getWbtc(alice, amount)
        await wbtc.approve(zap.address, amount)

        amount = amount.div(4)

        const calcMint = await zap.calcMint(wbtc.address, amount)
        const calcMintWithWbtc = await zap.calcMintWithWbtc(amount)
        expect(calcMint).to.deep.eq(calcMintWithWbtc)
        // console.log(calcMint, calcMintWithWbtc)

        let prev = await bBTC.balanceOf(alice)
        await zap.mint(wbtc.address, amount, 0 /* crvRenWBTC */, 1 /* wbtc idx */, 0)
        let now = await bBTC.balanceOf(alice)
        let minted = parseFloat(now.sub(prev).toString()) / 1e18
        expect(minted > 2.9).to.be.true

        prev = now
        await zap.mint(wbtc.address, amount, 1 /* crvRenWSBTC */, 1 /* wbtc idx */, 0)
        now = await bBTC.balanceOf(alice)
        minted = parseFloat(now.sub(prev).toString()) / 1e18
        expect(minted > 2.9).to.be.true

        prev = now
        await zap.mint(wbtc.address, amount, 2 /* tbtc/sbtcCrv */, 2 /* wbtc idx */, 0)
        now = await bBTC.balanceOf(alice)
        minted = parseFloat(now.sub(prev).toString()) / 1e18
        expect(minted > 2.9).to.be.true

        prev = now
        await zap.mint(wbtc.address, amount, 3 /* tbtcbyvWbtc */, 0 /* wbtc idx (redundant) */, 0)
        now = await bBTC.balanceOf(alice)
        minted = parseFloat(now.sub(prev).toString()) / 1e18
        expect(minted > 2.9).to.be.true

        const ibbtc = parseFloat((await bBTC.balanceOf(alice)).toString()) / 1e18
        expect(ibbtc > 17.8).to.be.true
    })
})
