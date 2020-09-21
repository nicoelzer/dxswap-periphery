import { Wallet, Contract } from 'ethers'
import { Web3Provider } from 'ethers/providers'
import { deployContract } from 'ethereum-waffle'

import { expandTo18Decimals } from './utilities'

import DXswapFactory from 'dxswap-core/build/contracts/DXswapFactory.json'
import IDXswapPair from 'dxswap-core/build/contracts/IDXswapPair.json'
import dxdaoAvatar from '../../build/contracts/DxAvatar.json'

import ERC20 from '../../build/contracts/ERC20.json'
import WETH9 from '../../build/contracts/WETH9.json'
import DXswapRouter from '../../build/contracts/DXswapRouter.json'
import RouterEventEmitter from '../../build/contracts/RouterEventEmitter.json'

const overrides = {
  gasLimit: 9999999
}

interface DXswapFixture {
  token0: Contract
  token1: Contract
  WETH: Contract
  WETHPartner: Contract
  dxswapFeactory: Contract
  routerEventEmitter: Contract
  router: Contract
  pair: Contract
  WETHPair: Contract
  avatar: Contract
}

export async function dxswapFixture(provider: Web3Provider, [wallet]: Wallet[]): Promise<DXswapFixture> {
  // deploy tokens
  const tokenA = await deployContract(wallet, ERC20, [expandTo18Decimals(10000)])
  const tokenB = await deployContract(wallet, ERC20, [expandTo18Decimals(10000)])
  const WETH = await deployContract(wallet, WETH9)
  const WETHPartner = await deployContract(wallet, ERC20, [expandTo18Decimals(10000)])

  // deploy DXswapFactory
  const dxswapFeactory = await deployContract(wallet, DXswapFactory, [wallet.address])

  // deploy router
  const router = await deployContract(wallet, DXswapRouter, [dxswapFeactory.address, WETH.address], overrides)

  // deploy Avatar
  const avatar = await deployContract(wallet, dxdaoAvatar, [], overrides)

  // event emitter for testing
  const routerEventEmitter = await deployContract(wallet, RouterEventEmitter, [])

  // initialize DXswapFactory
  await dxswapFeactory.createPair(tokenA.address, tokenB.address)
  const pairAddress = await dxswapFeactory.getPair(tokenA.address, tokenB.address)
  const pair = new Contract(pairAddress, JSON.stringify(IDXswapPair.abi), provider).connect(wallet)

  const token0Address = await pair.token0()
  const token0 = tokenA.address === token0Address ? tokenA : tokenB
  const token1 = tokenA.address === token0Address ? tokenB : tokenA

  await dxswapFeactory.createPair(WETH.address, WETHPartner.address)
  const WETHPairAddress = await dxswapFeactory.getPair(WETH.address, WETHPartner.address)
  const WETHPair = new Contract(WETHPairAddress, JSON.stringify(IDXswapPair.abi), provider).connect(wallet)

  return {
    token0,
    token1,
    WETH,
    WETHPartner,
    dxswapFeactory,
    router,
    routerEventEmitter,
    pair,
    WETHPair,
    avatar
  }
}
