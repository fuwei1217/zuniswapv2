// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.10;

import "./interfaces/IZuniswapV2Factory.sol";
import "./interfaces/IZuniswapV2Pair.sol";
import "./ZuniswapV2Library.sol";

contract ZuniswapV2Router {
    error ExcessiveInputAmount();
    error InsufficientAAmount();
    error InsufficientBAmount();
    error InsufficientOutputAmount();
    error SafeTransferFailed();

    IZuniswapV2Factory factory;

    // interface is needed to call functions
    constructor(address factoryAddress) {
        factory = IZuniswapV2Factory(factoryAddress);
    }

    // the LP token price is always changing, so we give the max and min value we expected.
    // in theory amount a and b should be in the same ration as the current reserve ratio. but since the reserve ratio may change 
    // so we cannot know which is sufficient so need to return the value of token a, b we deposited and liquidity minted.
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired, // max token a amount
        uint256 amountBDesired, // max token b amount
        uint256 amountAMin, // min tokan a amount
        uint256 amountBMin, // min token b amount
        address to
    )
        public
        returns (
            uint256 amountA,// deposited token a amount
            uint256 amountB, // deposited token b amount
            uint256 liquidity // minted liquidity
        )
    {
        // pair no exist, so create a new pair
        if (factory.pairs(tokenA, tokenB) == address(0)) {
            factory.createPair(tokenA, tokenB);
        }

        // calculated amount to deposit
        (amountA, amountB) = _calculateLiquidity(
            tokenA,
            tokenB,
            amountADesired,
            amountBDesired,
            amountAMin,
            amountBMin
        );
        address pairAddress = ZuniswapV2Library.pairFor(
            address(factory),
            tokenA,
            tokenB
        );
        // transfer tokens and then call pair.mint for minting LP token
        // transfer tokens from msg.sender to pair contract, why not directly call transfer or send?
        // note that this function runs in the context of router contract, so if call transfer, it will payer would be the contract!!! not the user
        // but in mint, since the erc20 is managed by pari contract, so it can directly all transfer
        // in other word, if call transfer, the msg.sender will change to router contract itself.

        // in test, we can see approve is called first then addLiquidity is called.
        _safeTransferFrom(tokenA, msg.sender, pairAddress, amountA);
        _safeTransferFrom(tokenB, msg.sender, pairAddress, amountB);
        liquidity = IZuniswapV2Pair(pairAddress).mint(to);
    }

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin, // min expected amount 
        uint256 amountBMin, // min expected amount
        address to
    ) public returns (uint256 amountA, uint256 amountB) {
        address pair = ZuniswapV2Library.pairFor(
            address(factory),
            tokenA,
            tokenB
        );
        // transfer LP token back to pair contract
        IZuniswapV2Pair(pair).transferFrom(msg.sender, pair, liquidity);
        // burn returns the amount of token, need to check with expected min token, otherwise reverse
        (amountA, amountB) = IZuniswapV2Pair(pair).burn(to);
        if (amountA < amountAMin) revert InsufficientAAmount();
        if (amountA < amountBMin) revert InsufficientBAmount();
    }

    // given exact input amount, and min acceptable out amount, try to swap
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to
    ) public returns (uint256[] memory amounts) {
        // getAmountsOut will return the out amounts on path, last one would the amountOut 
        amounts = ZuniswapV2Library.getAmountsOut(
            address(factory),
            amountIn,
            path
        );
        if (amounts[amounts.length - 1] < amountOutMin)
            revert InsufficientOutputAmount();

        // transfer amount in to the first pair in path
        _safeTransferFrom(
            path[0],
            msg.sender,
            ZuniswapV2Library.pairFor(address(factory), path[0], path[1]),
            amounts[0]
        );
        // swap will iterate the path and use output from previous pair as output for the next pair
        _swap(amounts, path, to);
    }

    // give exact output amount, and max acceptable in amount, try to swap
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to
    ) public returns (uint256[] memory amounts) {
        // getAmountIn calc required input for each pair in reverse order
        amounts = ZuniswapV2Library.getAmountsIn(
            address(factory),
            amountOut,
            path
        );
        // here should be a bug, amounts[0] should be the first input for first pair, so need to check amounts[0] instead
        if (amounts[amounts.length - 1] > amountInMax)
            revert ExcessiveInputAmount();
        // we checked the condition from reserve order, but still the swap is in the same order as normal
        _safeTransferFrom(
            path[0],
            msg.sender,
            ZuniswapV2Library.pairFor(address(factory), path[0], path[1]),
            amounts[0]
        );
        _swap(amounts, path, to);
    }

    //
    //
    //
    //  PRIVATE
    //
    //
    //


    // amounts store each input amount for pair
    function _swap(
        uint256[] memory amounts,
        address[] memory path,
        address to_
    ) internal {
        for (uint256 i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0, ) = ZuniswapV2Library.sortTokens(input, output);
            uint256 amountOut = amounts[i + 1];
            // amountOut may be amount0 or amount1, here is check which one is it
            (uint256 amount0Out, uint256 amount1Out) = input == token0
                ? (uint256(0), amountOut)
                : (amountOut, uint256(0));

            // to is the address we swap the output to, if it is not last pair then it should be next pair address, otherwise it should be the to address
            address to = i < path.length - 2
                ? ZuniswapV2Library.pairFor(
                    address(factory),
                    output,
                    path[i + 2]
                )
                : to_;

            // since we already calculated each input, so we can just can swap and know it will be ok
            IZuniswapV2Pair(
                ZuniswapV2Library.pairFor(address(factory), input, output)
            ).swap(amount0Out, amount1Out, to, "");
        }
    }

    function _calculateLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal returns (uint256 amountA, uint256 amountB) {
        (uint256 reserveA, uint256 reserveB) = ZuniswapV2Library.getReserves(
            address(factory),
            tokenA,
            tokenB
        );

        // no previous reserve, it is the initial liquidity supply, so take all tokens 
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            // calc with max token a, the a/b should be in the same ratio as reserve a/ reserve b.
            uint256 amountBOptimal = ZuniswapV2Library.quote(
                amountADesired,
                reserveA,
                reserveB
            );
            // make sure optimal token b amount is in the valid scope
            if (amountBOptimal <= amountBDesired) {
                // cannot be smaller than min
                if (amountBOptimal <= amountBMin) revert InsufficientBAmount();
                // in the valid scope, return calculated value
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = ZuniswapV2Library.quote(
                    amountBDesired,
                    reserveB,
                    reserveA
                );
                assert(amountAOptimal <= amountADesired);

                if (amountAOptimal <= amountAMin) revert InsufficientAAmount();
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    function _safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 value
    ) private {
        // use low-level call because some implementation of erc20 may not return anything for transferFrom
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSignature(
                "transferFrom(address,address,uint256)",
                from,
                to,
                value
            )
        );
        if (!success || (data.length != 0 && !abi.decode(data, (bool))))
            revert SafeTransferFailed();
    }
}
