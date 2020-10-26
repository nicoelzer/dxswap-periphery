import chai, { expect } from 'chai'
import { Contract, utils } from 'ethers'
import { AddressZero, MaxUint256 } from 'ethers/constants'
import { BigNumber } from 'ethers/utils'
import { solidity, MockProvider, createFixtureLoader } from 'ethereum-waffle'

import { expandTo18Decimals, mineBlock, MINIMUM_LIQUIDITY } from './shared/utilities'
import { dxswapFixture } from './shared/fixtures'

chai.use(solidity)

const overrides = {
  gasLimit: 7999999999999999
}

describe('DXswapRelayer', () => {
  const provider = new MockProvider({
    hardfork: 'istanbul',
    mnemonic: 'horn horn horn horn horn horn horn horn horn horn horn horn',
    gasLimit: 7999999999999999
  })
  const [wallet, wallet2] = provider.getWallets()
  const loadFixture = createFixtureLoader(provider, [wallet])

  let token0: Contract
  let token1: Contract
  let weth: Contract
  let wethPartner: Contract
  let wethPair: Contract
  let dxswapPair: Contract
  let dxswapFactory: Contract
  let dxswapRouter: Contract
  let uniPair: Contract
  let uniFactory: Contract
  let uniRouter: Contract
  let oracleCreator: Contract
  let dxRelayer: Contract

  async function addLiquidity(amount0: BigNumber = defaultAmountA, amount1: BigNumber = defaultAmountB) {
    if (!amount0.isZero()) await token0.transfer(dxswapPair.address, amount0)
    if (!amount1.isZero()) await token1.transfer(dxswapPair.address, amount1)
    await dxswapPair.sync()
  }

  const defaultAmountA = expandTo18Decimals(1)
  const defaultAmountB = expandTo18Decimals(4)
  const expectedLiquidity = expandTo18Decimals(2)
  const defaultPriceTolerance = 990000 // TODOOOOO: 99%
  const defaultMinReserve = expandTo18Decimals(1)
  const defaultDeadline = Date.now() + 1800 // 30 Minutes
  const defaultMaxWindowTime = 300 // 5 Minutes

  beforeEach('deploy fixture', async function() {
    const fixture = await loadFixture(dxswapFixture)
    token0 = fixture.token0
    token1 = fixture.token1
    weth = fixture.WETH
    wethPartner = fixture.WETHPartner
    wethPair = fixture.WETHPair
    dxswapPair = fixture.pair
    dxswapFactory = fixture.dxswapFactory
    dxswapRouter = fixture.dxswapRouter
    uniPair = fixture.pair
    uniFactory = fixture.dxswapFactory
    uniRouter = fixture.uniRouter
    oracleCreator = fixture.oracleCreator
    dxRelayer = fixture.dxRelayer
  })

  beforeEach('approve the relayer contract to spend any amount of tokens', async () => {
    await token0.approve(dxRelayer.address, MaxUint256)
    await token1.approve(dxRelayer.address, MaxUint256)
    await weth.approve(dxRelayer.address, MaxUint256)
    await wethPartner.approve(dxRelayer.address, MaxUint256)
  })

  beforeEach('fund the relayer to pay bounties', async () => {
    await wallet.sendTransaction({
      to: dxRelayer.address,
      value: utils.parseEther('10.0')
    })
  })

  describe('Liquidity provision', () => {
    it('requires correct order input', async () => {
      await expect(
        dxRelayer.orderLiquidityProvision(
          token0.address,
          token1.address,
          defaultAmountA,
          defaultAmountB,
          defaultPriceTolerance,
          defaultMinReserve,
          defaultMinReserve,
          defaultMaxWindowTime,
          defaultDeadline,
          token0.address
        )
      ).to.be.revertedWith('DXswapRelayer: INVALID_FACTORY')

      const dxRelayerFromWallet2 = dxRelayer.connect(wallet2)
      await expect(
        dxRelayerFromWallet2.orderLiquidityProvision(
          token0.address,
          token1.address,
          defaultAmountA,
          defaultAmountB,
          defaultPriceTolerance,
          defaultMinReserve,
          defaultMinReserve,
          defaultMaxWindowTime,
          defaultDeadline,
          dxswapFactory.address
        )
      ).to.be.revertedWith('DXswapRelayer: CALLER_NOT_OWNER')

      await expect(
        dxRelayer.orderLiquidityProvision(
          token1.address,
          token1.address,
          defaultAmountA,
          defaultAmountB,
          defaultPriceTolerance,
          defaultMinReserve,
          defaultMinReserve,
          defaultMaxWindowTime,
          defaultDeadline,
          dxswapFactory.address
        )
      ).to.be.revertedWith('DXswapRelayer: INVALID_PAIR')

      await expect(
        dxRelayer.orderLiquidityProvision(
          token1.address,
          token0.address,
          defaultAmountA,
          defaultAmountB,
          defaultPriceTolerance,
          defaultMinReserve,
          defaultMinReserve,
          defaultMaxWindowTime,
          defaultDeadline,
          dxswapFactory.address
        )
      ).to.be.revertedWith('DXswapRelayer: INVALID_TOKEN_ORDER')

      await expect(
        dxRelayer.orderLiquidityProvision(
          token0.address,
          token1.address,
          0,
          defaultAmountB,
          defaultPriceTolerance,
          defaultMinReserve,
          defaultMinReserve,
          defaultMaxWindowTime,
          defaultDeadline,
          dxswapFactory.address
        )
      ).to.be.revertedWith('DXswapRelayer: INVALID_TOKEN_AMOUNT')

      await expect(
        dxRelayer.orderLiquidityProvision(
          token0.address,
          token1.address,
          defaultAmountA,
          defaultAmountB,
          1000000000,
          defaultMinReserve,
          defaultMinReserve,
          defaultMaxWindowTime,
          defaultDeadline,
          dxswapFactory.address
        )
      ).to.be.revertedWith('DXswapRelayer: INVALID_TOLERANCE')

      await expect(
        dxRelayer.orderLiquidityProvision(
          token0.address,
          token1.address,
          defaultAmountA,
          defaultAmountB,
          defaultPriceTolerance,
          defaultMinReserve,
          defaultMinReserve,
          defaultMaxWindowTime,
          1577836800,
          dxswapFactory.address
        )
      ).to.be.revertedWith('DXswapRelayer: DEADLINE_REACHED')
    })

    it('provides initial liquidity immediately with ERC20/ERC20 pair', async () => {
      await expect(
        dxRelayer.orderLiquidityProvision(
          token0.address,
          token1.address,
          defaultAmountA,
          defaultAmountB,
          defaultPriceTolerance,
          0,
          0,
          defaultMaxWindowTime,
          defaultDeadline,
          dxswapFactory.address
        )
      )
        .to.emit(token0, 'Transfer')
        .withArgs(wallet.address, dxRelayer.address, defaultAmountA)
        .to.emit(token1, 'Transfer')
        .withArgs(wallet.address, dxRelayer.address, defaultAmountB)
        .to.emit(dxRelayer, 'NewOrder')
        .withArgs(1, 1)
        .to.emit(dxswapPair, 'Transfer')
        .withArgs(AddressZero, AddressZero, MINIMUM_LIQUIDITY)
        .to.emit(dxswapPair, 'Transfer')
        .withArgs(AddressZero, wallet.address, expectedLiquidity.sub(MINIMUM_LIQUIDITY))
        .to.emit(dxswapPair, 'Sync')
        .withArgs(defaultAmountA, defaultAmountB)
        .to.emit(dxswapPair, 'Mint')
        .withArgs(dxswapRouter.address, defaultAmountA, defaultAmountB)
        .to.emit(dxRelayer, 'ExecutedOrder')
        .withArgs(1)

      expect(await dxswapPair.balanceOf(wallet.address)).to.eq(expectedLiquidity.sub(MINIMUM_LIQUIDITY))
    })

    it('Provides initial liquidity immediately with ETH/ERC20 pair', async () => {
      await expect(
        dxRelayer.orderLiquidityProvision(
          AddressZero,
          wethPartner.address,
          defaultAmountA,
          defaultAmountB,
          defaultPriceTolerance,
          0,
          0,
          defaultMaxWindowTime,
          defaultDeadline,
          dxswapFactory.address,
          { ...overrides, value: defaultAmountA }
        )
      )
        .to.emit(wethPartner, 'Transfer')
        .withArgs(wallet.address, dxRelayer.address, defaultAmountB)
        .to.emit(dxRelayer, 'NewOrder')
        .withArgs(1, 1)
        .to.emit(wethPair, 'Transfer')
        .withArgs(AddressZero, AddressZero, MINIMUM_LIQUIDITY)
        .to.emit(wethPair, 'Transfer')
        .withArgs(AddressZero, wallet.address, expectedLiquidity.sub(MINIMUM_LIQUIDITY))
        .to.emit(wethPair, 'Sync')
        .withArgs(defaultAmountB, defaultAmountA)
        .to.emit(wethPair, 'Mint')
        .withArgs(dxswapRouter.address, defaultAmountB, defaultAmountA)
        .to.emit(dxRelayer, 'ExecutedOrder')
        .withArgs(1)

      expect(await wethPair.balanceOf(wallet.address)).to.eq(expectedLiquidity.sub(MINIMUM_LIQUIDITY))
    })

    it('reverts updates if minReserve is not reached', async () => {
      await expect(
        dxRelayer.orderLiquidityProvision(
          token0.address,
          token1.address,
          defaultAmountA,
          defaultAmountB,
          defaultPriceTolerance,
          defaultMinReserve,
          defaultMinReserve,
          defaultMaxWindowTime,
          defaultDeadline,
          dxswapFactory.address
        )
      )
        .to.emit(dxRelayer, 'NewOrder')
        .withArgs(1, 1)

      await expect(dxRelayer.updateOracle(1)).to.be.revertedWith('DXswapRelayer: RESERVE_TO_LOW')
    })

    it('updates price oracle', async () => {
      await addLiquidity(expandTo18Decimals(10), expandTo18Decimals(40))
      await expect(
        dxRelayer.orderLiquidityProvision(
          token0.address,
          token1.address,
          defaultAmountA,
          defaultAmountB,
          defaultPriceTolerance,
          defaultMinReserve,
          defaultMinReserve,
          defaultMaxWindowTime,
          defaultDeadline,
          dxswapFactory.address
        )
      )
        .to.emit(dxRelayer, 'NewOrder')
        .withArgs(1, 1)

      await dxRelayer.updateOracle(1)
      await expect(dxRelayer.updateOracle(1)).to.be.revertedWith('OracleCreator: PERIOD_NOT_ELAPSED')
      await mineBlock(provider, Date.now() + 350)
      await dxRelayer.updateOracle(1)
    })

    it('Provides liquidity with ERC20/ERC20 pair after price observation', async () => {
      await addLiquidity(expandTo18Decimals(10), expandTo18Decimals(40))
      await expect(
        dxRelayer.orderLiquidityProvision(
          token0.address,
          token1.address,
          defaultAmountA,
          defaultAmountB,
          defaultPriceTolerance,
          defaultMinReserve,
          defaultMinReserve,
          defaultMaxWindowTime,
          defaultDeadline,
          dxswapFactory.address
        )
      )
        .to.emit(token0, 'Transfer')
        .withArgs(wallet.address, dxRelayer.address, defaultAmountA)
        .to.emit(token1, 'Transfer')
        .withArgs(wallet.address, dxRelayer.address, defaultAmountB)
        .to.emit(dxRelayer, 'NewOrder')
        .withArgs(1, 1)

      await dxRelayer.updateOracle(1)
      await mineBlock(provider, Date.now() + 350)
      await dxRelayer.updateOracle(1)
      await dxRelayer.executeOrder(1)
      /* TODO ADD PRICE CHECKS */
    })

    it('Provides liquidity with ETH/ERC20 pair after price observation', async () => {
      await weth.deposit({ ...overrides, value: expandTo18Decimals(10) })
      await weth.transfer(wethPair.address, expandTo18Decimals(10))
      await wethPartner.transfer(wethPair.address, expandTo18Decimals(40))
      await wethPair.sync()

      await expect(
        dxRelayer.orderLiquidityProvision(
          AddressZero,
          wethPartner.address,
          defaultAmountA,
          defaultAmountB,
          defaultPriceTolerance,
          defaultMinReserve,
          defaultMinReserve,
          defaultMaxWindowTime,
          defaultDeadline,
          dxswapFactory.address,
          { ...overrides, value: defaultAmountA }
        )
      )
        .to.emit(wethPartner, 'Transfer')
        .withArgs(wallet.address, dxRelayer.address, defaultAmountB)
        .to.emit(dxRelayer, 'NewOrder')
        .withArgs(1, 1)

      await dxRelayer.updateOracle(1)
      await mineBlock(provider, Date.now() + 200)
      await dxRelayer.updateOracle(1)
      await dxRelayer.executeOrder(1)
      /* TODO ADD PRICE CHECKS */
    })
  })

  describe('Liquidity removal', () => {
    it('requires correct order input', async () => {
      const liquidityAmount = expandTo18Decimals(1)

      await expect(
        dxRelayer.orderLiquidityRemoval(
          token0.address,
          token1.address,
          liquidityAmount,
          defaultAmountA,
          defaultAmountB,
          defaultPriceTolerance,
          defaultMinReserve,
          defaultMinReserve,
          defaultMaxWindowTime,
          defaultDeadline,
          token0.address
        )
      ).to.be.revertedWith('DXswapRelayer: INVALID_FACTORY')

      const dxRelayerFromWallet2 = dxRelayer.connect(wallet2)
      await expect(
        dxRelayerFromWallet2.orderLiquidityRemoval(
          token0.address,
          token1.address,
          liquidityAmount,
          defaultAmountA,
          defaultAmountB,
          defaultPriceTolerance,
          defaultMinReserve,
          defaultMinReserve,
          defaultMaxWindowTime,
          defaultDeadline,
          dxswapFactory.address
        )
      ).to.be.revertedWith('DXswapRelayer: CALLER_NOT_OWNER')

      await expect(
        dxRelayer.orderLiquidityRemoval(
          token1.address,
          token1.address,
          liquidityAmount,
          defaultAmountA,
          defaultAmountB,
          defaultPriceTolerance,
          defaultMinReserve,
          defaultMinReserve,
          defaultMaxWindowTime,
          defaultDeadline,
          dxswapFactory.address
        )
      ).to.be.revertedWith('DXswapRelayer: INVALID_PAIR')

      await expect(
        dxRelayer.orderLiquidityRemoval(
          token1.address,
          token0.address,
          liquidityAmount,
          defaultAmountA,
          defaultAmountB,
          defaultPriceTolerance,
          defaultMinReserve,
          defaultMinReserve,
          defaultMaxWindowTime,
          defaultDeadline,
          dxswapFactory.address
        )
      ).to.be.revertedWith('DXswapRelayer: INVALID_TOKEN_ORDER')

      await expect(
        dxRelayer.orderLiquidityRemoval(
          token0.address,
          token1.address,
          liquidityAmount,
          0,
          defaultAmountB,
          defaultPriceTolerance,
          defaultMinReserve,
          defaultMinReserve,
          defaultMaxWindowTime,
          defaultDeadline,
          dxswapFactory.address
        )
      ).to.be.revertedWith('DXswapRelayer: INVALID_LIQUIDITY_AMOUNT')

      await expect(
        dxRelayer.orderLiquidityRemoval(
          token0.address,
          token1.address,
          liquidityAmount,
          defaultAmountA,
          defaultAmountB,
          1000000000,
          defaultMinReserve,
          defaultMinReserve,
          defaultMaxWindowTime,
          defaultDeadline,
          dxswapFactory.address
        )
      ).to.be.revertedWith('DXswapRelayer: INVALID_TOLERANCE')

      await expect(
        dxRelayer.orderLiquidityRemoval(
          token0.address,
          token1.address,
          liquidityAmount,
          defaultAmountA,
          defaultAmountB,
          defaultPriceTolerance,
          defaultMinReserve,
          defaultMinReserve,
          defaultMaxWindowTime,
          1577836800,
          dxswapFactory.address
        )
      ).to.be.revertedWith('DXswapRelayer: DEADLINE_REACHED')
    })
  })

  describe('Oracle price calulation', () => {
    it('calculates average', async () => {})
  })
})
