pragma solidity =0.6.6;

import './../libraries/TransferHelper.sol';
import './../libraries/DXswapOracleLibrary.sol';
import './../libraries/DXswapLibrary.sol';
import './../libraries/SafeMath.sol';

contract OracleCreator {    
    using FixedPoint for *;
    using SafeMath for uint256;

    event OracleCreated(
        uint256 _oracleIndex,
        address _pair,
        uint256 _windowTime,
        uint8 _granularity,
        uint256 _periodSize,
        uint256 _executionBountyWei
    );

    event OracleExecuted(
        uint256 _oracleIndex
    );

    struct Oracle{
      uint256 windowTime;
      address pair;
      uint8 granularity;
      uint256 periodSize;
      uint256 executionBountyWei;
      uint256 finishedTimestamp;
      bool observationFinished;
    }

    struct Observation {
      uint256 timestamp;
      uint256 price0Cumulative;
      uint256 price1Cumulative;
    }

    address public immutable DXswapRelayer;
    mapping(uint256 => Oracle) public oracles;
    uint256 public oraclesIndex;
    mapping (uint256 => Observation[]) public oracleObservations;
    
    constructor(
        address payable _DXswapRelayer
    ) public {
        DXswapRelayer = _DXswapRelayer;
    }

    function createOracle(
        uint256 windowTime,
        address pair,
        uint8 granularity,
        uint256 executionBountyWei
    ) public payable returns (uint256 oracleId) {
        uint256 periodSize;
        require(msg.sender == DXswapRelayer, 'DXliquidityRelay: CALLER_NOT_RELAYER');
        require(granularity > 1, 'DXliquidityRelay: GRANULARITY');
        require(
            (periodSize = windowTime / granularity) * granularity == windowTime,
            'DXliquidityRelay: WINDOW_NOT_EVENLY_DIVISIBLE'
        );
        require(msg.value >= executionBountyWei.mul(periodSize), 'DXliquidityRelay: INVALID_BOUNTY');

        oracles[oraclesIndex] = Oracle(
            windowTime,
            pair,
            granularity,
            periodSize,
            executionBountyWei,
            0,
            false
        );

      oracleId = oraclesIndex;
      emit OracleCreated(oracleId, pair, windowTime, granularity, periodSize, executionBountyWei);
      oraclesIndex++;
    }

    function update(uint256 _oracleIndex) public payable {
        require(_oracleIndex <= oraclesIndex, 'DXliquidityRelay: INVALID_oracleIndex');
        require(
            oracles[_oracleIndex].observationFinished == false,
            'DXliquidityRelay: OBSERVATION_FINISHED'
        );

        address pair = oracles[_oracleIndex].pair;

        // populate the array with empty observations (first call only)
        for (uint256 i = oracleObservations[_oracleIndex].length; i < oracles[_oracleIndex].granularity; i++) {
            oracleObservations[_oracleIndex].push();
        }

        // get the observation for the current period
        uint8 observationIndex = observationIndexOf(_oracleIndex, block.timestamp);
        Observation storage observation = oracleObservations[_oracleIndex][observationIndex];

        // we only want to commit updates once per period (i.e. windowTime / granularity)
        uint256 timeElapsed = block.timestamp - observation.timestamp;
        if (timeElapsed > oracles[_oracleIndex].periodSize) {
            (uint256 price0Cumulative, uint256 price1Cumulative, ) = DXswapOracleLibrary.currentCumulativePrices(pair);
            observation.timestamp = block.timestamp;
            observation.price0Cumulative = price0Cumulative;
            observation.price1Cumulative = price1Cumulative;
        }

        if (observationIndex == oracleObservations[_oracleIndex].length) {
            oracles[_oracleIndex].observationFinished = true;
            oracles[_oracleIndex].finishedTimestamp = block.timestamp;
            emit OracleExecuted(_oracleIndex);
        }

        // send the bounty to msg.sender
        TransferHelper.safeTransferETH(msg.sender, oracles[_oracleIndex].executionBountyWei);
    }

    // returns the index of the observation corresponding to the given timestamp
    function observationIndexOf(uint oracleId, uint256 timestamp) public view returns (uint8 index) {
        uint256 epochPeriod = timestamp / oracles[oracleId].periodSize;
        return uint8(epochPeriod % oracles[oracleId].granularity);
    }

    // returns the observation from the oldest epoch (at the beginning of the window) relative to the current time
    function getFirstObservationInWindow(uint256 _oracleIndex)
        private
        view
        returns (Observation storage firstObservation)
    {
        uint8 observationIndex = observationIndexOf(_oracleIndex, block.timestamp);
        // no overflow issue. if observationIndex + 1 overflows, result is still zero.
        uint8 firstObservationIndex = (observationIndex + 1) % oracles[_oracleIndex].granularity;
        firstObservation = oracleObservations[_oracleIndex][firstObservationIndex];
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
    // range [now - [windowTime, windowTime - periodSize * 2], now]
    // update must have been called for the bucket corresponding to timestamp `now - windowTime`
    function consult(
        uint _oracleIndex,
        address tokenIn,
        uint256 amountIn,
        address tokenOut
    ) public view returns (uint256 amountOut) {
        address pair = oracles[_oracleIndex].pair;
        Observation storage firstObservation = getFirstObservationInWindow(_oracleIndex);

        uint256 timeElapsed = block.timestamp - firstObservation.timestamp;
        require(timeElapsed <= oracles[_oracleIndex].windowTime, 'DXliquidityRelay: MISSING_HISTORICAL_OBSERVATION');
        // should never happen.
        require(timeElapsed >= oracles[_oracleIndex].windowTime - oracles[_oracleIndex].periodSize * 2, 'DXliquidityRelay: UNEXPECTED_TIME_ELAPSED');

        (uint256 price0Cumulative, uint256 price1Cumulative, ) = DXswapOracleLibrary.currentCumulativePrices(pair);
        (address token0, ) = DXswapLibrary.sortTokens(tokenIn, tokenOut);

        if (token0 == tokenIn) {
            return computeAmountOut(firstObservation.price0Cumulative, price0Cumulative, timeElapsed, amountIn);
        } else {
            return computeAmountOut(firstObservation.price1Cumulative, price1Cumulative, timeElapsed, amountIn);
        }
    }

    function getOracleStatus(uint256 oracleID) external view returns(bool observationFinished){
      return oracles[oracleID].observationFinished;
    }

}