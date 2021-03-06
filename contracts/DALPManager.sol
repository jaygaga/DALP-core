pragma solidity ^0.6.6;
pragma experimental ABIEncoderV2;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import {FixedPoint} from "@uniswap/lib/contracts/libraries/FixedPoint.sol";
import {Babylonian} from "@uniswap/lib/contracts/libraries/Babylonian.sol";
import {IWETH} from "@uniswap/v2-periphery/contracts/interfaces/IWETH.sol";
import {UniswapV2Library} from "@uniswap/v2-periphery/contracts/libraries/UniswapV2Library.sol";
import {IUniswapV2Router01} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router01.sol";

import {DALP} from "./DALP.sol";
import {OracleManager} from "./OracleManager.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";

contract DALPManager is Ownable, ReentrancyGuard {
    //----------------------------------------
    // Type definitions
    //----------------------------------------

    using SafeMath for uint256;
    using FixedPoint for *;
    using SafeERC20 for IERC20;

    //----------------------------------------
    // State variables
    //----------------------------------------

    uint private constant _DEFAULT_TOKEN_TO_ETH_FACTOR = 1000;
    uint112 private constant _MAX_UINT112 = uint112(-1);
    uint private constant _UNISWAP_V2_DEADLINE_DELTA = 15 minutes;

    // Limit slippage to 0.5%
    uint112 private constant _UNISWAP_V2_SLIPPAGE_LIMIT = 200;

    DALP public dalp; // DALP token
    IUniswapV2Router01 private immutable _uniswapRouter;
    address private immutable _WETH; // solhint-disable-line var-name-mixedcase
    OracleManager private _oracle;

    // address of the active Uniswap v2 pair
    address private _uniswapPair;

    // Uniswap v2 token pairs that will analyzed for investment
    address[] private _uniswapTokenPairs;

    //----------------------------------------
    // Events
    //----------------------------------------

    event AddUniswapLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountA,
        uint amountB,
        uint liquidity
    );

    event MintDALP(
        address sender,
        uint tokenAmount,
        uint ethAmount
    );

    event LiquidityEvent(
        uint timestamp,
        uint totalValue
    );

    //----------------------------------------
    // Constructor
    //----------------------------------------

    constructor(
        IUniswapV2Router01 uniswapRouter,
        OracleManager oracle,
        address[] memory uniswapTokenPairs
    ) public {
        _uniswapRouter = uniswapRouter;
        _WETH = uniswapRouter.WETH();
        _oracle = oracle;
        _uniswapTokenPairs = uniswapTokenPairs;

        for (uint i = 0; i < uniswapTokenPairs.length; i++) {
            address token0 = IUniswapV2Pair(uniswapTokenPairs[i]).token0();
            if (token0 != uniswapRouter.WETH() && oracle.getOraclePairExists(token0) == false) {
                oracle.addPair(token0);
            }

            address token1 = IUniswapV2Pair(uniswapTokenPairs[i]).token1();
            if (token1 != uniswapRouter.WETH() && oracle.getOraclePairExists(token1) == false) {
                oracle.addPair(token1);
            }
        }
    }

    //----------------------------------------
    // Receive function
    //----------------------------------------

    // solhint-disable-next-line no-empty-blocks
    receive() external payable {}

    //----------------------------------------
    // External functions
    //----------------------------------------

    /**
     * @notice Allocates all DALP assets to the most profitable Uniswap v2 pair
     */
    function reallocateLiquidity() external nonReentrant onlyOwner {
        IUniswapV2Pair pair = _findBestUpdatedUniswapV2Pair();

        if (_uniswapPair != address(pair)) {
            if (_uniswapPair != address(0)) {
                _removeAllUniswapV2Liquidity();
            }

            _addUniswapV2Liquidity(pair.token0(), pair.token1());
            setUniswapPair(address(pair));
        }
    }

    /**
     * @notice Redeems an amount of DALP tokens for its ETH value
     * @param amount The amount of DALP tokens to redeem
     */
    function redeem(uint amount) external nonReentrant {
        require(amount > 0, "DALPManager/insufficient-balance");
        require(amount <= dalp.balanceOf(msg.sender), "DALPManager/insufficient-balance");

        require(amount <= _MAX_UINT112, "DALPManager/overflow");
        require(dalp.totalSupply() > 0, "DALPManager/divide-by-zero");
        require(dalp.totalSupply() <= _MAX_UINT112, "DALPManager/overflow");

        FixedPoint.uq112x112 memory shareOfDALP = FixedPoint.fraction(
            uint112(amount), uint112(dalp.totalSupply())
        );
        dalp.burn(msg.sender, amount);

        require(address(this).balance <= _MAX_UINT112, "DALPManager/overflow");
        uint amountETH = shareOfDALP.mul(uint112(address(this).balance)).decode144();

        if (_uniswapPair != address(0)) {
            IUniswapV2Pair pair = IUniswapV2Pair(_uniswapPair);

            uint liquidity = shareOfDALP
                .mul(pair.balanceOf(address(this)))
                .decode144();

            _updateOracle(pair);

            amountETH = amountETH.add(_removeUniswapV2Liquidity(liquidity));
        }

        msg.sender.transfer(amountETH);
    }

    //----------------------------------------
    // External views
    //----------------------------------------

    function getActiveUniswapV2Tokens() external view returns (address, address) {
        if (_uniswapPair == address(0)) {
            return (address(0), address(0));
        } else {
            return (IUniswapV2Pair(_uniswapPair).token0(), IUniswapV2Pair(_uniswapPair).token1());
        }
    }

    function calculateMintAmount(uint ethValue) external view returns (uint) {
        uint totalValue = getDALPTotalValue();
        return _calculateMintAmount(ethValue, totalValue);
    }

    //----------------------------------------
    // Public functions
    //----------------------------------------

    // called by admin on deployment
    function setTokenContract(address tokenAddress) public onlyOwner {
        dalp = DALP(tokenAddress);
    }

    function setUniswapPair(address uniswapPair) public onlyOwner {
        _uniswapPair = uniswapPair;
    }

    function mint() public payable nonReentrant {
        require(msg.value > 0, "DALPManager/insufficient-value");

        if (_uniswapPair != address(0)) {
            _updateOracle(IUniswapV2Pair(_uniswapPair));
        }

        uint totalValue = getDALPTotalValue().sub(msg.value);
        uint mintAmount = _calculateMintAmount(msg.value, totalValue);
        dalp.mint(msg.sender, mintAmount);

        if (_uniswapPair != address(0)) {
            IUniswapV2Pair pair = IUniswapV2Pair(_uniswapPair);
            _addUniswapV2Liquidity(pair.token0(), pair.token1());
        }

        emit MintDALP(msg.sender, mintAmount, msg.value);
    }

    function burn(uint tokensToBurn) public nonReentrant {
        require(tokensToBurn > 0, "Must burn tokens");
        require(dalp.balanceOf(msg.sender) >= tokensToBurn, "Insufficient balance");

        dalp.burn(msg.sender, tokensToBurn);
    }

    //----------------------------------------
    // Public views
    //----------------------------------------

    function getUniswapPoolTokenHoldings() public view returns (uint) {
        return IERC20(_uniswapPair).balanceOf(address(this));
    }

    function getUniswapPoolTokenSupply() public view returns (uint) {
        return IERC20(_uniswapPair).totalSupply();
    }

    function getUniswapPoolReserves() public view returns (uint112 reserve0, uint112 reserve1) {
        (reserve0, reserve1, ) = IUniswapV2Pair(_uniswapPair).getReserves();
    }

    function getUniswapPair(address token) public view returns (IUniswapV2Pair pair) {
        pair = IUniswapV2Pair(UniswapV2Library.pairFor(_uniswapRouter.factory(), _WETH, token));
    }

    function getDalpProportionalReserves()
        public
        view
        returns (uint, uint)
    {
        uint256 liquidity = getUniswapPoolTokenHoldings();
        return getLiquidityProportionalReserves(liquidity);
    }

    function getLiquidityProportionalReserves(uint liquidity)
        public
        view
        returns (uint, uint)
    {
        require(liquidity <= _MAX_UINT112, "DALPManager/overflow");

        (uint112 reserve0, uint112 reserve1) = getUniswapPoolReserves();

        IUniswapV2Pair pair = IUniswapV2Pair(_uniswapPair);
        uint totalLiquidity = pair.totalSupply();
        require(totalLiquidity <= _MAX_UINT112, "DALPManager/overflow");

        FixedPoint.uq112x112 memory shareOfLiquidity = FixedPoint.fraction(
            uint112(liquidity),
            uint112(totalLiquidity)
        );

        require(reserve0 <= _MAX_UINT112, "DALPManager/overflow");
        uint reserve0Share = shareOfLiquidity.mul(reserve0).decode144();

        require(reserve1 <= _MAX_UINT112, "DALPManager/overflow");
        uint reserve1Share = shareOfLiquidity.mul(reserve1).decode144();

        return (reserve0Share, reserve1Share);
    }

    function getDALPTotalValue() public view returns (uint) {
        uint totalValue = address(this).balance;

        if (_uniswapPair != address(0)) {
            (uint reserve0Share, uint reserve1Share) = getDalpProportionalReserves();
            IUniswapV2Pair pair = IUniswapV2Pair(_uniswapPair);

            address token0 = pair.token0();
            address token1 = pair.token1();

            uint valueToken0 = _oracle.consult(token0, reserve0Share);
            uint valueToken1 = _oracle.consult(token1, reserve1Share);

            totalValue += valueToken0.add(valueToken1);
        }

        return totalValue;
    }

    /**
     * @notice Get the ETH value of an amount of DALP tokens
     * @param amount The amount of DALP tokens
     * @return The total ETH value of the DALP tokens
     */
    function getDALPValue(uint amount) public view returns (uint) {
        require(amount > 0, "DALPManager/insufficient-balance");
        require(amount <= _MAX_UINT112, "DALPManager/overflow");
        require(dalp.totalSupply() > 0, "DALPManager/divide-by-zero");
        require(dalp.totalSupply() <= _MAX_UINT112, "DALPManager/overflow");

        FixedPoint.uq112x112 memory shareOfDALP = FixedPoint.fraction(
            uint112(amount), uint112(dalp.totalSupply())
        );

        uint totalValue = getDALPTotalValue();
        require(totalValue <= _MAX_UINT112, "DALPManager/overflow");

        return shareOfDALP.mul(uint112(totalValue)).decode144();
    }

    function findBestUniswapV2Pair() public view returns (address) {
        return address(_findBestUniswapV2Pair());
    }

    //----------------------------------------
    // Internal functions
    //----------------------------------------

    /**
     * @notice Add liquidity to a Uniswap pool with DALP controlled assets
     * @dev The larger the discrepancy between WETH <-> token pairs and the token <-> token pair,
     *      the more ETH will be left behind after adding liquidity.
     * @param tokenA First token in the Uniswap pair
     * @param tokenB Second token in the Uniswap pair
     */
    function _addUniswapV2Liquidity(address tokenA, address tokenB) internal {
        require(address(this).balance > 0, "DALPManager/insufficient-balance");

        uint112 amountADesired;
        uint112 amountBDesired;

        if (tokenA == _WETH || tokenB == _WETH) {
            // Get amount desired for a WETH <-> token pair
            (
                uint112 amountETHDesired,
                uint112 amountTokenDesired
            ) = _getAmountDesiredForWETHPairUniswapV2(tokenA == _WETH ? tokenB : tokenA);

            (amountADesired, amountBDesired) = tokenA == _WETH
                ? (amountETHDesired, amountTokenDesired)
                : (amountTokenDesired, amountETHDesired);
        } else {
            // Get amount desired for a token <-> token pair
            (amountADesired, amountBDesired) = _getAmountDesiredForTokenPairUniswapV2(
                tokenA,
                tokenB
            );
        }

        // Approve tokens for transfer to Uniswap pair
        IERC20(tokenA).safeIncreaseAllowance(address(_uniswapRouter), amountADesired);
        IERC20(tokenB).safeIncreaseAllowance(address(_uniswapRouter), amountBDesired);

        (uint amountA, uint amountB, uint liquidity) = _uniswapRouter.addLiquidity(
            tokenA,
            tokenB,
            amountADesired,
            amountBDesired,
            amountADesired - (
                FixedPoint
                    .encode(amountADesired)
                    .div(_UNISWAP_V2_SLIPPAGE_LIMIT)
                    .decode()
            ),
            amountBDesired - (
                FixedPoint
                    .encode(amountBDesired)
                    .div(_UNISWAP_V2_SLIPPAGE_LIMIT)
                    .decode()
            ),
            address(this),
            now + _UNISWAP_V2_DEADLINE_DELTA // solhint-disable-line not-rely-on-time
        );

        // Swap token A dust to WETH
        if (tokenA != _WETH) {
            uint amountAIn = IERC20(tokenA).balanceOf(address(this));

            if (amountAIn > 0) {
                _swapTokensForWETH(tokenA, amountAIn);
            }
        }

        // Swap token B dust to WETH
        if (tokenB != _WETH) {
            uint amountBIn = IERC20(tokenB).balanceOf(address(this));

            if (amountBIn > 0) {
                _swapTokensForWETH(tokenB, amountBIn);
            }
        }

        // Withdraw WETH dust back to ETH
        IWETH(_WETH).withdraw(IERC20(_WETH).balanceOf(address(this)));

        emit AddUniswapLiquidity(
            tokenA,
            tokenB,
            amountADesired,
            amountBDesired,
            amountA,
            amountB,
            liquidity
        );

        // solhint-disable-next-line not-rely-on-time
        emit LiquidityEvent(now, getDALPTotalValue());
    }

    /**
     * @notice Remove all liquidity from the active Uniswap v2 pair
     */
    function _removeAllUniswapV2Liquidity() internal {
        uint liquidity = IUniswapV2Pair(_uniswapPair).balanceOf(address(this));
        _removeUniswapV2Liquidity(liquidity);
    }

    /**
     * @notice Remove a requested amount of liquidity from the active Uniswap v2 pair
     * @param liquidity The amount of liquidity to remove
     * @return The amount of ETH withdrawn from the removed liquidity
     */
    function _removeUniswapV2Liquidity(uint liquidity) internal returns (uint) {
        require(liquidity <= _MAX_UINT112, "DALPManager/overflow");

        (uint reserve0, uint reserve1) = getLiquidityProportionalReserves(liquidity);

        require(reserve0 <= _MAX_UINT112, "DALPManager/overflow");
        uint amountToken0Min = reserve0.sub(
            FixedPoint.encode(uint112(reserve0)).div(_UNISWAP_V2_SLIPPAGE_LIMIT).decode()
        );

        require(reserve1 <= _MAX_UINT112, "DALPManager/overflow");
        uint amountToken1Min = reserve1.sub(
            FixedPoint.encode(uint112(reserve1)).div(_UNISWAP_V2_SLIPPAGE_LIMIT).decode()
        );

        IUniswapV2Pair pair = IUniswapV2Pair(_uniswapPair);
        address token0 = pair.token0();
        address token1 = pair.token1();

        pair.approve(address(_uniswapRouter), liquidity);

        (uint amount0, uint amount1) = _uniswapRouter.removeLiquidity(
            token0,
            token1,
            liquidity,
            amountToken0Min,
            amountToken1Min,
            address(this),
            now + _UNISWAP_V2_DEADLINE_DELTA // solhint-disable-line not-rely-on-time
        );

        uint amount0ETH = 0;
        if (token0 != _WETH && amount0 > 0) {
            uint[] memory amounts0 = _swapTokensForWETH(token0, amount0);
            amount0ETH = amounts0[1];
        }

        uint amount1ETH = 0;
        if (token1 != _WETH && amount1 > 0) {
            uint[] memory amounts1 = _swapTokensForWETH(token1, amount1);
            amount1ETH = amounts1[1];
        }

        uint amountETH = amount0ETH.add(amount1ETH);
        IWETH(_WETH).withdraw(amountETH);

        // solhint-disable-next-line not-rely-on-time
        emit LiquidityEvent(now, getDALPTotalValue());

        return amountETH;
    }

    /**
     * @notice Get the amount of tokens the DALP can afford to add to a Uniswap v2 WETH pair
     * @dev It was necessary to refactor this code out of `_addUniswapV2Liquidity` to avoid a
     *      "Stack too deep" error.
     * @param token The token paired with WETH
     * @return The desired amount of WETH and tokens
     */
    function _getAmountDesiredForWETHPairUniswapV2(address token)
        internal
        returns (uint112, uint112)
    {
        // Get maximum amount of tokens that can be swapped with half the ETH balance
        uint totalETH = address(this).balance;
        uint amountETH = totalETH / 2;
        uint amountTokenOut = _getAmountOutForUniswapV2(_WETH, token, totalETH - amountETH);

        // Get the balanced amounts for the WETH pair that is less than the maximum swap amount
        (uint amountETHBalanced, uint amountTokenBalanced) = _getBalancedAmountsForUniswapV2(
            _WETH,
            token,
            amountETH,
            amountTokenOut
        );

        // Wrap ETH for WETH
        IWETH(_WETH).deposit{value: amountETHBalanced}();

        // Swap for tokens
        uint[] memory amountsToken = _swapForTokens(
            token,
            address(this).balance,
            amountTokenBalanced
        );

        // Amounts need to be rebalanced because the reserves are changed from the swap
        (amountETHBalanced, amountTokenBalanced) = _getBalancedAmountsForUniswapV2(
            _WETH,
            token,
            amountETHBalanced,
            amountsToken[1]
        );

        require(amountETHBalanced <= _MAX_UINT112, "DALPManager/overflow");
        uint112 amountETHDesired = uint112(amountETHBalanced);

        require(amountTokenBalanced <= _MAX_UINT112, "DALPManager/overflow");
        uint112 amountTokenDesired = uint112(amountTokenBalanced);

        return (amountETHDesired, amountTokenDesired);
    }

    /**
     * @notice Get the amount of tokens the DALP can afford to add to a Uniswap v2 pair
     * @dev It was necessary to refactor this code out of `_addUniswapV2Liquidity` to avoid a
     *      "Stack too deep" error.
     * @param tokenA First token in the Uniswap pair
     * @param tokenB Second token in the Uniswap pair
     * @return The desired amount of token A and token B
     */
    function _getAmountDesiredForTokenPairUniswapV2(address tokenA, address tokenB)
        internal
        returns (uint112, uint112)
    {
        // Get maximum amount of tokens that can be swapped with half the ETH balance
        uint amountAOut = _getAmountOutForUniswapV2(_WETH, tokenA, address(this).balance / 2);
        uint amountBOut = _getAmountOutForUniswapV2(
            _WETH,
            tokenB,
            address(this).balance - (address(this).balance / 2)
        );

        // Get the balanced amounts for the target pair that is less than the maximum swap amount
        (uint amountABalanced, uint amountBBalanced) = _getBalancedAmountsForUniswapV2(
            tokenA,
            tokenB,
            amountAOut,
            amountBOut
        );

        // Swap for token A
        uint[] memory amountsA = _swapForTokens(
            tokenA,
            address(this).balance / 2,
            amountABalanced
        );
        require(amountsA[1] <= _MAX_UINT112, "DALPManager/overflow");
        uint112 amountADesired = uint112(amountsA[1]);

        // Swap for token B
        uint[] memory amountsB = _swapForTokens(tokenB, address(this).balance, amountBBalanced);
        require(amountsB[1] <= _MAX_UINT112, "DALPManager/overflow");
        uint112 amountBDesired = uint112(amountsB[1]);

        return (amountADesired, amountBDesired);
    }

    /**
     * @notice Swap DALP ETH for tokens
     * @param token The token address
     * @param amountInMax The maximum amount of ETH to swap
     * @param amountOut The number of tokens to receive
     * @return A two element array of the ETH sent and the tokens received
     */
    function _swapForTokens(address token, uint amountInMax, uint amountOut)
        internal
        returns (uint[] memory)
    {
        address[] memory path = new address[](2);
        path[0] = _WETH;
        path[1] = token;

        return _uniswapRouter.swapETHForExactTokens{value: amountInMax}(
            amountOut,
            path,
            address(this), 
            now + _UNISWAP_V2_DEADLINE_DELTA // solhint-disable-line not-rely-on-time
        );
    }

    /**
     * @notice Swap DALP tokens for WETH
     * @notice Used to clean up token dust after adding liquidity
     * @param token The token to swap for WETH
     * @param amountIn The amount of tokens to swap
     * @return A two element array of the tokens sent and the WETH received
     */
    function _swapTokensForWETH(address token, uint amountIn) internal returns (uint[] memory) {
        uint amountOut = _getAmountOutForUniswapV2(token, _WETH, amountIn);
        require(amountOut <= _MAX_UINT112, "DALPManager/overflow");
        uint amountOutMin = amountOut - (
            FixedPoint
                .encode(uint112(amountOut))
                .div(_UNISWAP_V2_SLIPPAGE_LIMIT)
                .decode()
        );

        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = _WETH;

        IERC20(token).safeIncreaseAllowance(address(_uniswapRouter), amountIn);

        return _uniswapRouter.swapExactTokensForTokens(
            amountIn,
            amountOutMin,
            path,
            address(this), 
            now + _UNISWAP_V2_DEADLINE_DELTA // solhint-disable-line not-rely-on-time
        );
    }

    /**
     * @notice Find which Uniswap v2 pair will earn the most fees
     * @notice Uses latest oracle values when rating pairs
     * @return The address of the best Uniswap v2 pair
     */
    function _findBestUpdatedUniswapV2Pair() internal returns (IUniswapV2Pair) {
        IUniswapV2Pair bestPair;
        uint bestRating = 0;

        for (uint i = 0; i < _uniswapTokenPairs.length; i++) {
            IUniswapV2Pair pair = IUniswapV2Pair(_uniswapTokenPairs[i]);
            _updateOracle(pair);

            uint rating = _getUniswapV2PairRating(pair);

            // Track the best rated pair
            if (rating > bestRating) {
                bestPair = pair;
                bestRating = rating;
            }
        }

        return bestPair;
    }

    function _updateOracle(IUniswapV2Pair pair) internal {
        address token0 = pair.token0();
        if (token0 != _WETH) _oracle.update(token0);

        address token1 = pair.token1();
        if (token1 != _WETH) _oracle.update(token1);
    }

    //----------------------------------------
    // Internal views
    //----------------------------------------

    /**
     * @notice Rates a Uniswap v2 pair on its ability to generate fees
     * @dev Rating system looks for pairs with the most fees and least liquidity
     * @param pair The Uniswap v2 pair to rate
     * @return The Uniswap v2 pair's rating
     */
    function _getUniswapV2PairRating(IUniswapV2Pair pair) internal view returns (uint) {
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();

        // Get square root of k values
        uint rootK = Babylonian.sqrt(uint(reserve0).mul(reserve1));
        uint rootKLast = Babylonian.sqrt(pair.kLast());

        // Skip if there is an overflow
        if (rootKLast > _MAX_UINT112) return 0;

        uint totalSupply = pair.totalSupply();

        // Skip if there would be a divide by zero or an overflow
        if (totalSupply == 0) return 0;
        if (totalSupply > _MAX_UINT112) return 0;

        uint112 growthDenominator = (
            FixedPoint.encode(uint112(rootKLast))
                .div(uint112(totalSupply))
                .decode()
        );

        // If the last root k was 0, the new k value is all growth
        growthDenominator = growthDenominator > 0 ? growthDenominator : 1;

        // Skip if there was negative growth, this would cause an overflow
        if (rootK < rootKLast) return 0;
        // Skip if there is an overflow
        if (rootK - rootKLast > _MAX_UINT112) return 0;

        // percent growth of k over supply since last liquidity event
        FixedPoint.uq112x112 memory growth = (
            FixedPoint.encode(uint112(rootK - rootKLast))
                .div(uint112(totalSupply))
                .div(growthDenominator)
        );

        uint totalValue = 0;

        // Get value of token0 liquidity
        totalValue += _oracle.consult(pair.token0(), reserve0);

        // Get value of token1 liquidity
        totalValue += _oracle.consult(pair.token1(), reserve1);

        // Skip if there would be a divide by zero or an overflow
        if (totalValue == 0) return 0;
        if (totalValue > _MAX_UINT112) return 0;

        // Multiply by some large factor to get a useable value
        // TODO: This multiplication is not the ideal solution
        return growth.div(uint112(totalValue)).mul(1e36).decode144();
    }

    /**
     * @notice Find which Uniswap v2 pair will earn the most fees
     * @notice Oracle is not updated, values may be stale
     * @return The address of the best Uniswap v2 pair
     */
    function _findBestUniswapV2Pair() internal view returns (IUniswapV2Pair) {
        IUniswapV2Pair bestPair;
        uint bestRating = 0;

        for (uint i = 0; i < _uniswapTokenPairs.length; i++) {
            IUniswapV2Pair pair = IUniswapV2Pair(_uniswapTokenPairs[i]);
            uint rating = _getUniswapV2PairRating(pair);

            // Track the best rated pair
            if (rating > bestRating) {
                bestPair = pair;
                bestRating = rating;
            }
        }

        return bestPair;
    }

    /**
     * @notice Get balanced token amounts for adding liquidity to a Uniswap v2 pair
     * @param tokenA The address of token A
     * @param tokenB The address of token B
     * @param amountA The amount of token A available
     * @param amountB The amount of token B available
     * @return The balanced amounts for token A and B
     */
    function _getBalancedAmountsForUniswapV2(
        address tokenA,
        address tokenB,
        uint amountA,
        uint amountB
    )
        internal
        view
        returns (uint, uint)
    {
        uint amountBBalanced = _getEquivalentAmountForUniswapV2(tokenA, tokenB, amountA);

        if (amountBBalanced > amountB) {
            amountBBalanced = amountB;
        } else if (amountBBalanced == 0) {
            return (amountA, amountB);
        }

        uint amountABalanced = _getEquivalentAmountForUniswapV2(tokenB, tokenA, amountBBalanced);

        return (amountABalanced, amountBBalanced);
    }

    /**
     * @notice Get the amount of token B that is equivalent to the given amount of token A
     * @param tokenA The address of token A
     * @param tokenB The address of token B
     * @param amountA The amount of token A
     * @return The equivalent amount of token B, returns 0 if the token pair has no reserves
     */
    function _getEquivalentAmountForUniswapV2(address tokenA, address tokenB, uint amountA)
        internal
        view
        returns (uint)
    {
        (uint reserveA, uint reserveB) = UniswapV2Library.getReserves(
            _uniswapRouter.factory(),
            tokenA,
            tokenB
        );

        if (reserveA == 0 && reserveB == 0) {
            return 0;
        }

        return _uniswapRouter.quote(amountA, reserveA, reserveB);
    }

    /**
     * @notice Get the amount of token B that can be swapped for the given amount of token A
     * @param tokenA The address of token A
     * @param tokenB The address of token B
     * @param amountInA The amount of token A
     * @return The amount of token B that can be swapped for token A
     */
    function _getAmountOutForUniswapV2(address tokenA, address tokenB, uint amountInA)
        internal
        view
        returns (uint)
    {
        (uint reserveA, uint reserveB) = UniswapV2Library.getReserves(
            _uniswapRouter.factory(),
            tokenA,
            tokenB
        );

        return _uniswapRouter.getAmountOut(amountInA, reserveA, reserveB);
    }

    //----------------------------------------
    // Private views
    //----------------------------------------

    function _calculateMintAmount(uint ethValue, uint totalValue) private view returns (uint) {
        uint totalSupply = dalp.totalSupply();

        if (totalValue == 0 || totalSupply == 0) {
            return ethValue * _DEFAULT_TOKEN_TO_ETH_FACTOR;
        }

        require(ethValue <= _MAX_UINT112, "DALPManager/overflow");
        require(totalValue <= _MAX_UINT112, "DALPManager/overflow");
        require(totalSupply <= _MAX_UINT112, "DALPManager/overflow");

        return FixedPoint.fraction(uint112(ethValue), uint112(totalValue))
            .mul(uint112(totalSupply))
            .decode144();
    }
}
