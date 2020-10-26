pragma solidity =0.6.6;

import './OracleCreator.sol';
import './../interfaces/IDXswapFactory.sol';
import './../interfaces/IDXswapRouter.sol';
import './../libraries/TransferHelper.sol';
import './../interfaces/IERC20.sol';
import './../libraries/SafeMath.sol';
import './../libraries/DXswapLibrary.sol';

contract DXswapRelayer {
    using SafeMath for uint256;

    event NewOrder(
        uint256 indexed _orderIndex,
        uint8 indexed _action
    );

    event ExecutedOrder(
        uint256 indexed _orderIndex
    );

    event WithdrawnExpiredOrder(
        uint256 indexed _orderIndex
    );

    struct Order {
        uint8 action; // 1=provision; 2=removal
        address tokenA;
        address tokenB;
        uint256 amountA;
        uint256 amountB;
        uint256 liquidity;
        uint256 priceTolerance;
        uint256 minReserveA;
        uint256 minReserveB;
        address oraclePair;
        uint256 deadline;
        uint256 maxWindowTime;
        uint256 oracleId;
        address factory;
        bool executed;
    }

    uint256 public immutable GAS_ORACLE_UPDATE = 70000;
    uint256 public immutable PARTS_PER_MILLION = 1000000;
    uint256 public immutable BOUNTY = 0.01 ether;
    uint8 public immutable PROVISION = 1;
    uint8 public immutable REMOVAL = 2;

    address payable public immutable owner;
    address public immutable dxSwapFactory;
    address public immutable dxSwapRouter;
    address public immutable uniswapFactory;
    address public immutable uniswapRouter;

    OracleCreator public oracleCreator;
    uint256 public orderCount;
    mapping(uint256 => Order) orders;

    constructor(
        address payable _owner,
        address _dxSwapFactory,
        address _dxSwapRouter,
        address _uniswapFactory,
        address _uniswapRouter,
        OracleCreator _oracleCreater
    ) public {
        owner = _owner;
        dxSwapFactory = _dxSwapFactory;
        dxSwapRouter = _dxSwapRouter;
        uniswapFactory = _uniswapFactory;
        uniswapRouter = _uniswapRouter;
        oracleCreator = _oracleCreater;
    }

    function orderLiquidityProvision(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 priceTolerance,
        uint256 minReserveA,
        uint256 minReserveB,
        uint256 maxWindowTime,
        uint256 deadline,
        address factory
    ) external payable returns (uint256 orderIndex) {
        require(factory == dxSwapFactory || factory == uniswapFactory, 'DXswapRelayer: INVALID_FACTORY');
        require(msg.sender == owner, 'DXswapRelayer: CALLER_NOT_OWNER');
        require(tokenA != tokenB, 'DXswapRelayer: INVALID_PAIR');
        require(tokenA < tokenB, 'DXswapRelayer: INVALID_TOKEN_ORDER');
        require(amountA > 0 && amountB > 0, 'DXswapRelayer: INVALID_TOKEN_AMOUNT');
        require(priceTolerance <= PARTS_PER_MILLION, 'DXswapRelayer: INVALID_TOLERANCE');
        require(block.timestamp <= deadline, 'DXswapRelayer: DEADLINE_REACHED');

        if (tokenA == address(0)) {
            require(msg.value >= amountA, 'DXswapRelayer: INSUFFIENT_ETH');
            TransferHelper.safeTransferFrom(tokenB, owner, address(this), amountB);
        } else {
            TransferHelper.safeTransferFrom(tokenA, owner, address(this), amountA);
            TransferHelper.safeTransferFrom(tokenB, owner, address(this), amountB);
        }

        address pair = _pair(tokenA, tokenB, factory);
        orderIndex = _getOrderIndex();
        orders[orderIndex] = Order(
            PROVISION,
            tokenA,
            tokenB,
            amountA,
            amountB,
            0,
            priceTolerance,
            minReserveA,
            minReserveB,
            pair,
            deadline,
            maxWindowTime,
            0,
            factory,
            false
        );
        emit NewOrder(orderIndex, PROVISION);

        (uint reserveA, uint reserveB,) = IDXswapPair(pair).getReserves();
        if (minReserveA == 0 && minReserveB == 0 && reserveA == 0 && reserveB == 0) {
            /* For initial liquidity provision can be transfered immediatly */
            orders[orderIndex].executed = true;
            _pool(tokenA, tokenB, amountA, amountB, priceTolerance);
            emit ExecutedOrder(orderIndex);
        } else {
            /* create oracle to calculate average price over time before providing liquidity*/
            uint256 windowTime = consultOracleParameters(amountA, amountB, reserveA, reserveB, maxWindowTime);
            orders[orderIndex].oracleId = oracleCreator.createOracle(windowTime, factory, pair);
        }
    }

    function orderLiquidityRemoval(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountA,
        uint256 amountB,
        uint256 priceTolerance,
        uint256 minReserveA,
        uint256 minReserveB,
        uint256 maxWindowTime,
        uint256 deadline,
        address factory
    ) external returns (uint256 orderIndex) {
        require(factory == dxSwapFactory || factory == uniswapFactory, 'DXswapRelayer: INVALID_FACTORY');
        require(msg.sender == owner, 'DXswapRelayer: CALLER_NOT_OWNER');
        require(tokenA != tokenB, 'DXswapRelayer: INVALID_PAIR');
        require(tokenA < tokenB, 'DXswapRelayer: INVALID_TOKEN_ORDER');
        require(amountA > 0 && amountB > 0 && liquidity > 0, 'DXswapRelayer: INVALID_LIQUIDITY_AMOUNT');
        require(priceTolerance <= PARTS_PER_MILLION, 'DXswapRelayer: INVALID_TOLERANCE');
        require(block.timestamp <= deadline, 'DXswapRelayer: DEADLINE_REACHED');

        address pair = _pair(factory, tokenA, tokenB);
        orderIndex = _getOrderIndex();
        orders[orderIndex] = Order(
            REMOVAL,
            tokenA,
            tokenB,
            amountA,
            amountB,
            liquidity,
            priceTolerance,
            minReserveA,
            minReserveB,
            pair,
            deadline,
            maxWindowTime,
            0,
            factory,
            false
        );

        address dxSwapPair = DXswapLibrary.pairFor(address(dxSwapFactory), tokenA, tokenB);
        (uint reserveA, uint reserveB,) = IDXswapPair(dxSwapPair).getReserves();
        uint256 windowTime = consultOracleParameters(amountA, amountB, reserveA, reserveB, maxWindowTime);
        orders[orderIndex].oracleId = oracleCreator.createOracle(windowTime, factory, pair);
        emit NewOrder(orderIndex, REMOVAL);
    }
    
    function executeOrder(uint256 orderIndex) external {
        require(orderIndex <= orderCount && orderIndex != 0, 'DXswapRelayer: INVALID_ORDER');
        require(orders[orderIndex].executed == false, 'DXswapRelayer: ORDER_EXECUTED');
        require(oracleCreator.isOracleFinalized(orders[orderIndex].oracleId) , 'DXswapRelayer: OBSERVATION_RUNNING');
        require(block.timestamp <= orders[orderIndex].deadline, 'DXswapRelayer: DEADLINE_REACHED');

        address tokenA = orders[orderIndex].tokenA;
        address tokenB = orders[orderIndex].tokenB;
        uint256 amountA;
        if(tokenA == address(0)){
          amountA = oracleCreator.consult(
            orders[orderIndex].oracleId,
            IDXswapRouter(dxSwapRouter).WETH(),
            orders[orderIndex].amountA
          );
        } else {
          amountA = oracleCreator.consult(
            orders[orderIndex].oracleId,
            tokenA,
            orders[orderIndex].amountA
          );
        }
        uint256 amountB = oracleCreator.consult(orders[orderIndex].oracleId, tokenB, orders[orderIndex].amountB);

        orders[orderIndex].executed = true;
        if(orders[orderIndex].action == PROVISION){
          _pool(tokenA, tokenB, amountA, amountB, orders[orderIndex].priceTolerance);
        } else if (orders[orderIndex].action == REMOVAL){
          address pair = _pair(tokenA, tokenB, dxSwapFactory);
          _unpool(
            tokenA, 
            tokenB, 
            pair, 
            orders[orderIndex].liquidity,
            amountA, 
            amountB,
            orders[orderIndex].priceTolerance
          );
        }
        emit ExecutedOrder(orderIndex);
    }
    
    function _pool(
        address _tokenA,
        address _tokenB,
        uint256 _amountA,
        uint256 _amountB,
        uint256 _priceTolerance
    ) internal {
        uint256 minA = _amountA.sub(_amountA.mul(_priceTolerance) / PARTS_PER_MILLION);
        uint256 minB = _amountB.sub(_amountB.mul(_priceTolerance) / PARTS_PER_MILLION);
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
    }

    function _unpool(
        address _tokenA,
        address _tokenB,
        address _pair,
        uint256 _liquidity,
        uint256 _amountA,
        uint256 _amountB,
        uint256 _priceTolerance
    ) internal {
        uint256 minA = _amountA.sub(_amountA.mul(_priceTolerance) / PARTS_PER_MILLION);
        uint256 minB = _amountB.sub(_amountB.mul(_priceTolerance) / PARTS_PER_MILLION);
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
    }

    function withdrawExpiredOrder(uint256 orderIndex) external {
        require(block.timestamp > orders[orderIndex].deadline, 'DXswapRelayer: DEADLINE_NOT_REACHED');
        require(orders[orderIndex].executed == false, 'DXswapRelayer: ORDER_EXECUTED');
        address tokenA = orders[orderIndex].tokenA;
        address tokenB = orders[orderIndex].tokenB;
        uint256 amountA = orders[orderIndex].amountA;
        uint256 amountB = orders[orderIndex].amountB;
        orders[orderIndex].executed = true;

        if (tokenA == address(0)) {
            TransferHelper.safeTransferETH(owner, amountA);
            TransferHelper.safeTransfer(tokenB, owner, amountB);
        } else {
            TransferHelper.safeTransfer(tokenA, owner, amountA);
            TransferHelper.safeTransfer(tokenB, owner, amountB);
        }
        emit WithdrawnExpiredOrder(orderIndex);
    }
    
    function updateOracle(uint256 _orderIndex) external {
      require(block.timestamp < orders[_orderIndex].deadline, 'DXswapRelayer: DEADLINE_REACHED');
      require(address(this).balance >= GAS_ORACLE_UPDATE.mul(tx.gasprice).add(BOUNTY), 'DXswapRelayer: INSUFFICIENT_BALANCE');
      (uint reserveA, uint reserveB,) = IDXswapPair(orders[_orderIndex].oraclePair).getReserves();
      require(
        reserveA >= orders[_orderIndex].minReserveA && reserveB >= orders[_orderIndex].minReserveB,
        'DXswapRelayer: RESERVE_TO_LOW'
      );
      oracleCreator.update(orders[_orderIndex].oracleId);
      TransferHelper.safeTransferETH(msg.sender, GAS_ORACLE_UPDATE.mul(tx.gasprice).add(BOUNTY));
    }

    function consultOracleParameters(
        uint256 amountA,
        uint256 amountB,
        uint256 reserveA,
        uint256 reserveB,
        uint256 maxWindowTime
    ) internal view returns (uint256 windowTime) {
        if(reserveA > 0 && reserveB > 0){
            uint256 poolStake = (amountA.add(amountB) / reserveA.add(reserveB)).mul(PARTS_PER_MILLION);
            // poolStake: 0.1% = 1000; 1=10000; 10% = 100000;
            if(poolStake < 1000) {
              windowTime = 30;
            } else if (poolStake >= 1000 && poolStake < 2500){
              windowTime = 60;
            } else if (poolStake >= 2500 && poolStake < 5000){
              windowTime = 90;
            } else if (poolStake >= 5000 && poolStake < 10000){
              windowTime = 120;
            } else {
              windowTime = 150;
            }
            windowTime = windowTime <= maxWindowTime ? windowTime : maxWindowTime;
        } else {
          windowTime = maxWindowTime;
        }
    }

    function _pair(address _token1, address _token2, address _factory) internal view returns (address pair) {
        address token1;
        address token2;
        if(_factory == dxSwapFactory){
          token1 = _token1 == address(0) ? IDXswapRouter(dxSwapRouter).WETH() : _token1;
          token2 = _token2 == address(0) ? IDXswapRouter(dxSwapRouter).WETH() : _token2;
        } else if(_factory == uniswapFactory) {
          token1 = _token1 == address(0) ? IDXswapRouter(uniswapRouter).WETH() : _token1;
          token2 = _token2 == address(0) ? IDXswapRouter(uniswapRouter).WETH() : _token2;
        }
        pair = IDXswapFactory(_factory).getPair(token1, token2);
    }

    function _getOrderIndex() internal returns(uint256 orderIndex){
        orderCount++;
        orderIndex = orderCount;
    }

    function ERC20Withdraw(address token, uint256 amount) external {
        require(msg.sender == owner, 'DXswapRelayer: CALLER_NOT_OWNER');
        TransferHelper.safeTransfer(token, owner, amount);
    }

    function ETHWithdraw(uint256 amount) external {
        require(msg.sender == owner, 'DXswapRelayer: CALLER_NOT_OWNER');
        TransferHelper.safeTransferETH(owner, amount);
    }

    receive() external payable {}
}