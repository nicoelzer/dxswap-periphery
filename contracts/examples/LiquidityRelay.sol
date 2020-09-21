pragma solidity =0.6.6;

import 'dxswap-core/contracts/interfaces/IDXswapFactory.sol';
import 'dxswap-core/contracts/interfaces/IDXswapPair.sol';

import '../interfaces/IDXswapRouter.sol';
import '../interfaces/IERC20.sol';
import '../libraries/FixedPoint.sol';
import '../libraries/DXswapOracleLibrary.sol';
import '../libraries/DXswapLibrary.sol';

contract LiquidityRelay {
    using FixedPoint for *;
    using SafeMath for uint256;

    event NewLiquidityAddition(
        uint256 _actionId,
        address _tokenA,
        address _tokenB,
        uint256 _amountTokenA,
        uint256 _amountTokenB,
        uint256 _deadline,
        uint256 _priceSlippage
    );

    event NewLiquidityRemoval(
        uint256 _actionId,
        address _tokenA,
        address _tokenB,
        uint256 _liquidity,
        uint256 _deadline,
        uint256 _priceSlippage
    );

    event ExecutedLiquidityAddition(uint256 _actionId, uint256 _amountA, uint256 _amountB, uint256 _liquidity);
    event ExecutedLiquidityRemoval(uint256 _actionId, uint256 _amountA, uint256 _amountB);

    enum LiquidityActionState {CREATED, PRICE_OBERSERVATION, PRICE_OBERSERVATION_FINISHED, EXECUTED}

    struct LiquidityAction {
        uint8 action; // 1=Adding Liquidity; 2=Removing Liquidity
        address tokenA;
        address tokenB;
        uint256 amountTokenA;
        uint256 amountTokenB;
        uint256 liquidity;
        uint256 deadline;
        uint256 priceSlippage;
        uint256 finishedTimestamp;
        address pair;
        LiquidityActionState state;
        mapping(address => Observation[]) pairObservations;
    }

    struct Observation {
        uint256 timestamp;
        uint256 price0Cumulative;
        uint256 price1Cumulative;
    }

    uint8 public immutable REMOVAL = 1;
    uint8 public immutable ADDITION = 2;
    address payable public immutable dxdaoAvatar;
    address public immutable factory;
    address public immutable router;
    uint256 public immutable executionBountyWei;
    // the desired amount of time over which the moving average should be computed, e.g. 24 hours
    uint256 public immutable windowSize;
    // the number of observations stored for each pair, i.e. how many price observations are stored for the window.
    // as granularity increases from 1, more frequent updates are needed, but moving averages become more precise.
    // averages are computed over intervals with sizes in the range:
    //   [windowSize - (windowSize / granularity) * 2, windowSize]
    // e.g. if the window size is 24 hours, and the granularity is 24, the oracle will return the average price for
    //   the period:
    //   [now - [22 hours, 24 hours], now]
    uint8 public immutable granularity;
    // this is redundant with granularity and windowSize, but stored for gas savings & informational purposes.
    uint256 public immutable periodSize;

    LiquidityAction[] public liquidityActions;
    uint256 public liquidityActionsIndex;

    constructor(
        address payable _dxdaoAvatar,
        address factory_,
        address router_,
        uint256 _windowSize,
        uint8 _granularity,
        uint256 _executionBountyWei
    ) public {
        require(_granularity > 1, 'LiquidityRelay: GRANULARITY');
        require(
            (periodSize = _windowSize / _granularity) * _granularity == _windowSize,
            'LiquidityRelay: WINDOW_NOT_EVENLY_DIVISIBLE'
        );
        dxdaoAvatar = _dxdaoAvatar;
        factory = factory_;
        router = router_;
        windowSize = _windowSize;
        granularity = _granularity;
        executionBountyWei = _executionBountyWei;
    }

    function createLiquidityAddition(
        address tokenA,
        address tokenB,
        uint256 amountTokenA,
        uint256 amountTokenB,
        uint256 deadline,
        uint256 priceSlippage
    ) public payable returns (uint256) {
        require(msg.sender == dxdaoAvatar, 'AddLiquidityToAveragePrice: CALLER_NOT_DXDAO');
        require(msg.value == executionBountyWei.mul(periodSize), 'AddLiquidityToAveragePrice: BOUNTY NOT PROVIDED');
        require(
            IERC20(tokenA).allowance(dxdaoAvatar, address(this)) >= amountTokenA,
            'AddLiquidityToAveragePrice: INSUFFICIENT_ALLOWANCE_TOKEN_A'
        );
        require(
            IERC20(tokenB).allowance(dxdaoAvatar, address(this)) >= amountTokenB,
            'AddLiquidityToAveragePrice: INSUFFICIENT_ALLOWANCE_TOKEN_B'
        );
        require(
            IERC20(tokenA).transferFrom(dxdaoAvatar, address(this), amountTokenA),
            'AddLiquidityToAveragePrice: TRANSFER_FAILED_TOKEN_A'
        );
        require(
            IERC20(tokenB).transferFrom(dxdaoAvatar, address(this), amountTokenB),
            'AddLiquidityToAveragePrice: TRANSFER_FAILED_TOKEN_B'
        );

        uint256 actionId = createLiquidityAction(ADDITION, tokenA, tokenB, amountTokenA, amountTokenB, 0, deadline, priceSlippage);
        emit NewLiquidityAddition(actionId, tokenA, tokenB, amountTokenA, amountTokenB, deadline, priceSlippage);

    }

    function createLiquidityRemoval(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 deadline,
        uint256 priceSlippage
    ) public payable returns (uint256) {
        require(msg.sender == dxdaoAvatar, 'AddLiquidityToAveragePrice: CALLER_NOT_DXDAO');
        require(msg.value == executionBountyWei.mul(periodSize), 'AddLiquidityToAveragePrice: BOUNTY NOT PROVIDED');

        address pair = DXswapLibrary.pairFor(factory, tokenA, tokenB);
        require(IERC20(pair).approve(router, liquidity), 'AddLiquidityToAveragePrice: INSUFFICIENT_ALLOWANCE_LIQUIDITY');

        uint256 actionId = createLiquidityAction(REMOVAL, tokenA, tokenB, 0, 0, liquidity,  deadline, priceSlippage);
        emit NewLiquidityRemoval(actionId, tokenA, tokenB, liquidity, deadline, priceSlippage);
    }

    function createLiquidityAction(
        uint8 action,
        address tokenA,
        address tokenB,
        uint256 amountTokenA,
        uint256 amountTokenB,
        uint256 liquidity,
        uint256 deadline,
        uint256 priceSlippage
    ) internal returns (uint256) {

      liquidityActionsIndex++;
      address pair = DXswapLibrary.pairFor(factory, tokenA, tokenB);

      liquidityActions.push(
          LiquidityAction({
              action: action,
              tokenA: tokenA,
              tokenB: tokenB,
              amountTokenA: amountTokenA,
              amountTokenB: amountTokenB,
              liquidity: liquidity,
              deadline: deadline,
              priceSlippage: priceSlippage,
              finishedTimestamp: 0,
              pair: pair,
              state: LiquidityActionState.CREATED
          })
      );

      liquidityActions[liquidityActionsIndex].state = LiquidityActionState.PRICE_OBERSERVATION;
      update(liquidityActionsIndex);

      return liquidityActionsIndex;
    }

    function update(uint256 _actionId) public payable {
        require(_actionId <= liquidityActionsIndex, 'AddLiquidityToAveragePrice: INVALID_ACTIONID');
        require(
            liquidityActions[_actionId].state == LiquidityActionState.PRICE_OBERSERVATION,
            'AddLiquidityToAveragePrice: STATE_NOT_OBSERVATION'
        );

        address pair = liquidityActions[_actionId].pair;

        // populate the array with empty observations (first call only)
        for (uint256 i = liquidityActions[_actionId].pairObservations[pair].length; i < granularity; i++) {
            liquidityActions[_actionId].pairObservations[pair].push();
        }

        // get the observation for the current period
        uint8 observationIndex = observationIndexOf(block.timestamp);
        Observation storage observation = liquidityActions[_actionId].pairObservations[pair][observationIndex];

        // we only want to commit updates once per period (i.e. windowSize / granularity)
        uint256 timeElapsed = block.timestamp - observation.timestamp;
        if (timeElapsed > periodSize) {
            (uint256 price0Cumulative, uint256 price1Cumulative, ) = DXswapOracleLibrary.currentCumulativePrices(pair);
            observation.timestamp = block.timestamp;
            observation.price0Cumulative = price0Cumulative;
            observation.price1Cumulative = price1Cumulative;
        }

        if (observationIndex == liquidityActions[_actionId].pairObservations[pair].length) {
            liquidityActions[_actionId].state = LiquidityActionState.PRICE_OBERSERVATION_FINISHED;
            liquidityActions[_actionId].finishedTimestamp = block.timestamp;
        }

        // send the bounty to the address that executed this function
        msg.sender.transfer(executionBountyWei);
    }

    function executeLiquidityAction(uint256 _actionId) public {
        require(_actionId <= liquidityActionsIndex, 'AddLiquidityToAveragePrice: INVALID_ACTIONID');
        require(
            liquidityActions[_actionId].state == LiquidityActionState.PRICE_OBERSERVATION_FINISHED,
            'AddLiquidityToAveragePrice: NOT_FINISHED'
        );
        require(
            block.timestamp <= liquidityActions[_actionId].finishedTimestamp.add(liquidityActions[_actionId].deadline),
            'AddLiquidityToAveragePrice: DEADLINE_EXCEEDED'
        );

        uint256 tokenAveragePriceA = consult(
            _actionId,
            liquidityActions[_actionId].tokenA,
            liquidityActions[_actionId].amountTokenA,
            liquidityActions[_actionId].tokenB
        );
        uint256 tokenAveragePriceB = consult(
            _actionId,
            liquidityActions[_actionId].tokenB,
            liquidityActions[_actionId].amountTokenB,
            liquidityActions[_actionId].tokenA
        );

        uint256 tokenMinA = tokenAveragePriceA.mul(1 - liquidityActions[_actionId].priceSlippage / 1000);
        uint256 tokenMinB = tokenAveragePriceB.mul(1 - liquidityActions[_actionId].priceSlippage / 1000);

        uint deadline = liquidityActions[_actionId].deadline;

        if(liquidityActions[_actionId].action == ADDITION) {

          require(
            IERC20(liquidityActions[_actionId].tokenA).balanceOf(address(this)) >=
                liquidityActions[_actionId].amountTokenA,
            'AddLiquidityToAveragePrice: INSUFFICIENT_BALANCE_TOKEN_A'
          );
          require(
              IERC20(liquidityActions[_actionId].tokenB).balanceOf(address(this)) >=
                  liquidityActions[_actionId].amountTokenB,
              'AddLiquidityToAveragePrice: INSUFFICIENT_BALANCE_TOKEN_B'
          );
          require(
              IERC20(liquidityActions[_actionId].tokenA).approve(router, liquidityActions[_actionId].amountTokenA),
              'AddLiquidityToAveragePrice: APPROVE_FAILED_TOKEN_A'
          );
          require(
              IERC20(liquidityActions[_actionId].tokenB).approve(router, liquidityActions[_actionId].amountTokenB),
              'AddLiquidityToAveragePrice: APPROVE_FAILED_TOKEN_B'
          );

          (uint256 amountA, uint256 amountB, uint256 liquidity) = IDXswapRouter(router).addLiquidity(
            liquidityActions[_actionId].tokenA,
            liquidityActions[_actionId].tokenB,
            liquidityActions[_actionId].amountTokenA,
            liquidityActions[_actionId].amountTokenB,
            tokenMinA,
            tokenMinB,
            dxdaoAvatar,
            deadline
          );

          liquidityActions[_actionId].state = LiquidityActionState.EXECUTED;
          emit ExecutedLiquidityAddition(_actionId, amountA, amountB, liquidity);

          // Send back tokenA Fragments
          IERC20(liquidityActions[_actionId].tokenA).transfer(
              dxdaoAvatar,
              liquidityActions[_actionId].amountTokenA.sub(amountA)
          );
          // Send back tokenB Fragments
          IERC20(liquidityActions[_actionId].tokenA).transfer(
              dxdaoAvatar,
              liquidityActions[_actionId].amountTokenB.sub(amountB)
          );

          /* Reset approval for router */
          IERC20(liquidityActions[_actionId].tokenA).approve(router, 0);
          IERC20(liquidityActions[_actionId].tokenB).approve(router, 0);

        } else if (liquidityActions[_actionId].action == REMOVAL) {

          (uint256 amountA, uint256 amountB) = IDXswapRouter(router).removeLiquidity(
            liquidityActions[_actionId].tokenA,
            liquidityActions[_actionId].tokenB,
            liquidityActions[_actionId].liquidity,
            tokenMinA,
            tokenMinB,
            dxdaoAvatar,
            deadline
          );
          emit ExecutedLiquidityRemoval(_actionId, amountA, amountB);
        }
        
    }

    // returns the index of the observation corresponding to the given timestamp
    function observationIndexOf(uint256 timestamp) public view returns (uint8 index) {
        uint256 epochPeriod = timestamp / periodSize;
        return uint8(epochPeriod % granularity);
    }

    // returns the observation from the oldest epoch (at the beginning of the window) relative to the current time
    function getFirstObservationInWindow(uint256 _actionId)
        private
        view
        returns (Observation storage firstObservation)
    {
        address pair = liquidityActions[_actionId].pair;
        uint8 observationIndex = observationIndexOf(block.timestamp);
        // no overflow issue. if observationIndex + 1 overflows, result is still zero.
        uint8 firstObservationIndex = (observationIndex + 1) % granularity;
        firstObservation = liquidityActions[_actionId].pairObservations[pair][firstObservationIndex];
    }

    // given the cumulative prices of the start and end of a period, and the length of the period, compute the average
    // price in terms of how much amount out is received for the amount in
    function computeAmountOut(
        uint256 priceCumulativeStart,
        uint256 priceCumulativeEnd,
        uint256 timeElapsed,
        uint256 amountIn
    ) private pure returns (uint256 amountOut) {
        // overflow is desired.
        FixedPoint.uq112x112 memory priceAverage = FixedPoint.uq112x112(
            uint224((priceCumulativeEnd - priceCumulativeStart) / timeElapsed)
        );
        amountOut = priceAverage.mul(amountIn).decode144();
    }

    // returns the amount out corresponding to the amount in for a given token using the moving average over the time
    // range [now - [windowSize, windowSize - periodSize * 2], now]
    // update must have been called for the bucket corresponding to timestamp `now - windowSize`
    function consult(
        uint _actionId,
        address tokenIn,
        uint256 amountIn,
        address tokenOut
    ) public view returns (uint256 amountOut) {
        address pair = liquidityActions[_actionId].pair;
        Observation storage firstObservation = getFirstObservationInWindow(_actionId);

        uint256 timeElapsed = block.timestamp - firstObservation.timestamp;
        require(timeElapsed <= windowSize, 'SlidingWindowOracle: MISSING_HISTORICAL_OBSERVATION');
        // should never happen.
        require(timeElapsed >= windowSize - periodSize * 2, 'SlidingWindowOracle: UNEXPECTED_TIME_ELAPSED');

        (uint256 price0Cumulative, uint256 price1Cumulative, ) = DXswapOracleLibrary.currentCumulativePrices(pair);
        (address token0, ) = DXswapLibrary.sortTokens(tokenIn, tokenOut);

        if (token0 == tokenIn) {
            return computeAmountOut(firstObservation.price0Cumulative, price0Cumulative, timeElapsed, amountIn);
        } else {
            return computeAmountOut(firstObservation.price1Cumulative, price1Cumulative, timeElapsed, amountIn);
        }
    }

    function emergencyERC20Withdraw(address token, uint256 amount) public {
        require(msg.sender == dxdaoAvatar, 'AddLiquidityToAveragePrice: CALLER_NOT_DXDAO');
        IERC20(token).transfer(dxdaoAvatar, amount);
    }

    function emergencyEthWithdraw(uint256 amount) public {
        require(msg.sender == dxdaoAvatar, 'AddLiquidityToAveragePrice: CALLER_NOT_DXDAO');
        dxdaoAvatar.transfer(amount);
    }
}
