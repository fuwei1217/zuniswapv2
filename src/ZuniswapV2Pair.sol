// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.10;

import "solmate/tokens/ERC20.sol";
import "./libraries/Math.sol";
import "./libraries/UQ112x112.sol";
import "./interfaces/IZuniswapV2Callee.sol";

interface IERC20 {
    function balanceOf(address) external returns (uint256);

    function transfer(address to, uint256 amount) external;
}

error AlreadyInitialized();
error BalanceOverflow();
error InsufficientInputAmount();
error InsufficientLiquidity();
error InsufficientLiquidityBurned();
error InsufficientLiquidityMinted();
error InsufficientOutputAmount();
error InvalidK();
error TransferFailed();

// pair contract provide lower-level function for router which is the user interface
// for eaxample, swap checks the constant K after swapping, but the parameter should be calculated by caller.
contract ZuniswapV2Pair is ERC20, Math {
    using UQ112x112 for uint224;

    uint256 constant MINIMUM_LIQUIDITY = 1000;

    address public token0;
    address public token1;

    // using uint112 and uint32 to make full use of a 32 bytes slot
    // need to keep record of reserves as state variable to protect against price manipulation
    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;

    // with twap one toke price cannot be calculated with another one, so need to keep both
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;

    // lock for re-entrancea issue
    bool private isEntered;

    event Burn(
        address indexed sender,
        uint256 amount0,
        uint256 amount1,
        address to // which address will take the token out
    );
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Sync(uint256 reserve0, uint256 reserve1);
    event Swap(
        address indexed sender,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );

    // for re-entrance issue
    modifier nonReentrant() {
        require(!isEntered);
        isEntered = true;

        _;

        isEntered = false;
    }

    constructor() ERC20("ZuniswapV2 Pair", "ZUNIV2", 18) {}

    // since create2 is used to create the pair contract, initialize is used to record token addresses.
    function initialize(address token0_, address token1_) public {
        // make sure initialize only once
        if (token0 != address(0) || token1 != address(0))
            revert AlreadyInitialized();

        token0 = token0_;
        token1 = token1_;
    }

    // mint LP token, provide liduidity. 
    function mint(address to) public returns (uint256 liquidity) {
        (uint112 reserve0_, uint112 reserve1_, ) = getReserves();
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        // note mint is called after token has been transfered to pair contract.
        // so amount here is the input amounts for providing liquidity
        uint256 amount0 = balance0 - reserve0_;
        uint256 amount1 = balance1 - reserve1_;

        // totalSupply is managed in super class ERC20
        if (totalSupply == 0) {
            // MINIMUM_LIQUIDITY is used in case a milicious first mint can make the LP token price too high
            // by mint and donation
            liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            // note here mint is for 0 address, it will be always in the pair
            _mint(address(0), MINIMUM_LIQUIDITY);
        } else {
            // in v1, LP token amount is calculated by token, in v2 we take the lower one, higher one will be 
            // consider as price manipulaton and be punished(since the value of one share increase, others LP holder could get more when burn).
            liquidity = Math.min(
                (amount0 * totalSupply) / reserve0_,
                (amount1 * totalSupply) / reserve1_
            );
        }

        if (liquidity <= 0) revert InsufficientLiquidityMinted();

        _mint(to, liquidity);

        // update reserves state variable
        _update(balance0, balance1, reserve0_, reserve1_);

        emit Mint(to, amount0, amount1);
    }

    // remove liqudity by burning LP token
    function burn(address to)
        public
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 liquidity = balanceOf[address(this)];

        amount0 = (liquidity * balance0) / totalSupply;
        amount1 = (liquidity * balance1) / totalSupply;

        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurned();

        // note burn cannot burn msg.sender's token
        // router calls transferFrom first to transfer token from msg.sender to pair contract, then it burn
        _burn(address(this), liquidity);

        // transfer token to to address
        _safeTransfer(token0, to, amount0);
        _safeTransfer(token1, to, amount1);

        balance0 = IERC20(token0).balanceOf(address(this));
        balance1 = IERC20(token1).balanceOf(address(this));

        // update reserve with current balance
        (uint112 reserve0_, uint112 reserve1_, ) = getReserves();
        _update(balance0, balance1, reserve0_, reserve1_);

        emit Burn(msg.sender, amount0, amount1, to);
    }

    // amountOut is expected token amount. Amount in can be inferred by balances and reserves
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) public nonReentrant {
        if (amount0Out == 0 && amount1Out == 0)
            revert InsufficientOutputAmount();

        (uint112 reserve0_, uint112 reserve1_, ) = getReserves();

        if (amount0Out > reserve0_ || amount1Out > reserve1_)
            revert InsufficientLiquidity();

        // no matter flash swap or normal swap, we can transfer directly to the to address, since k is checked later
        // So actuallly it maybe :
        //  - normal swap: provide token in and get token out. so the amount out should be calculated before calling this func
        //  - flash swap: no need to provide token in, get token out first, then provide token in in the callback func. so the amount out is the amouont of token you need.
        if (amount0Out > 0) _safeTransfer(token0, to, amount0Out);
        if (amount1Out > 0) _safeTransfer(token1, to, amount1Out);

        // data is provided for flash swap, call the callback func with data
        if (data.length > 0)
            IZuniswapV2Callee(to).zuniswapV2Call(
                msg.sender,
                amount0Out,
                amount1Out,
                data
            );

        // at this point, balance should either be pre-paid in normal swap, or repayed in the flash swap case.
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        // balance > reserve - amountout => balance + amountOut > reserve
        // if yes it means input amount is more than 0
        // if no, it means we have less reseve now, so user is buying the token
        // Note, we can pay with one token or both token
        // also, we can want output to be one token or two token
        uint256 amount0In = balance0 > reserve0 - amount0Out
            ? balance0 - (reserve0 - amount0Out)
            : 0;
        uint256 amount1In = balance1 > reserve1 - amount1Out
            ? balance1 - (reserve1 - amount1Out)
            : 0;

        if (amount0In == 0 && amount1In == 0) revert InsufficientInputAmount();

        // Adjusted = balance before swap - swap fee; fee stays in the contract
        // all data mul 1000
        uint256 balance0Adjusted = (balance0 * 1000) - (amount0In * 3);
        uint256 balance1Adjusted = (balance1 * 1000) - (amount1In * 3);

        // constant k checking
        if (
            balance0Adjusted * balance1Adjusted <
            uint256(reserve0_) * uint256(reserve1_) * (1000**2)
        ) revert InvalidK();

        _update(balance0, balance1, reserve0_, reserve1_);

        emit Swap(msg.sender, amount0Out, amount1Out, to);
    }

    // synce state varialbe with token balance and also update cumulated price
    function sync() public {
        (uint112 reserve0_, uint112 reserve1_, ) = getReserves();
        _update(
            IERC20(token0).balanceOf(address(this)),
            IERC20(token1).balanceOf(address(this)),
            reserve0_,
            reserve1_
        );
    }

    function getReserves()
        public
        view
        returns (
            uint112,
            uint112,
            uint32
        )
    {
        return (reserve0, reserve1, blockTimestampLast);
    }

    //
    //
    //
    //  PRIVATE
    //
    //
    //
    // update record reserves with balance also update cumulated price and lastBlockTime
    function _update(
        uint256 balance0,
        uint256 balance1,
        uint112 reserve0_,
        uint112 reserve1_
    ) private {
        if (balance0 > type(uint112).max || balance1 > type(uint112).max)
            revert BalanceOverflow();

        unchecked {
            uint32 timeElapsed = uint32(block.timestamp) - blockTimestampLast;

            if (timeElapsed > 0 && reserve0_ > 0 && reserve1_ > 0) {
                // cumulate with price*time
                price0CumulativeLast +=
                    uint256(UQ112x112.encode(reserve1_).uqdiv(reserve0_)) *
                    timeElapsed;
                price1CumulativeLast +=
                    uint256(UQ112x112.encode(reserve0_).uqdiv(reserve1_)) *
                    timeElapsed;
            }
        }

        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = uint32(block.timestamp);

        emit Sync(reserve0, reserve1);
    }

    function _safeTransfer(
        address token,
        address to,
        uint256 value
    ) private {
        // cannot call token.transfer directly, since some erc20 token contract does not provide return value for transfer function
        // by using lowlevel call function, we can check the result
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSignature("transfer(address,uint256)", to, value)
        );
        if (!success || (data.length != 0 && !abi.decode(data, (bool))))
            revert TransferFailed();
    }
}
