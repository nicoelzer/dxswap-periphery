pragma solidity =0.6.6;

import './OracleCreator.sol';
import './../interfaces/IDXswapFactory.sol';
import './../interfaces/IDXswapRouter.sol';
import './../libraries/TransferHelper.sol';
import './../interfaces/IERC20.sol';
import './../libraries/SafeMath.sol';

contract DXswapRelayer {
    using FixedPoint for *;
    using SafeMath for uint256;

    event NewOrder(
        uint256 _orderId,
        uint8 _action,
        address _tokenA,
        address _tokenB,
        uint256 _amountA,
        uint256 _amountB,
        uint256 _priceTolerance,
        uint256 _minReserveA,
        uint256 _minReserveB,
        uint256 _deadline,
        uint8 _maxWindows,
        uint256 _executionBounty,
        uint256 _oracleId,
        address _factory
    );

    event OrderTerminated(
        uint256 _orderId
    );

    event ExecutedPool(
        address _tokenA,
        address _tokenB,
        uint256 _amountTokenA,
        uint256 _amountTokenB,
        uint256 _liquidity
    );

    event ExecutedUnpool(
        address _tokenA,
        address _tokenB,
        uint256 _amountTokenA,
        uint256 _amountTokenB,
        uint256 _liquidity
    );

    struct Order {
        uint8 action; /* 1=liquidity provision; 2=liquidity removal; 3=swap */
        address tokenA;
        address tokenB;
        uint256 amountA;
        uint256 amountB;
        uint256 priceTolerance;
        uint256 minReserveA;
        uint256 minReserveB;
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

    uint256 public immutable PartsPerMillion = 1000000;
    uint8 public immutable PROVISION = 1;
    uint8 public immutable REMOVAL = 2;
    uint8 public immutable SWAP = 3;
    OracleCreator oracleCreator;
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
        uint256 minReserveA,
        uint256 minReserveB,
        uint8 maxWindows,
        uint256 executionBounty,
        uint256 deadline
    ) external payable returns (uint256 orderId) {
        require(msg.sender == owner, 'DXliquidityRelay: CALLER_NOT_OWNER');
        require(tokenA != tokenB, 'DXliquidityRelay: INVALID_PAIR');
        require(amountA > 0 && amountB > 0, 'DXliquidityRelay: INVALID_LIQUIDITY_AMOUNT');
        require(priceTolerance <= PartsPerMillion, 'DXliquidityRelay: INVALID_TOLERANCE');
        require(maxWindows <= 255, 'DXliquidityRelay: INVALID_MAXWINDOWS');
        require(block.timestamp <= deadline, 'DXliquidityRelay: DEADLINE_REACHED');

        if (tokenA == address(0) || tokenB == address(0)) {
            address token = tokenA == address(0) ? tokenB : tokenA;
            uint256 valueETH = tokenA == address(0) ? amountA : amountB;
            uint256 amountToken = tokenA == address(0) ? amountB : amountA;
            require(msg.value >= valueETH, 'DXliquidityRelay: INSUFFIENT_ETH');
            TransferHelper.safeTransferFrom(token, owner, address(this), amountToken);
        } else {
            TransferHelper.safeTransferFrom(tokenA, owner, address(this), amountA);
            TransferHelper.safeTransferFrom(tokenB, owner, address(this), amountB);
        }
        
        orders[orderId] = Order(
            PROVISION,
            tokenA,
            tokenB,
            amountA,
            amountB,
            priceTolerance,
            minReserveA,
            minReserveB,
            deadline,
            maxWindows,
            executionBounty,
            0,
            address(0),
            false
        );
        return _getOrderIndex();
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
        uint8 maxWindows,
        uint256 executionBounty,
        uint256 deadline
    ) external payable returns (uint256 orderId) {
        require(msg.sender == owner, 'DXliquidityRelay: CALLER_NOT_OWNER');
        require(tokenA != tokenB, 'DXliquidityRelay: INVALID_PAIR');
        require(amountA > 0 && amountB > 0 && liquidity > 0, 'DXliquidityRelay: INVALID_LIQUIDITY_AMOUNT');
        require(priceTolerance <= PartsPerMillion, 'DXliquidityRelay: INVALID_TOLERANCE');
        require(maxWindows <= 255, 'DXliquidityRelay: INVALID_MAXWINDOWS');
        require(block.timestamp <= deadline, 'DXliquidityRelay: DEADLINE_REACHED');
        
        orders[orderId] = Order(
            REMOVAL,
            tokenA,
            tokenB,
            amountA,
            amountB,
            priceTolerance,
            minReserveA,
            minReserveB,
            deadline,
            maxWindows,
            executionBounty,
            0,
            address(0),
            false
        );

        return _getOrderIndex();
    }

    function initializeOrder (uint256 orderId) internal{
        uint8 action = orders[orderId].action;
        address tokenA = orders[orderId].tokenA;
        address tokenB = orders[orderId].tokenB;
        uint256 amountA = orders[orderId].amountA;
        uint256 amountB = orders[orderId].amountB;
        uint256 priceTolerance = orders[orderId].priceTolerance;
        uint256 minReserveA = orders[orderId].minReserveA;
        uint256 minReserveB = orders[orderId].minReserveB;
        uint256 deadline = orders[orderId].deadline;
        uint8 maxWindows = orders[orderId].maxWindows;
        uint256 executionBounty = orders[orderId].executionBounty;

        IDXswapFactory factory = IDXswapFactory(getPriceOracleFactory(tokenA, tokenB, minReserveA, minReserveB));
        address pair;
        if (factory.getPair(tokenA, tokenB) == address(0)) {
            factory.createPair(tokenA, tokenB);
            pair = factory.getPair(tokenA, tokenB);
        } else{
          pair = factory.getPair(tokenA, tokenB);
        }
        (uint256 dxReserveA, uint256 dxReserveB) = DXswapLibrary.getReserves(address(factory), tokenA, tokenB);
        
        if (action == PROVISION && minReserveA == 0 && minReserveB == 0 && dxReserveA == 0 && dxReserveB == 0) {
            /* For initial liquidity provision can be deployed immediatly */
            _pool(tokenA, tokenB, amountA, amountB, priceTolerance);
        } else {
            /* create oracle to calculate average price over time before providing liquidity*/
            (uint256 windowTime, uint8 granularity) = consultOracleParameters(
                factory,
                tokenA,
                tokenB,
                amountA,
                amountB,
                maxWindows
            );
            uint256 oracleId = oracleCreator.createOracle(windowTime, pair, granularity, executionBounty);
            orders[orderId].oracleId = oracleId;
            emit NewOrder(orderId, action, tokenA, tokenB, amountA, amountB, priceTolerance, minReserveA, minReserveB, deadline, maxWindows, executionBounty, oracleId, address(factory));
        }
    }
    
    /**
     * @dev Execute liquidity provision after price observation.
     * @param orderId to reference the commitment.
     */
    function executeLiquidityProvision(uint256 orderId) external {
        require(orderId <= orderCount && orderId != 0, 'DXliquidityRelay: INVALID_COMMITMENT');
        require(orders[orderId].executed == false, 'DXliquidityRelay: COMMITMENT_EXECUTED');
        require(oracleCreator.getOracleStatus(orders[orderId].oracleId) == true, 'DXliquidityRelay: OBSERVATION_RUNNING');
        require(block.timestamp <= orders[orderId].deadline, 'DXliquidityRelay: DEADLINE_REACHED');

        address tokenA = orders[orderId].tokenA;
        address tokenB = orders[orderId].tokenB;
        uint256 desiredAmountA = orders[orderId].amountA;
        uint256 desiredAmountB = orders[orderId].amountB;
        uint256 amountA = oracleCreator.consult(orders[orderId].oracleId, tokenA, desiredAmountA, tokenB);
        uint256 amountB = oracleCreator.consult(orders[orderId].oracleId, tokenB, desiredAmountB, tokenA);
        orders[orderId].executed = true;

        _pool(tokenA, tokenB, amountA, amountB, orders[orderId].priceTolerance);
    }
    
    function _pool(
        address _tokenA,
        address _tokenB,
        uint256 _amountA,
        uint256 _amountB,
        uint256 _priceTolerance
    ) internal {
        uint256 minA = _amountA.sub(_amountA.mul(_priceTolerance) / PartsPerMillion);
        uint256 minB = _amountB.sub(_amountB.mul(_priceTolerance) / PartsPerMillion);

        if (_tokenA != address(0) && _tokenB != address(0)) {
            TransferHelper.safeApprove(_tokenA, dxSwapRouter, _amountA);
            TransferHelper.safeApprove(_tokenB, dxSwapRouter, _amountB);
            (uint256 amountA, uint256 amountB, uint256 liquidity) = IDXswapRouter(dxSwapRouter).addLiquidity(
                _tokenA,
                _tokenB,
                _amountA,
                _amountB,
                minA,
                minB,
                owner,
                block.timestamp
            );
            emit ExecutedPool(_tokenA, _tokenB, amountA, amountB, liquidity);
        } else {
            address token = _tokenA == address(0) ? _tokenB : _tokenA;
            uint256 amount = _tokenA == address(0) ? _amountB : _amountA;
            uint256 value = _tokenA == address(0) ? _amountA : _amountB;
            uint256 minToken = _tokenA == address(0) ? minB : minA;
            uint256 minETH = _tokenA == address(0) ? minA : minB;

            TransferHelper.safeApprove(token, dxSwapRouter, amount);
            (uint256 amountToken, uint256 amountETH, uint256 liquidity) = IDXswapRouter(dxSwapRouter).addLiquidityETH{
                value: value
            }(token, amount, minToken, minETH, owner, block.timestamp);
            emit ExecutedPool(address(0), token, amountETH, amountToken, liquidity);
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
        uint256 minA = _amountA.sub(_amountA.mul(_priceTolerance) / PartsPerMillion);
        uint256 minB = _amountB.sub(_amountB.mul(_priceTolerance) / PartsPerMillion);

        if (_tokenA != address(0) && _tokenB != address(0)) {
            TransferHelper.safeApprove(_pair, dxSwapRouter, _liquidity);
            (uint amountA, uint amountB) = IDXswapRouter(dxSwapRouter).removeLiquidity(
                _tokenA,
                _tokenB,
                _liquidity,
                minA,
                minB,
                owner,
                block.timestamp
            );
            emit ExecutedUnpool(_tokenA, _tokenB, amountA, amountB, _liquidity);
        } else {
            address token = _tokenA == address(0) ? _tokenB : _tokenA;
            uint256 amount = _tokenA == address(0) ? _amountB : _amountA;
            uint256 minToken = _tokenA == address(0) ? minB : minA;
            uint256 minETH = _tokenA == address(0) ? minA : minB;

            TransferHelper.safeApprove(token, dxSwapRouter, amount);
            (uint amountToken, uint amountETH) = IDXswapRouter(dxSwapRouter).removeLiquidityETH(
              token,
              _liquidity,
              minToken,
              minETH,
              owner,
              block.timestamp
            );
            emit ExecutedUnpool(address(0), token, amountETH, amountToken, _liquidity);
        }
    }

    /**
     * @dev Withdraw an timed out order.
     * @param orderId to reference the commitment.
     */
    function withdrawTerminatedCommitment(uint256 orderId) external {
        require(block.timestamp > orders[orderId].deadline, 'DXliquidityRelay: DEADLINE_NOT_REACHED');
        require(orders[orderId].executed == false, 'DXliquidityRelay: COMMITMENT_EXECUTED');
        address tokenA = orders[orderId].tokenA;
        address tokenB = orders[orderId].tokenB;
        uint256 amountA = orders[orderId].amountA;
        uint256 amountB = orders[orderId].amountB;
        orders[orderId].executed = true;

        if (tokenA == address(0) || tokenB == address(0)) {
            address token = tokenA== address(0) ? tokenB : tokenA;
            uint256 valueETH = tokenA == address(0) ? amountA : amountB;
            uint256 amountToken = tokenA == address(0) ? amountB : amountA;
            TransferHelper.safeTransferETH(owner, valueETH);
            TransferHelper.safeTransfer(token, owner, amountToken);
        } else {
            TransferHelper.safeTransfer(tokenA, owner, amountA);
            TransferHelper.safeTransfer(tokenB, owner, amountB);
        }
        emit OrderTerminated(orderId);
    }

    function _getOrderIndex() internal returns(uint256 orderId){
        orderCount++;
        orderId = orderCount;
    }

    function getPriceOracleFactory(
        address tokenA,
        address tokenB,
        uint256 minReserveA,
        uint256 minReserveB
    ) internal view returns (address factory) {
        (uint256 dxSwapReserveA, uint256 dxSwapReserveB) = DXswapLibrary.getReserves(dxSwapFactory, tokenA, tokenB);
        (uint256 uniswapReserveA, uint256 uniswapReserveB) = DXswapLibrary.getReserves(uniswapFactory, tokenA, tokenB);
        require(
            (dxSwapReserveA >= minReserveA && dxSwapReserveB >= minReserveB) ||
                (uniswapReserveA >= minReserveA && uniswapReserveB >= minReserveB),
            'DXliquidityRelay: INSUFFICIENT_RESERVE'
        );
        if (dxSwapReserveA >= minReserveA && dxSwapReserveB >= minReserveB) {
            factory = dxSwapFactory;
        } else {
            factory = uniswapFactory;
        }
    }

    function getPoolStake(
        address factory,
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB
    ) internal view returns (uint256 poolStake) {
        (uint256 reserveA, uint256 reserveB) = DXswapLibrary.getReserves(factory, tokenA, tokenB);
        poolStake = (amountA.add(amountB)) / ((reserveA.add(reserveB))).mul(PartsPerMillion);
    }

    function consultOracleParameters(
        IDXswapFactory factory,
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 maxWindows
    ) internal view returns (uint256 windowTime, uint8 granularity) {
        uint256 poolStake = getPoolStake(address(factory), tokenA, tokenB, amountA, amountB);
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
        granularity = uint8(windowTime / basewindowTime);
    }

    function ERC20Withdraw(address token, uint256 amount) public {
        require(msg.sender == owner, 'DXliquidityRelay: CALLER_NOT_OWNER');
        TransferHelper.safeTransfer(token, owner, amount);
    }

    function ETHWithdraw(uint256 amount) public {
        require(msg.sender == owner, 'DXliquidityRelay: CALLER_NOT_OWNER');
        TransferHelper.safeTransferETH(owner, amount);
    }
}
