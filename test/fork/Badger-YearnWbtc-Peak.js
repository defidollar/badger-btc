const _ = require('lodash');
const { expect } = require("chai");
const { BigNumber } = ethers

const deployer = require('../deployer')
const { impersonateAccount } = require('../utils')

let mintAndRedeemFee = BigNumber.from(10)
const PRECISION = BigNumber.from(10000)
const ZERO = BigNumber.from(0)
const _1e18 = ethers.constants.WeiPerEther

const yvWBTCHolder = '0x5b908e3a23823fd9da157726736bacbff472976a'

describe('BadgerSettPeak + YearnWbtc (mainnet-fork)', function() {
    before('setup contracts', async function() {
        signers = await ethers.getSigners()
        alice = signers[0].address
        feeSink = '0x5b5cF8620292249669e1DCC73B753d01543D6Ac7' // DeFiDollar DAO Governance Multisig
        ;({ badgerPeak, core, bBTC } = await deployer.setupMainnetContracts(feeSink, 12174154))
        yvWBTC = await ethers.getContractAt('IyvWBTC', '0x1Ae8Ccd120A05080d9A01C3B4F627F865685D091')
    })

    it('deploy YearnWbtc Peak', async function() {
        const [ UpgradableProxy, YearnWbtcPeak ] = await Promise.all([
            ethers.getContractFactory('UpgradableProxy'),
            ethers.getContractFactory('YearnWbtcPeak')
        ])
        wbtcPeak = await UpgradableProxy.deploy()
        await wbtcPeak.updateImplementation(
            (await YearnWbtcPeak.deploy(core.address, yvWBTC.address)).address
        )
        wbtcPeak = await ethers.getContractAt('YearnWbtcPeak', wbtcPeak.address)
    })

    it('whitelist wbtc peak', async function() {
        expect(await core.peaks(wbtcPeak.address)).to.eq(0) // Extinct

        await core.whitelistPeak(wbtcPeak.address)

        expect(await core.peakAddresses(1)).to.eq(wbtcPeak.address)
        expect(await core.peaks(wbtcPeak.address)).to.eq(1) // Active
    })

    it('badgerPeak.modifyWhitelistedCurvePools', async function() {
        const pools = Object.keys(deployer.crvPools).map(k => _.pick(deployer.crvPools[k], ['swap', 'sett']))
        await badgerPeak.modifyWhitelistedCurvePools(pools)
        expect((await badgerPeak.numPools()).toString()).to.eq('3')
        for (let i = 0; i < 3; i++) {
            const pool = await badgerPeak.pools(i)
            expect(pool.swap).to.eq(pools[i].swap)
            expect(pool.sett).to.eq(pools[i].sett)
        }
    })

    it('setConfig', async function() {
        await core.setConfig(0, 0, feeSink)
        expect(await core.mintFee()).to.eq(ZERO)
        expect(await core.redeemFee()).to.eq(ZERO)
        expect(await core.feeSink()).to.eq(feeSink)
        mintAndRedeemFee = ZERO
    })

    it('mint with yvWBTC', async function() {
        let amount = BigNumber.from(5).mul(1e7) // 0.5 yvWBTC
        await impersonateAccount(yvWBTCHolder)
        await yvWBTC.connect(ethers.provider.getSigner(yvWBTCHolder)).transfer(alice, amount)

        // yvWBTC.pricePerShare() = 1e8, so exact same bBTC will be minted
        let mintedBbtc = _1e18.mul(5).div(10)
        const fee = mintedBbtc.mul(mintAndRedeemFee).div(PRECISION)
        const expectedBbtc = mintedBbtc.sub(fee)

        const calcMint = await wbtcPeak.calcMint(amount)
        expect(calcMint.bBTC).to.eq(expectedBbtc)

        await yvWBTC.approve(wbtcPeak.address, amount)
        await wbtcPeak.mint(amount)

        expect(await wbtcPeak.portfolioValue()).to.eq(mintedBbtc)
        await yvWbtcAssertions(
            wbtcPeak,
            [
                ZERO,
                expectedBbtc,
                amount,
                fee
            ]
        )
    })

    it('mint with bcrvRenWSBTC', async function() {
        let amount = _1e18.mul(10)
        await deployer.mintCrvPoolToken('sbtc', alice, amount)
        const contracts = await deployer.getPoolContracts('sbtc')
        const [ lp, _, sett ] = contracts
        await lp.approve(sett.address, amount)
        await sett.deposit(amount)
        await testMint(0, await sett.balanceOf(alice), [badgerPeak].concat(contracts))
    });

    it('mint with bcrvRenWBTC', async function() {
        const amount = _1e18.mul(10)
        await deployer.mintCrvPoolToken('ren', alice, amount)
        const [ lp, swap, sett ] = await deployer.getPoolContracts('ren')
        renWbtcSwap = swap
        await lp.approve(sett.address, amount)
        await sett.deposit(amount)
        await testMint(1, await sett.balanceOf(alice), [ badgerPeak, lp, swap, sett ])
    });

    it('mint with b-tbtc/sbtcCrv', async function() {
        const amount = _1e18.mul(10)
        await deployer.mintCrvPoolToken('tbtc', alice, amount)
        const contracts = await deployer.getPoolContracts('tbtc')
        const [ lp, _, sett ] = contracts
        await lp.approve(sett.address, amount)
        await sett.deposit(amount)
        await testMint(2, await sett.balanceOf(alice), [badgerPeak].concat(contracts))
    });

    it('getPricePerFullShare should increase after a trade', async function() {
        let amount = BigNumber.from(15).mul(1e8) // wbtc has 8 decimals
        const wbtc = await deployer.getWbtc(alice, amount)

        let ppfs = await core.getPricePerFullShare()
        for (let i = 0; i < 10; i++) {
            await tradeWbtcxRen(wbtc)
            // trades will increase the virtual price; so ppfs should increase
            const _ppfs = await core.getPricePerFullShare()
            expect(_ppfs.gt(ppfs)).to.be.true
            ppfs = _ppfs
        }
    })

    async function tradeWbtcxRen(wbtc) {
        let amount = await wbtc.balanceOf(alice)
        await wbtc.approve(renWbtcSwap.address, amount)
        await renWbtcSwap.exchange(1 /* wbtc */, 0 /* ren */, amount, 0)

        const ren = await ethers.getContractAt('IERC20', '0xeb4c2781e4eba804ce9a9803c67d0893436bb27d')
        amount = await ren.balanceOf(alice)
        await ren.approve(renWbtcSwap.address, amount)
        await renWbtcSwap.exchange(0, 1, amount, 0)
    }

    it('redeem in bcrvRenWSBTC', async function() {
        await testRedeem(0, 'sbtc')
    });

    it('redeem in bcrvRenWBTC', async function() {
        await testRedeem(1, 'ren')
    });

    it('redeem in b-tbtc/sbtcCrv', async function() {
        await testRedeem(2, 'tbtc')
    });

    it('redeem in yvWBTC', async function() {
        // aliceBbtc = 499998553138746239
        // core.bBtcToBtc(aliceBbtc) = 499999999999999999909214769325897064
        // redeem-able yvWBTC = 49999999
        const aliceBbtc = await bBTC.balanceOf(alice)
        const calcRedeem = await wbtcPeak.calcRedeem(aliceBbtc)
        expect(calcRedeem.sett.toString()).to.eq('49999999') // 0.499

        // console.log({
        //     aliceBbtc: aliceBbtc.toString(),
        //     bBtcToBtc: (await core.bBtcToBtc(aliceBbtc)).btc.toString(),
        //     sett: calcRedeem.sett.toString(),
        //     fee: calcRedeem.fee.toString(),
        //     max: calcRedeem.max.toString(),
        // })

        await wbtcPeak.redeem(await bBTC.balanceOf(alice))

        // 5e7 - 49999999 = 1 yvWBTC = 1e10 in portfolio value
        expect(await wbtcPeak.portfolioValue()).to.eq(BigNumber.from(1e10))
        expect(await core.totalSystemAssets()).to.eq(BigNumber.from(1e10))
        await yvWbtcAssertions(
            wbtcPeak,
            [
                calcRedeem.sett,
                ZERO,
                BigNumber.from(1),
                ZERO
            ]
        )
    });

    it('sanity checks', async function() {
        expect(await bBTC.balanceOf(alice)).to.eq(ZERO)
        expect(await bBTC.totalSupply()).to.eq(ZERO)
        expect(await bBTC.getPricePerFullShare()).to.eq(_1e18)
        expect(await core.getPricePerFullShare()).to.eq(_1e18)
        expect(await core.accumulatedFee()).to.eq(ZERO)
    })

    async function testRedeem(poolId, pool) {
        const [ curveLPToken, swap, sett ] = await deployer.getPoolContracts(pool)
        const amount = (await sett.balanceOf(badgerPeak.address))
            .mul(await sett.getPricePerFullShare())
            .mul(await swap.get_virtual_price())
            .div(await core.getPricePerFullShare())
            .div(_1e18)
            .add(1) // round-off nuance
        const [
            virtualPrice,
            ppfs,
            aliceBbtcBal,
            aliceCrvBal,
            peakCrvLPBal,
            accumulatedFee,
            calcRedeem
        ] = await Promise.all([
            swap.get_virtual_price(),
            sett.getPricePerFullShare(),
            bBTC.balanceOf(alice),
            curveLPToken.balanceOf(alice),
            curveLPToken.balanceOf(badgerPeak.address),
            core.accumulatedFee(),
            badgerPeak.calcRedeem(poolId, amount)
        ])
        const fee = amount.mul(mintAndRedeemFee).div(PRECISION)
        const expected = amount.sub(fee)
            .mul(await core.getPricePerFullShare())
            .mul(_1e18)
            .div(ppfs)
            .div(virtualPrice)
        expect(calcRedeem.sett).to.eq(expected)

        await badgerPeak.redeem(poolId, amount)

        await assertions(
            badgerPeak,
            curveLPToken,
            [
                aliceCrvBal, // curveLPToken.balanceOf(alice)
                aliceBbtcBal.sub(amount), // bBTC.balanceOf(alice)
                peakCrvLPBal, // curveLPToken.balanceOf(badgerPeak.address)
                accumulatedFee.add(fee) // core.accumulatedFee()
            ]
        )
        await settAssertions(
            badgerPeak,
            sett,
            [
                expected, // sett.balanceOf(alice)
                ZERO, // sett.balanceOf(peak.address)
            ]
        )
    }

    async function testMint(poolId, amount, [ peak, curveLPToken, swap, sett ]) {
        const [
            ppfs,
            virtualPrice,
            aliceCrvBal,
            aliceBbtcBal,
            peakCrvLPBal,
            peakSettLPBal,
            totalSupply,
            accumulatedFee,
            calcMint
        ] = await Promise.all([
            sett.getPricePerFullShare(),
            swap.get_virtual_price(),
            curveLPToken.balanceOf(alice),
            bBTC.balanceOf(alice),
            curveLPToken.balanceOf(peak.address),
            sett.balanceOf(peak.address),
            bBTC.totalSupply(),
            core.accumulatedFee(),
            badgerPeak.calcMint(poolId, amount)
        ])
        let mintedBbtc = amount
            .mul(ppfs)
            .mul(virtualPrice)
            .div(_1e18.mul(_1e18))
        if (totalSupply.gt(ZERO)) {
            mintedBbtc = mintedBbtc
                .mul((await bBTC.totalSupply()).add(accumulatedFee))
                .div(await core.totalSystemAssets())
        }
        const fee = mintedBbtc.mul(mintAndRedeemFee).div(PRECISION)
        const expectedBbtc = mintedBbtc.sub(fee)
        expect(calcMint.bBTC).to.eq(expectedBbtc)

        await sett.approve(peak.address, amount)
        await peak.mint(poolId, amount)

        await assertions(
            peak,
            curveLPToken,
            [
                aliceCrvBal, // curveLPToken.balanceOf(alice)
                aliceBbtcBal.add(expectedBbtc), // bBTC.balanceOf(alice)
                peakCrvLPBal, // curveLPToken.balanceOf(peak.address)
                accumulatedFee.add(fee) // core.accumulatedFee()
            ]
        )
        await settAssertions(
            peak,
            sett,
            [
                ZERO, // sett.balanceOf(alice)
                peakSettLPBal.add(amount), // sett.balanceOf(peak.address)
            ]
        )
        return expectedBbtc
    }

    async function assertions(peak, curveLPToken, [ aliceCrvLP, alicebtc, peakCrvLP, accumulatedFee ]) {
        const vals = await Promise.all([
            curveLPToken.balanceOf(alice),
            bBTC.balanceOf(alice),
            curveLPToken.balanceOf(peak.address),
            core.accumulatedFee()
        ])
        expect(aliceCrvLP).to.eq(vals[0])
        expect(alicebtc).to.eq(vals[1])
        expect(peakCrvLP).to.eq(vals[2])
        expect(accumulatedFee).to.eq(vals[3])
    }

    async function settAssertions(peak, sett, [ aliceSettLP, peakSettLP ]) {
        expect(aliceSettLP).to.eq(await sett.balanceOf(alice))
        expect(peakSettLP).to.eq(await sett.balanceOf(peak.address))
    }

    async function yvWbtcAssertions(peak, [ aliceYVwbtc, alicebtc, peakYVwbtc, accumulatedFee ]) {
        const vals = await Promise.all([
            yvWBTC.balanceOf(alice),
            bBTC.balanceOf(alice),
            yvWBTC.balanceOf(peak.address),
            core.accumulatedFee()
        ])
        expect(aliceYVwbtc).to.eq(vals[0])
        expect(alicebtc).to.eq(vals[1])
        expect(peakYVwbtc).to.eq(vals[2])
        expect(accumulatedFee).to.eq(vals[3])
    }
});