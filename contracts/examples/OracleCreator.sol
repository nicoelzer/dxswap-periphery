pragma solidity =0.6.6;
pragma experimental ABIEncoderV2;

import './../libraries/TransferHelper.sol';
import './../libraries/DXswapOracleLibrary.sol';
import './../libraries/DXswapLibrary.sol';
import './../libraries/SafeMath.sol';

contract OracleCreator {
    using FixedPoint for *;
    using SafeMath for uint256;

    event OracleCreated(
        uint256 indexed _oracleIndex,
        address indexed _factory,
        address indexed _pair,
        uint256 windowTime
    );

    struct Oracle{
      uint256 windowTime;
      address factory;
      address token0;
      address token1;
      IDXswapPair pair;
      uint32 blockTimestampLast;
      uint256 price0CumulativeLast;
      uint256 price1CumulativeLast;
      FixedPoint.uq112x112 price0Average;
      FixedPoint.uq112x112 price1Average;
      uint256 observationsCount;
      address owner;
    }

    mapping(uint256 => Oracle) public oracles;
    uint256 public oraclesIndex;

    function createOracle(
        uint256 windowTime,
        address factory,
        address pair
    ) public returns (uint256 oracleId) {
      address token0 = IDXswapPair(pair).token0();
      address token1 = IDXswapPair(pair).token1();
      oracles[oraclesIndex] = Oracle(
        windowTime,
        factory,
        token0,
        token1,
        IDXswapPair(pair),
        0,
        0,
        0,
        FixedPoint.uq112x112(0),
        FixedPoint.uq112x112(0),
        0,
        msg.sender
      );
      oracleId = oraclesIndex;
      oraclesIndex++;
      emit OracleCreated(oracleId, factory, pair, windowTime);
    }

    function update(uint256 oracleIndex) public {
        require(msg.sender == oracles[oracleIndex].owner, 'OracleCreator: CALLER_NOT_OWNER');
        require(oracles[oracleIndex].observationsCount < 2, 'OracleCreator: FINISHED_OBERSERVATION');
        (uint price0Cumulative, uint price1Cumulative, uint32 blockTimestamp) =
            DXswapOracleLibrary.currentCumulativePrices(address(oracles[oracleIndex].pair));
        uint32 timeElapsed = blockTimestamp - oracles[oracleIndex].blockTimestampLast; // overflow is desired

        // ensure that at least one full period has passed since the last update, first update can be executed immediately
        require(
          oracles[oracleIndex].observationsCount == 0 || timeElapsed >= oracles[oracleIndex].windowTime, 
          'OracleCreator: PERIOD_NOT_ELAPSED'
        );

        // overflow is desired, casting never truncates
        // cumulative price is in (uq112x112 price * seconds) units so we simply wrap it after division by time elapsed
        oracles[oracleIndex].price0Average = FixedPoint.uq112x112(
          uint224((price0Cumulative - oracles[oracleIndex].price0CumulativeLast) / timeElapsed)
        );
        oracles[oracleIndex].price1Average = FixedPoint.uq112x112(
          uint224((price1Cumulative - oracles[oracleIndex].price1CumulativeLast) / timeElapsed)
        );

        oracles[oracleIndex].price0CumulativeLast = price0Cumulative;
        oracles[oracleIndex].price1CumulativeLast = price1Cumulative;
        oracles[oracleIndex].blockTimestampLast = blockTimestamp;
        oracles[oracleIndex].observationsCount++;
    }

    // note this will always return 0 before update has been called successfully for the first time.
    function consult(uint256 oracleIndex, address token, uint amountIn) external view returns (uint amountOut) {
        if (token == oracles[oracleIndex].token0) {
            amountOut = oracles[oracleIndex].price0Average.mul(amountIn).decode144();
        } else {
            require(token == oracles[oracleIndex].token1, 'OracleCreator: INVALID_TOKEN');
            amountOut = oracles[oracleIndex].price1Average.mul(amountIn).decode144();
        }
    }

    function isOracleFinalized(uint256 oracleIndex) external view returns (bool){
      return oracles[oracleIndex].observationsCount == 2 ? true : false; 
    }

}