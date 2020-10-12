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

    event Pool(
        address _tokenA,
        address _tokenB,
        uint256 _amountTokenA,
        uint256 _amountTokenB,
        uint256 _minA,
        uint256 _minB,
        uint256 _liquidity
    );

    struct Commitment {
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
        bool executed;
    }

    address payable public immutable dxdaoAvatar;
    address public immutable dxSwapFactory;
    address public immutable dxSwapRouter;
    address public immutable uniswapFactory;
    address public immutable uniswapRouter;
    uint256 public immutable baseWindowSize;

    uint256 public immutable PPM = 1000000;
    uint8 public immutable PROVISION = 1;
    uint8 public immutable REMOVAL = 2;
    uint8 public immutable SWAP = 3;
    OracleCreator oracleCreator;
    uint256 public commitmentCount;

    mapping(uint256 => Commitment) commitments;

    constructor(
        address payable _dxdaoAvatar,
        address _dxSwapFactory,
        address _dxSwapRouter,
        address _uniswapFactory,
        address _uniswapRouter,
        uint256 _baseWindowSize
    ) public {
        dxdaoAvatar = _dxdaoAvatar;
        dxSwapFactory = _dxSwapFactory;
        dxSwapRouter = _dxSwapRouter;
        uniswapFactory = _uniswapFactory;
        uniswapRouter = _uniswapRouter;
        baseWindowSize = _baseWindowSize;
    }

    /**
     * @dev Commit to pool tokens.
     * @param tokenA The address of the pair's first token [address(0) for ETH].
     * @param tokenB The address of the pair's second token [address(0) for ETH].
     * @param amountA The amount of tokenA to pool.
     * @param amountB The amount of tokenB to pool.
     * @param priceTolerance The allowed price tolerance [reverts otherwise].
     * @param minReserveA  Minimum required tokenA in the reserve [reverts otherwise].
     * @param minReserveB Minimum required tokenB in the reserve [reverts otherwise].
     * @param maxWindows Maximum amount of windows to measure the average price.
     */
    function commitLiquidityProvision(
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
    ) external payable returns (uint256 commitmentId) {
        require(msg.sender == dxdaoAvatar, 'DXliquidityRelay: CALLER_NOT_DXDAO');
        require(tokenA != tokenB, 'DXliquidityRelay: INVALID_PAIR');
        require(amountA > 0 && amountB > 0, 'DXliquidityRelay: INVALID_LIQUIDITY_AMOUNT');
        require(priceTolerance <= PPM, 'DXliquidityRelay: INVALID_TOLERANCE');
        require(maxWindows <= 255, 'DXliquidityRelay: INVALID_MAXWINDOWS');
        require(block.timestamp <= deadline, 'DXliquidityRelay: DEADLINE_REACHED');
        if (tokenA == address(0) || tokenB == address(0)) {
            address token = tokenA == address(0) ? tokenB : tokenA;
            uint256 valueETH = tokenA == address(0) ? amountA : amountB;
            uint256 amountToken = tokenA == address(0) ? amountB : amountA;
            require(msg.value >= valueETH, 'DXliquidityRelay: INSUFFIENT_ETH');
            TransferHelper.safeTransferFrom(token, dxdaoAvatar, address(this), amountToken);
        } else {
            TransferHelper.safeTransferFrom(tokenA, dxdaoAvatar, address(this), amountA);
            TransferHelper.safeTransferFrom(tokenB, dxdaoAvatar, address(this), amountB);
        }

        commitmentCount++;
        commitmentId = commitmentCount;
        commitments[commitmentId] = Commitment(
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
                false
            );
        // STACK TO DEEP: _commitLiquidity(commitmentId);
        return commitmentId;
    }

    function _commitLiquidity (uint256 commitmentId) internal{
        address tokenA = commitments[commitmentId].tokenA;
        address tokenB = commitments[commitmentId].tokenB;
        uint256 amountA = commitments[commitmentId].amountA;
        uint256 amountB = commitments[commitmentId].amountB;
        uint256 priceTolerance = commitments[commitmentId].priceTolerance;
        uint256 minReserveA = commitments[commitmentId].minReserveA;
        uint256 minReserveB = commitments[commitmentId].minReserveB;
        uint8 maxWindows = commitments[commitmentId].maxWindows;
        uint256 executionBounty = commitments[commitmentId].executionBounty;

        IDXswapFactory factory = IDXswapFactory(getPriceOracleFactory(tokenA, tokenB, minReserveA, minReserveB));
        if (factory.getPair(tokenA, tokenB) == address(0)) {
            factory.createPair(tokenA, tokenB);
        }
        address pair = factory.getPair(tokenA, tokenB);
        (uint256 dxReserveA, uint256 dxReserveB) = DXswapLibrary.getReserves(address(factory), tokenA, tokenB);

        if (minReserveA == 0 && minReserveB == 0 && dxReserveA == 0 && dxReserveB == 0) {
            /* For initial liquidity provision can be deployed immediatly */
            _pool(tokenA, tokenB, amountA, amountB, priceTolerance);
            commitmentId = 0;
        } else {
            /* create oracle to calculate average price over time before providing liquidity*/
            (uint256 windowSize, uint8 granularity) = consultOracleParameters(
                factory,
                tokenA,
                tokenB,
                amountA,
                amountB,
                maxWindows
            );
            uint256 oracleId = oracleCreator.createOracle(windowSize, pair, granularity, executionBounty);
            commitments[commitmentId].oracleId = oracleId;
        }
    }
    
    /**
     * @dev Execute liquidity provision after price observation.
     * @param commitmentId to reference the commitment.
     */
    function executeLiquidityProvision(uint256 commitmentId) external {
        require(commitmentId != 0, 'DXliquidityRelay: INVALID_COMMITMENT');
        require(commitmentId <= commitmentCount, 'DXliquidityRelay: INVALID_COMMITMENT');
        require(commitments[commitmentId].executed == false, 'DXliquidityRelay: COMMITMENT_EXECUTED');
        require(oracleCreator.getOracleStatus(commitmentId) == true, 'DXliquidityRelay: OBSERVATION_RUNNING');
        require(block.timestamp <= commitments[commitmentId].deadline, 'DXliquidityRelay: DEADLINE_REACHED');

        address tokenA = commitments[commitmentId].tokenA;
        address tokenB = commitments[commitmentId].tokenB;
        uint256 desiredAmountA = commitments[commitmentId].amountA;
        uint256 desiredAmountB = commitments[commitmentId].amountB;
        uint256 amountA = oracleCreator.consult(commitments[commitmentId].oracleId, tokenA, desiredAmountA, tokenB);
        uint256 amountB = oracleCreator.consult(commitments[commitmentId].oracleId, tokenB, desiredAmountB, tokenA);
        commitments[commitmentId].executed = true;

        _pool(tokenA, tokenB, amountA, amountB, commitments[commitmentId].priceTolerance);
    }

    /**
     * @dev Withdraw a commitment that timed out.
     * @param commitmentId to reference the commitment.
     */
    function withdrawTerminatedCommitment(uint256 commitmentId) external {
        require(block.timestamp > commitments[commitmentId].deadline, 'DXliquidityRelay: DEADLINE_NOT_REACHED');
        require(commitments[commitmentId].executed == false, 'DXliquidityRelay: COMMITMENT_EXECUTED');
        address tokenA = commitments[commitmentId].tokenA;
        address tokenB = commitments[commitmentId].tokenB;
        uint256 amountA = commitments[commitmentId].amountA;
        uint256 amountB = commitments[commitmentId].amountB;
        commitments[commitmentId].executed == true;

        if (tokenA == address(0) || tokenB == address(0)) {
            address token = tokenA== address(0) ? tokenB : tokenA;
            uint256 valueETH = tokenA == address(0) ? amountA : amountB;
            uint256 amountToken = tokenA == address(0) ? amountB : amountA;
            TransferHelper.safeTransferETH(dxdaoAvatar, valueETH);
            TransferHelper.safeTransfer(token, dxdaoAvatar, amountToken);
        } else {
            TransferHelper.safeTransfer(tokenA, dxdaoAvatar, amountA);
            TransferHelper.safeTransfer(tokenB, dxdaoAvatar, amountB);
        }
    }
    
    function _pool(
        address _tokenA,
        address _tokenB,
        uint256 _amountA,
        uint256 _amountB,
        uint256 _priceTolerance
    ) internal {
        uint256 minA = _amountA.sub(_amountA.mul(_priceTolerance) / PPM);
        uint256 minB = _amountB.sub(_amountB.mul(_priceTolerance) / PPM);

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
                dxdaoAvatar,
                block.timestamp
            );
            emit Pool(_tokenA, _tokenB, amountA, amountB, minA, minB, liquidity);
        } else {
            address token = _tokenA == address(0) ? _tokenB : _tokenA;
            uint256 amount = _tokenA == address(0) ? _amountB : _amountA;
            uint256 value = _tokenA == address(0) ? _amountA : _amountB;
            uint256 minToken = _tokenA == address(0) ? minB : minA;
            uint256 minETH = _tokenA == address(0) ? minA : minB;

            TransferHelper.safeApprove(token, dxSwapRouter, amount);
            (uint256 amountToken, uint256 amountETH, uint256 liquidity) = IDXswapRouter(dxSwapRouter).addLiquidityETH{
                value: value
            }(token, amount, minToken, minETH, dxdaoAvatar, block.timestamp);
            emit Pool(address(0), token, amountETH, amountToken, minETH, minToken, liquidity);
        }
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
        poolStake = (amountA.add(amountB)) / ((reserveA.add(reserveB))).mul(10000);
    }

    function consultOracleParameters(
        IDXswapFactory factory,
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 maxWindows
    ) internal view returns (uint256 windowSize, uint8 granularity) {
        uint256 poolStake = getPoolStake(address(factory), tokenA, tokenB, amountA, amountB);
        // poolStake: 0.1% = 10; 1=100; 10% = 1000;
        uint256 windows;
        if(poolStake < 10) {
          windows = 3;
        } else if (poolStake >= 10 && poolStake < 25){
          windows = 4;
        } else if (poolStake >= 25 && poolStake < 50){
          windows = 5;
        } else if (poolStake >= 50 && poolStake < 100){
          windows = 6;
        } else if (poolStake >= 100 && poolStake < 300){
          windows = 6;
        } else {
          windows = 10;
        }
        windows = windows <= maxWindows ? windows : maxWindows;
        windowSize = windows.mul(baseWindowSize);
        granularity = uint8(windowSize / baseWindowSize);
    }

    function ERC20Withdraw(address token, uint256 amount) public {
        require(msg.sender == dxdaoAvatar, 'DXliquidityRelay: CALLER_NOT_DXDAO');
        TransferHelper.safeTransfer(token, dxdaoAvatar, amount);
    }

    function EthWithdraw(uint256 amount) public {
        require(msg.sender == dxdaoAvatar, 'DXliquidityRelay: CALLER_NOT_DXDAO');
        TransferHelper.safeTransferETH(dxdaoAvatar, amount);
    }
}
