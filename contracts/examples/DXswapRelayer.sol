pragma solidity =0.6.6;

import './OracleCreator.sol';
import './../interfaces/IDXswapFactory.sol';
import './../interfaces/IDXswapRouter.sol';
import './../libraries/TransferHelper.sol';
import './../interfaces/IERC20.sol';
import './../libraries/SafeMath.sol';
import './../libraries/DXswapLibrary.sol';

contract DXswapRelayer {
    using FixedPoint for *;
    using SafeMath for uint256;

    event NewOrder(
        uint256 indexed _orderId,
        uint8 indexed _action
    );

    event ExecutedPool(
        uint256 indexed _orderId,
        address _tokenA,
        address _tokenB,
        uint256 _amountTokenA,
        uint256 _amountTokenB,
        uint256 _liquidity
    );

    event ExecutedUnpool(
        uint256 indexed _orderId,
        address _tokenA,
        address _tokenB,
        uint256 _amountTokenA,
        uint256 _amountTokenB,
        uint256 _liquidity
    );

    event ExpiredOrderWithdrawn(
        uint256 indexed _orderId
    );

    struct Order {
        uint8 action; /* 1=liquidity provision; 2=liquidity removal; 3=swap */
        address tokenA;
        address tokenB;
        uint256 amountA;
        uint256 amountB;
        uint256 liquidity;
        uint256 priceTolerance;
        uint256 minReserve;
        address indirectPricingToken;
        uint256 deadline;
        uint8 maxWindows;
        uint256 executionBounty;
        uint256 oracleId;
        address factory;
        bool executed;
    }

    address payable public immutable owner;
    address public immutable dxSwapFactory;
    address public immutable dxSwapRouter;
    address public immutable uniswapFactory;
    address public immutable uniswapRouter;
    uint256 public immutable basewindowTime;

    uint256 public immutable PARTSPERMILLION = 1000000;
    uint8 public immutable PROVISION = 1;
    uint8 public immutable REMOVAL = 2;
    uint8 public immutable SWAP = 3;
    OracleCreator public oracleCreator;
    uint256 public orderCount;

    mapping(uint256 => Order) orders;

    constructor(
        address payable _owner,
        address _dxSwapFactory,
        address _dxSwapRouter,
        address _uniswapFactory,
        address _uniswapRouter,
        uint256 _basewindowTime
    ) public {
        owner = _owner;
        dxSwapFactory = _dxSwapFactory;
        dxSwapRouter = _dxSwapRouter;
        uniswapFactory = _uniswapFactory;
        uniswapRouter = _uniswapRouter;
        basewindowTime = _basewindowTime;
    }

    function orderLiquidityProvision(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 priceTolerance,
        uint256 minReserve,
        uint8 maxWindows,
        uint256 deadline,
        address indirectPricingToken,
        address factory
    ) external payable returns (uint256 orderIndex) {
        require(msg.sender == owner, 'DXswapRelayer: CALLER_NOT_OWNER');
        require(tokenA != tokenB, 'DXswapRelayer: INVALID_PAIR');
        require(tokenA < tokenB, 'DXswapRelayer: INVALID_TOKEN_ORDER');
        require(amountA > 0 && amountB > 0, 'DXswapRelayer: INVALID_LIQUIDITY_AMOUNT');
        require(priceTolerance <= PARTSPERMILLION, 'DXswapRelayer: INVALID_TOLERANCE');
        require(block.timestamp <= deadline, 'DXswapRelayer: DEADLINE_REACHED');

        if (tokenA == address(0)) {
            require(msg.value >= amountA, 'DXswapRelayer: INSUFFIENT_ETH');
            TransferHelper.safeTransferFrom(tokenB, owner, address(this), amountB);
        } else {
            TransferHelper.safeTransferFrom(tokenA, owner, address(this), amountA);
            TransferHelper.safeTransferFrom(tokenB, owner, address(this), amountB);
        }

        address pair = DXswapLibrary.pairFor(address(factory), tokenA, tokenB);
        (uint reserveA, uint reserveB,) = IDXswapPair(pair).getReserves();

        orderIndex = _getOrderIndex();
        orders[orderIndex] = Order(
            PROVISION,
            tokenA,
            tokenB,
            amountA,
            amountB,
            0,
            priceTolerance,
            minReserve,
            indirectPricingToken,
            deadline,
            maxWindows,
            0,
            0,
            factory,
            false
        );
        
        if (minReserve == 0 && reserveA == 0 && reserveB == 0) {
            /* For initial liquidity provision can be deployed immediatly */
            _pool(orderIndex, tokenA, tokenB, amountA, amountB, priceTolerance);
            orders[orderIndex].executed = true;
        } else {
            /* create oracle to calculate average price over time before providing liquidity*/
            uint256 windowTime = consultOracleParameters(amountA, amountB, reserveA, reserveB, maxWindows);
            uint256 oracleId = oracleCreator.createOracle(windowTime, pair, uint8(windowTime/basewindowTime), 0);
            orders[orderIndex].oracleId = oracleId;
            oracleCreator.update(oracleId);
        }
        emit NewOrder(orderIndex, PROVISION);
    }

    function orderLiquidityRemoval(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountA,
        uint256 amountB,
        uint256 priceTolerance,
        uint256 minReserve,
        uint8 maxWindows,
        uint256 deadline,
        address factory
    ) external payable returns (uint256 orderIndex) {
        require(msg.sender == owner, 'DXswapRelayer: CALLER_NOT_OWNER');
        require(tokenA != tokenB, 'DXswapRelayer: INVALID_PAIR');
        require(tokenA < tokenB, 'DXswapRelayer: INVALID_TOKEN_ORDER');
        require(amountA > 0 && amountB > 0 && liquidity > 0, 'DXswapRelayer: INVALID_LIQUIDITY_AMOUNT');
        require(priceTolerance <= PARTSPERMILLION, 'DXswapRelayer: INVALID_TOLERANCE');
        require(block.timestamp <= deadline, 'DXswapRelayer: DEADLINE_REACHED');
        
        orderIndex = _getOrderIndex();
        orders[orderIndex] = Order(
            REMOVAL,
            tokenA,
            tokenB,
            amountA,
            amountB,
            liquidity,
            priceTolerance,
            minReserve,
            address(0),
            deadline,
            maxWindows,
            0,
            0,
            factory,
            false
        );

        address pair = DXswapLibrary.pairFor(address(factory), tokenA, tokenB);
        (uint reserveA, uint reserveB,) = IDXswapPair(pair).getReserves();
        uint256 windowTime = consultOracleParameters(amountA, amountB, reserveA, reserveB, maxWindows);
        uint256 oracleId = oracleCreator.createOracle(windowTime, pair, uint8(windowTime/basewindowTime), 0);
        orders[orderIndex].oracleId = oracleId;
        oracleCreator.update(oracleId);

        emit NewOrder(orderIndex, REMOVAL);
        return _getOrderIndex();
    }
    
    /**
     * @dev Execute liquidity provision after price observation.
     * @param orderId to reference the commitment.
     */
    function executeOrder(uint256 orderId) external {
        require(orderId <= orderCount && orderId != 0, 'DXswapRelayer: INVALID_COMMITMENT');
        require(orders[orderId].executed == false, 'DXswapRelayer: COMMITMENT_EXECUTED');
        require(oracleCreator.getOracleStatus(orders[orderId].oracleId) == true, 'DXswapRelayer: OBSERVATION_RUNNING');
        require(block.timestamp <= orders[orderId].deadline, 'DXswapRelayer: DEADLINE_REACHED');

        address tokenA = orders[orderId].tokenA;
        address tokenB = orders[orderId].tokenB;
        uint256 amountA = oracleCreator.consult(orders[orderId].oracleId, tokenA, orders[orderId].amountA, tokenB);
        uint256 amountB = oracleCreator.consult(orders[orderId].oracleId, tokenB, orders[orderId].amountB, tokenA);

        if(orders[orderId].action == PROVISION){
          _pool(orderId, tokenA, tokenB, amountA, amountB, orders[orderId].priceTolerance);
        } else if (orders[orderId].action == REMOVAL){
          address pair = DXswapLibrary.pairFor(address(dxSwapFactory), tokenA, tokenB);
          _unpool(orderId, tokenA, tokenB, pair, orders[orderId].liquidity, amountA, amountB, orders[orderId].priceTolerance);
        }
        orders[orderId].executed = true;
        
    }
    
    function _pool(
        uint256 _orderId,
        address _tokenA,
        address _tokenB,
        uint256 _amountA,
        uint256 _amountB,
        uint256 _priceTolerance
    ) internal {
        uint256 minA = _amountA.sub(_amountA.mul(_priceTolerance) / PARTSPERMILLION);
        uint256 minB = _amountB.sub(_amountB.mul(_priceTolerance) / PARTSPERMILLION);
        uint256 amountA;
        uint256 amountB;
        uint256 liquidity;

        if (_tokenA != address(0) && _tokenB != address(0)) {
            TransferHelper.safeApprove(_tokenA, dxSwapRouter, _amountA);
            TransferHelper.safeApprove(_tokenB, dxSwapRouter, _amountB);
            (amountA, amountB, liquidity) = IDXswapRouter(dxSwapRouter).addLiquidity(
                _tokenA,
                _tokenB,
                _amountA,
                _amountB,
                minA,
                minB,
                owner,
                block.timestamp
            );
        } else {
            TransferHelper.safeApprove(_tokenB, dxSwapRouter, _amountB);
            (amountB, amountA, liquidity) = IDXswapRouter(dxSwapRouter).addLiquidityETH{
                value: _amountA
            }(_tokenB, _amountB, minB, minA, owner, block.timestamp);
        }
        emit ExecutedPool(_orderId, _tokenA, _tokenB, amountA, amountB, liquidity);
    }

    function _unpool(
        uint256 _orderId,
        address _tokenA,
        address _tokenB,
        address _pair,
        uint256 _liquidity,
        uint256 _amountA,
        uint256 _amountB,
        uint256 _priceTolerance
    ) internal {
        uint256 minA = _amountA.sub(_amountA.mul(_priceTolerance) / PARTSPERMILLION);
        uint256 minB = _amountB.sub(_amountB.mul(_priceTolerance) / PARTSPERMILLION);
        uint amountA;
        uint amountB;

        if (_tokenA != address(0) && _tokenB != address(0)) {
            TransferHelper.safeApprove(_pair, dxSwapRouter, _liquidity);
            (amountA, amountB) = IDXswapRouter(dxSwapRouter).removeLiquidity(
                _tokenA,
                _tokenB,
                _liquidity,
                minA,
                minB,
                owner,
                block.timestamp
            );
            emit ExecutedUnpool(_orderId, _tokenA, _tokenB, amountA, amountB, _liquidity);
        } else {
            TransferHelper.safeApprove(_tokenB, dxSwapRouter, _amountB);
            (amountB, amountA) = IDXswapRouter(dxSwapRouter).removeLiquidityETH(
              _tokenB,
              _liquidity,
              minB,
              minA,
              owner,
              block.timestamp
            );
        }
        emit ExecutedUnpool(_orderId, _tokenA, _tokenB, amountA, amountB, _liquidity);
    }

    /**
     * @dev Withdraw an timed out order.
     * @param orderId to reference the commitment.
     */
    function withdrawExpiredCommitment(uint256 orderId) external {
        require(block.timestamp > orders[orderId].deadline, 'DXswapRelayer: DEADLINE_NOT_REACHED');
        require(orders[orderId].executed == false, 'DXswapRelayer: COMMITMENT_EXECUTED');
        address tokenA = orders[orderId].tokenA;
        address tokenB = orders[orderId].tokenB;
        uint256 amountA = orders[orderId].amountA;
        uint256 amountB = orders[orderId].amountB;
        orders[orderId].executed = true;

        if (tokenA == address(0)) {
            ETHWithdraw(amountA);
            ERC20Withdraw(tokenB,amountB);
        } else {
            ERC20Withdraw(tokenA,amountA);
            ERC20Withdraw(tokenB,amountB);
        }
        emit ExpiredOrderWithdrawn(orderId);
    }

    function _getOrderIndex() internal returns(uint256 orderId){
        orderCount++;
        orderId = orderCount;
    }

    function consultOracleParameters(
        uint256 amountA,
        uint256 amountB,
        uint256 reserveA,
        uint256 reserveB,
        uint256 maxWindows
    ) internal view returns (uint256 windowTime) {
        uint256 poolStake = (amountA.add(amountB)) / ((reserveA.add(reserveB))).mul(PARTSPERMILLION);
        // poolStake: 0.1% = 100; 1=1000; 10% = 10000;
        uint256 windows;
        if(poolStake < 100) {
          windows = 3;
        } else if (poolStake >= 100 && poolStake < 250){
          windows = 4;
        } else if (poolStake >= 250 && poolStake < 500){
          windows = 5;
        } else if (poolStake >= 500 && poolStake < 1000){
          windows = 6;
        } else if (poolStake >= 1000 && poolStake < 3000){
          windows = 7;
        } else {
          windows = 10;
        }
        windows = windows <= maxWindows ? windows : maxWindows;
        windowTime = windows.mul(basewindowTime);
    }

    function ERC20Withdraw(address token, uint256 amount) public {
        require(msg.sender == owner, 'DXswapRelayer: CALLER_NOT_OWNER');
        TransferHelper.safeTransfer(token, owner, amount);
    }

    function ETHWithdraw(uint256 amount) public {
        require(msg.sender == owner, 'DXswapRelayer: CALLER_NOT_OWNER');
        TransferHelper.safeTransferETH(owner, amount);
    }
}
