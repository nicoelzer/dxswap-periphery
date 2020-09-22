import chai, { expect } from 'chai'
import { Contract, utils } from 'ethers'
import { BigNumber, bigNumberify } from 'ethers/utils'
import { solidity, MockProvider, createFixtureLoader, deployContract } from 'ethereum-waffle'

import { expandTo18Decimals, mineBlock, encodePrice } from './shared/utilities'
import { dxswapFixture } from './shared/fixtures'

import LiquidityRelay from '../build/contracts/LiquidityRelay.json'

chai.use(solidity)

const overrides = {
  gasLimit: 9999999999999
}

const defaultToken0Amount = expandTo18Decimals(5)
const defaultToken1Amount = expandTo18Decimals(10)
const executionBounty = 10000

describe('LiquidityRelay', () => {
  const provider = new MockProvider({
    hardfork: 'istanbul',
    mnemonic: 'horn horn horn horn horn horn horn horn horn horn horn horn',
    gasLimit: 9999999999999
  })
  const [wallet, wallet2] = provider.getWallets()
  const loadFixture = createFixtureLoader(provider, [wallet])

  let token0: Contract
  let token1: Contract
  let pair: Contract
  let weth: Contract
  let factory: Contract
  let router: Contract
  let avatar: Contract

  async function addLiquidity(amount0: BigNumber = defaultToken0Amount, amount1: BigNumber = defaultToken1Amount) {
    if (!amount0.isZero()) await token0.transfer(pair.address, amount0)
    if (!amount1.isZero()) await token1.transfer(pair.address, amount1)
    await pair.sync()
  }

  const defaultWindowSize = 3600 // 30 Minutes
  const defaultGranularity = 6 // Every 5 Minutes

  function observationIndexOf(
    timestamp: number,
    windowSize: number = defaultWindowSize,
    granularity: number = defaultGranularity
  ): number {
    const periodSize = Math.floor(windowSize / granularity)
    const epochPeriod = Math.floor(timestamp / periodSize)
    return epochPeriod % granularity
  }

  function deployOracle(windowSize: number, granularity: number) {
    return deployContract(wallet, LiquidityRelay, [avatar.address, factory.address, router.address, windowSize, granularity, executionBounty], overrides)
  }

  beforeEach('deploy fixture', async function() {
    const fixture = await loadFixture(dxswapFixture)

    token0 = fixture.token0
    token1 = fixture.token1
    pair = fixture.pair
    weth = fixture.WETH
    factory = fixture.dxswapFeactory
    router = fixture.router
    avatar = fixture.avatar
  })

  // 1/1/2020 @ 12:00 am UTC
  // cannot be 0 because that instructs ganache to set it to current timestamp
  // cannot be 86400 because then timestamp 0 is a valid historical observation
  const startTime = 1577836800

  // must come before adding liquidity to pairs for correct cumulative price computations
  // cannot use 0 because that resets to current timestamp
  beforeEach(`set start time to ${startTime}`, () => mineBlock(provider, startTime))

  it('requires granularity to be greater than 0', async () => {
    await expect(deployOracle(defaultWindowSize, 0)).to.be.revertedWith('LiquidityRelay: GRANULARITY')
  })

  it('requires windowSize to be evenly divisible by granularity', async () => {
    await expect(deployOracle(defaultWindowSize - 1, defaultGranularity)).to.be.revertedWith(
      'LiquidityRelay: WINDOW_NOT_EVENLY_DIVISIBLE'
    )
  })

  it('computes the periodSize correctly', async () => {
    const oracle = await deployOracle(defaultWindowSize, defaultGranularity)
    expect(await oracle.periodSize()).to.eq(600)
    const oracleOther = await deployOracle(defaultWindowSize * 2, defaultGranularity / 2)
    expect(await oracleOther.periodSize()).to.eq(600 * 4)

  })

  describe('#observationIndexOf', () => {
    it('works for examples', async () => {
      const oracle = await deployOracle(defaultWindowSize, defaultGranularity)
      expect(await oracle.observationIndexOf(0)).to.eq(0)
      expect(await oracle.observationIndexOf(599)).to.eq(0)
      expect(await oracle.observationIndexOf(600)).to.eq(1)
      expect(await oracle.observationIndexOf(780)).to.eq(1)
      expect(await oracle.observationIndexOf(1199)).to.eq(1)
      expect(await oracle.observationIndexOf(1200)).to.eq(2)
      expect(await oracle.observationIndexOf(2999)).to.eq(4)
      expect(await oracle.observationIndexOf(3000)).to.eq(5)
      expect(await oracle.observationIndexOf(3599)).to.eq(5)
      expect(await oracle.observationIndexOf(3700)).to.eq(0)
      expect(await oracle.observationIndexOf(4300)).to.eq(1)
    })
    it('overflow safe', async () => {
      const oracle = await deployOracle(25500, 255) // 100 period size
      expect(await oracle.observationIndexOf(0)).to.eq(0)
      expect(await oracle.observationIndexOf(99)).to.eq(0)
      expect(await oracle.observationIndexOf(100)).to.eq(1)
      expect(await oracle.observationIndexOf(199)).to.eq(1)
      expect(await oracle.observationIndexOf(25499)).to.eq(254) // 255th element
      expect(await oracle.observationIndexOf(25500)).to.eq(0)

    })
    it('matches offline computation', async () => {
      const oracle = await deployOracle(defaultWindowSize, defaultGranularity)
      for (let timestamp of [0, 5000, 1000, 25000, 86399, 86400, 86401]) {
        expect(await oracle.observationIndexOf(timestamp)).to.eq(observationIndexOf(timestamp))
      }
    })
  })

  describe('#update', () => {
    let liquidityRelay: Contract
    let ActionId: number

    async function addLiquidityAction(amount0: BigNumber = defaultToken0Amount, amount1: BigNumber = defaultToken1Amount) {

      await token0.transfer(avatar.address, amount0)
      await token1.transfer(avatar.address, amount1)
      let iLiquidityRelay = new utils.Interface(LiquidityRelay.abi)
      await avatar.externalTokenApproval(token0.address, liquidityRelay.address, amount0)
      await avatar.externalTokenApproval(token1.address, liquidityRelay.address, amount1)
      await wallet2.sendTransaction({
        to: avatar.address,
        value: utils.parseEther("6.0")
      });
      
      const callDataCreateAddition = await iLiquidityRelay.functions.createLiquidityAddition.encode([ token0.address, token1.address, 20, 20, 120, 25 ])
      
      let index = await liquidityRelay.liquidityActionsIndex();

      const GenericCall = await avatar.genericCall(liquidityRelay.address, callDataCreateAddition, utils.parseEther("2.0"), { gasLimit: 9999999999999})
      //const receipt = await GenericCall.wait()
  
      return index;
    }

    beforeEach(
      'deploy oracle',
      async () => (liquidityRelay = await deployOracle(defaultWindowSize, defaultGranularity))
    )

    beforeEach('add default liquidity', () => addLiquidity())

    beforeEach(
      'add liquidity action', 
      async () => (ActionId = await addLiquidityAction(bigNumberify(100), bigNumberify(100)))
    )

    it('succeeds', async () => {
      await mineBlock(provider, startTime + 600)
      await liquidityRelay.update(ActionId)
    })

    it('sets the appropriate epoch slot', async () => {
      const blockTimestamp = (await pair.getReserves())[2]
      expect(blockTimestamp).to.eq(startTime+1)
      await liquidityRelay.update(ActionId)

      expect(await liquidityRelay.pairObservations(ActionId, observationIndexOf(blockTimestamp))).to.deep.eq([
        bigNumberify(blockTimestamp),
        await pair.price0CumulativeLast(),
        await pair.price1CumulativeLast()
      ])
    }).retries(2) // we may have slight differences between pair blockTimestamp and the expected timestamp
    // because the previous block timestamp may differ from the current block timestamp by 1 second

    it('gas for update in the same period (skips)', async () => {
      await liquidityRelay.update(ActionId)
      const tx = await liquidityRelay.update(ActionId)
      const receipt = await tx.wait()
      expect(receipt.gasUsed).to.eq('37165')
    }).retries(2) // gas test inconsistent

    it('gas for second update different period (no allocate, no skip)', async () => {
      await liquidityRelay.update(ActionId)
      await mineBlock(provider, startTime + 3600)
      const tx = await liquidityRelay.update(ActionId)
      const receipt = await tx.wait()
      expect(receipt.gasUsed).to.eq('91742')
    }).retries(2) // gas test inconsistent

    it('second update in one timeslot does not overwrite', async () => {
      await liquidityRelay.update(ActionId)
      const before = await liquidityRelay.pairObservations(ActionId, observationIndexOf(0))
      // first hour still
      await mineBlock(provider, startTime + 200)
      await liquidityRelay.update(ActionId)
      const after = await liquidityRelay.pairObservations(ActionId, observationIndexOf(200))
      expect(observationIndexOf(200)).to.eq(observationIndexOf(0))
      expect(before).to.deep.eq(after)
    })

    it('fails for invalid actionId', async () => {
      await expect(liquidityRelay.update(150)).to.be.reverted
    })
  })

  describe('#consult', () => {
    let liquidityRelay: Contract
    let ActionId: number

    async function addLiquidityAction(amount0: BigNumber = defaultToken0Amount, amount1: BigNumber = defaultToken1Amount) {
      await token0.transfer(avatar.address, amount0)
      await token1.transfer(avatar.address, amount1)
      let iLiquidityRelay = new utils.Interface(LiquidityRelay.abi)
      await avatar.externalTokenApproval(token0.address, liquidityRelay.address, amount0)
      await avatar.externalTokenApproval(token1.address, liquidityRelay.address, amount1)
      await wallet2.sendTransaction({
        to: avatar.address,
        value: utils.parseEther("6.0")
      });
      
      const callDataCreateAddition = await iLiquidityRelay.functions.createLiquidityAddition.encode([ token0.address, token1.address, 20, 20, 120, 25 ])
      let index = await liquidityRelay.liquidityActionsIndex();
      const GenericCall = await avatar.genericCall(liquidityRelay.address, callDataCreateAddition, utils.parseEther("2.0"), { gasLimit: 9999999999999})
      return index;
    }

    beforeEach(
      'deploy oracle',
      async () => (liquidityRelay = await deployOracle(defaultWindowSize, defaultGranularity))
    )

    // must come after setting time to 0 for correct cumulative price computations in the pair
    beforeEach('add default liquidity', () => addLiquidity())

    beforeEach(
      'add liquidity action', 
      async () => (ActionId = await addLiquidityAction(bigNumberify(100), bigNumberify(100)))
    )

    it('fails if previous bucket not set', async () => {
      await liquidityRelay.update(ActionId)
      await expect(liquidityRelay.consult(ActionId, token0.address, 0, token1.address)).to.be.revertedWith(
        'LiquidityRelay: MISSING_HISTORICAL_OBSERVATION'
      )
    })

    it('fails for invalid action', async () => {
      await expect(liquidityRelay.consult(13, token0.address, 0, token1.address)).to.be.reverted
    })

    describe('happy path', () => {
      let liquidityRelay: Contract
      let blockTimestamp: number
      let previousBlockTimestamp: number
      let previousCumulativePrices: any
      let ActionId: number

      async function addLiquidityAction(amount0: BigNumber = defaultToken0Amount, amount1: BigNumber = defaultToken1Amount) {
        await token0.transfer(avatar.address, amount0)
        await token1.transfer(avatar.address, amount1)
        let iLiquidityRelay = new utils.Interface(LiquidityRelay.abi)
        await avatar.externalTokenApproval(token0.address, liquidityRelay.address, amount0)
        await avatar.externalTokenApproval(token1.address, liquidityRelay.address, amount1)
        await wallet2.sendTransaction({
          to: avatar.address,
          value: utils.parseEther("6.0")
        });
        
        const callDataCreateAddition = await iLiquidityRelay.functions.createLiquidityAddition.encode([ token0.address, token1.address, 20, 20, 120, 25 ])
        let index = await liquidityRelay.liquidityActionsIndex();
        const GenericCall = await avatar.genericCall(liquidityRelay.address, callDataCreateAddition, utils.parseEther("2.0"), { gasLimit: 9999999999999})
        return index;
      }

      beforeEach(
        'deploy oracle',
        async () => (liquidityRelay = await deployOracle(defaultWindowSize, defaultGranularity))
      )
  
      beforeEach(
        'add liquidity action', 
        async () => (ActionId = await addLiquidityAction(bigNumberify(100), bigNumberify(100)))
      )

      beforeEach('add some prices', async () => {
        previousBlockTimestamp = (await pair.getReserves())[2]
        previousCumulativePrices = [await pair.price0CumulativeLast(), await pair.price1CumulativeLast()]
        await liquidityRelay.update(ActionId)
        blockTimestamp = previousBlockTimestamp + 5 * 600
        await mineBlock(provider, blockTimestamp)
        await liquidityRelay.update(ActionId)
      })

      it('has cumulative price in previous bucket', async () => {
        expect(
          await liquidityRelay.pairObservations(ActionId, observationIndexOf(previousBlockTimestamp))
        ).to.deep.eq([bigNumberify(previousBlockTimestamp), previousCumulativePrices[0], previousCumulativePrices[1]])
      }).retries(5) // test flaky because timestamps aren't mocked

      it('has cumulative price in current bucket', async () => {
        const timeElapsed = blockTimestamp - previousBlockTimestamp
        const prices = encodePrice(defaultToken0Amount, defaultToken1Amount)
        expect(
          await liquidityRelay.pairObservations(ActionId, observationIndexOf(blockTimestamp))
        ).to.deep.eq([bigNumberify(blockTimestamp), prices[0].mul(timeElapsed), prices[1].mul(timeElapsed)])
      }).retries(5) // test flaky because timestamps aren't mocked

      it('provides the current ratio in consult token0', async () => {
        expect(await liquidityRelay.consult(ActionId, token0.address, 100, token1.address)).to.eq(200)
      })

      it('provides the current ratio in consult token1', async () => {
        expect(await liquidityRelay.consult(ActionId, token1.address, 100, token0.address)).to.eq(50)
      })
    })

    describe('price changes over period', () => {
      const hour = 600
      beforeEach('add some prices', async () => {
        // starting price of 1:2, or token0 = 2token1, token1 = 0.5token0
        await liquidityRelay.update(ActionId) // hour 0, 1:2
        // change the price at hour 3 to 1:1 and immediately update
        await mineBlock(provider, startTime + 1 * hour)
        await addLiquidity(defaultToken0Amount, bigNumberify(0))
        await liquidityRelay.update(ActionId)

        // change the ratios at hour 6:00 to 2:1, don't update right away
        await mineBlock(provider, startTime + 2 * hour)
        await token0.transfer(pair.address, defaultToken0Amount.mul(2))
        await pair.sync()

        // update at hour 9:00 (price has been 2:1 for 3 hours, invokes counterfactual)
        await mineBlock(provider, startTime + 3 * hour)
        await liquidityRelay.update(ActionId)
        // move to hour 23:00 so we can check prices
        await mineBlock(provider, startTime + 4 * hour)
      })

      it('provides the correct ratio in consult token0', async () => {
        // at hour 23, price of token 0 spent 3 hours at 2, 3 hours at 1, 17 hours at 0.5 so price should
        // be less than 1
        expect(await liquidityRelay.consult(ActionId, token0.address, 100, token1.address)).to.eq(76)
      })

      it('provides the correct ratio in consult token1', async () => {
        // price should be greater than 1
        expect(await liquidityRelay.consult(ActionId, token1.address, 100, token0.address)).to.eq(167)
      })

      // price has been 2:1 all of 23 hours
      describe('hour 32', () => {
        beforeEach('set hour 32', () => mineBlock(provider, startTime + 8 * hour))
        it('provides the correct ratio in consult token0', async () => {
          // at hour 23, price of token 0 spent 3 hours at 2, 3 hours at 1, 17 hours at 0.5 so price should
          // be less than 1
          expect(await liquidityRelay.consult(ActionId, token0.address, 100, token1.address)).to.eq(50)
        })

        it('provides the correct ratio in consult token1', async () => {
          // price should be greater than 1
          expect(await liquidityRelay.consult(ActionId, token1.address, 100, token0.address)).to.eq(200)
        })
      })
    })
  })
})
