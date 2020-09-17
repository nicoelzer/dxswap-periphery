// TODO:
// – CreateLiquidityProvision FOR ETH<>ERC20 Pairs
// – Handle ETH transfers

pragma solidity =0.6.6;

import 'dxswap-core/contracts/interfaces/IDXswapFactory.sol';
import 'dxswap-core/contracts/interfaces/IDXswapPair.sol';

import '../interfaces/IDXswapRouter.sol';
import '../interfaces/IERC20.sol';
import '../libraries/FixedPoint.sol';
import '../libraries/DXswapOracleLibrary.sol';
import '../libraries/DXswapLibrary.sol';

contract AddLiquidityToAveragePrice {
    using FixedPoint for *;
    using SafeMath for uint256;

    event NewLiquidityProvision(
        uint256 _provisionId,
        address _tokenA,
        address _tokenB,
        uint256 _amountTokenA,
        uint256 _amountTokenB,
        uint256 _deadline
    );

    event ExecutedLiquidityProvision(uint256 _provisionId, uint256 _amountA, uint256 _amountB, uint256 _liquidity);

    enum LiqudityProvisionState {CREATED, PRICE_OBERSERVATION, FINISHED, EXECUTED}

    address payable public dxdaoAvatar;

    struct LiquidityProvision {
        address tokenA;
        address tokenB;
        uint256 amountTokenA;
        uint256 amountTokenB;
        uint256 startSyncTime;
        uint256 actualSyncPeriod;
        uint256 cumulativeQuote;
        uint256 deadline;
        LiqudityProvisionState state;
    }

    address public immutable factory;
    address public immutable router;
    uint256 public minimunSyncTime;
    uint256 public syncPeriods;

    LiquidityProvision[] public liquidityProvisions;
    uint256 public liquidityProvisionsCount;

    constructor(
        address payable _dxdaoAvatar,
        address factory_,
        address router_,
        uint256 _minimunSyncTime,
        uint8 _syncPeriods
    ) public {
        require(_minimunSyncTime > 1, 'AddLiquidityToAveragePrice: MINIMIM_SYNC_TIME');
        require(_syncPeriods > 1, 'AddLiquidityToAveragePrice: SYNC_PERIODS');
        dxdaoAvatar = _dxdaoAvatar;
        factory = factory_;
        router = router_;
        minimunSyncTime = _minimunSyncTime;
        syncPeriods = _syncPeriods;
    }

    function createLiquidityProvision(
        address tokenA,
        address tokenB,
        uint256 amountTokenA,
        uint256 amountTokenB,
        uint256 deadline
    ) public returns (uint8 liquidityProvisionsCount) {
        require(msg.sender == dxdaoAvatar, 'AddLiquidityToAveragePrice: CALLER_NOT_DXDAO');
        require(IERC20(tokenA).transfer(address(this), amountTokenA), 'AddLiquidityToAveragePrice: TRANSFER_FAILED_TOKEN_A');
        require(IERC20(tokenB).transfer(address(this), amountTokenB), 'AddLiquidityToAveragePrice: TRANSFER_FAILED_TOKEN_B');

        liquidityProvisions.push(
            LiquidityProvision({
                tokenA: tokenA,
                tokenB: tokenB,
                amountTokenA: amountTokenA,
                amountTokenB: amountTokenB,
                startSyncTime: block.timestamp,
                actualSyncPeriod: 1,
                cumulativeQuote: 0,
                deadline: deadline,
                state: LiqudityProvisionState.CREATED
            })
        );

        updateQuote(liquidityProvisionsCount);

        emit NewLiquidityProvision(liquidityProvisionsCount, tokenA, tokenB, amountTokenA, amountTokenB, deadline);

        liquidityProvisionsCount++;
    }

    function updateQuote(uint256 provision) public {
        require(
            liquidityProvisions[provision].state == LiqudityProvisionState.PRICE_OBERSERVATION,
            'AddLiquidityToAveragePrice: STATE_NOT_OBSERVATION'
        );
        require(
            block.timestamp >=
                liquidityProvisions[provision].startSyncTime.add(
                    liquidityProvisions[provision].actualSyncPeriod.mul(minimunSyncTime)
                ),
            'AddLiquidityToAveragePrice: MINUMUM_SYNCTIME_NOT_PASSED'
        );

        address pair = DXswapLibrary.pairFor(
            factory,
            liquidityProvisions[provision].tokenA,
            liquidityProvisions[provision].tokenB
        );
        (uint256 reserve0, uint256 reserve1, ) = IDXswapPair(pair).getReserves();
        uint256 amountTokenB = liquidityProvisions[provision].amountTokenA.mul(reserve1) / reserve0;
        liquidityProvisions[provision].cumulativeQuote = liquidityProvisions[provision].cumulativeQuote.add(
            amountTokenB
        );
        liquidityProvisions[provision].actualSyncPeriod = liquidityProvisions[provision].actualSyncPeriod.add(1);
        if (liquidityProvisions[provision].actualSyncPeriod == syncPeriods) {
            liquidityProvisions[provision].state = LiqudityProvisionState.FINISHED;
        }
    }

    function executeLiquidityProvision(uint256 provision) public {
        require(provision <= liquidityProvisionsCount, 'AddLiquidityToAveragePrice: INVALID_PROVISION');
        require(
            liquidityProvisions[provision].state == LiqudityProvisionState.FINISHED,
            'AddLiquidityToAveragePrice: NOT_FINISHED'
        );
        require(
            IERC20(liquidityProvisions[provision].tokenA).balanceOf(address(this)) >=
                liquidityProvisions[provision].amountTokenA,
            'AddLiquidityToAveragePrice: INSUFFICIENT_BALANCE_TOKEN_A'
        );
        require(
            IERC20(liquidityProvisions[provision].tokenB).balanceOf(address(this)) >=
                liquidityProvisions[provision].amountTokenB,
            'AddLiquidityToAveragePrice: INSUFFICIENT_BALANCE_TOKEN_B'
        );
        require(
            IERC20(liquidityProvisions[provision].tokenA).approve(router, liquidityProvisions[provision].amountTokenA),
            'AddLiquidityToAveragePrice: APPROVE_FAILED_TOKEN_A'
        );
        require(
            IERC20(liquidityProvisions[provision].tokenB).approve(router, liquidityProvisions[provision].amountTokenB),
            'AddLiquidityToAveragePrice: APPROVE_FAILED_TOKEN_B'
        );

        uint256 targetAmountTokenB = liquidityProvisions[provision].cumulativeQuote / syncPeriods;
        (uint256 amountA, uint256 amountB, uint256 liquidity) = IDXswapRouter(router).addLiquidity(
            liquidityProvisions[provision].tokenA,
            liquidityProvisions[provision].tokenB,
            liquidityProvisions[provision].amountTokenA,
            liquidityProvisions[provision].amountTokenB,
            0, /* TODO amountAMin: To be calculated */
            targetAmountTokenB, /* TODO amountBMin: To be calculated */
            dxdaoAvatar,
            liquidityProvisions[provision].deadline
        );

        /* Send back Token A Fragments */
        IERC20(liquidityProvisions[provision].tokenA).transfer(
            dxdaoAvatar,
            liquidityProvisions[provision].amountTokenA.sub(amountA)
        );
        /* Send back Token B Fragments */
        IERC20(liquidityProvisions[provision].tokenA).transfer(
            dxdaoAvatar,
            liquidityProvisions[provision].amountTokenB.sub(amountB)
        );

        /* Reset approval for router */
        IERC20(liquidityProvisions[provision].tokenA).approve(router, 0);
        IERC20(liquidityProvisions[provision].tokenB).approve(router, 0);

        liquidityProvisions[provision].state = LiqudityProvisionState.EXECUTED;
        emit ExecutedLiquidityProvision(provision, amountA, amountB, liquidity);
    }
}
