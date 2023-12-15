// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.10;

import "./interfaces/IZuniswapV2Factory.sol";
import "./interfaces/IZuniswapV2Pair.sol";
import {ZuniswapV2Pair} from "./ZuniswapV2Pair.sol";

library ZuniswapV2Library {
    error InsufficientAmount();
    error InsufficientLiquidity();
    error InvalidPath();

    function getReserves(
        address factoryAddress,
        address tokenA,
        address tokenB
    ) public returns (uint256 reserveA, uint256 reserveB) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        (uint256 reserve0, uint256 reserve1, ) = IZuniswapV2Pair(
            pairFor(factoryAddress, token0, token1)
        ).getReserves();
        // return reserver in the same order as input since order may have changed
        (reserveA, reserveB) = tokenA == token0
            ? (reserve0, reserve1)
            : (reserve1, reserve0);
    }

    // amount out / in = amount out /in 
    function quote(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) public pure returns (uint256 amountOut) {
        if (amountIn == 0) revert InsufficientAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();

        return (amountIn * reserveOut) / reserveIn;
    }

    // sort token by address
    function sortTokens(address tokenA, address tokenB)
        internal
        pure
        returns (address token0, address token1)
    {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    // calculate pair address, since it is created by create2
    function pairFor(
        address factoryAddress,
        address tokenA,
        address tokenB
    ) internal pure returns (address pairAddress) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pairAddress = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            factoryAddress,
                            keccak256(abi.encodePacked(token0, token1)),
                            keccak256(type(ZuniswapV2Pair).creationCode)
                        )
                    )
                )
            )
        );
    }

    // use constant product to calculate output, take fee into account
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) public pure returns (uint256) {
        if (amountIn == 0) revert InsufficientAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();

        //   (x + x') * (y - y') = xy
        //   xy - xy' + x'y -x'y'= xy
        //   x'y = y'(x+x')
        //   y' = x'y/(x+x')
        //   x' is (1 - 0.3%)* input
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 1000) + amountInWithFee;

        return numerator / denominator;
    }

    // get amounts with path, format path is like : token a, token b, token c, token d, if you want to swap a for d with b,c as intermediate token
    // the path here is full path and could be calculated off-chain
    function getAmountsOut(
        address factory,
        uint256 amountIn,
        address[] memory path
    ) public returns (uint256[] memory) {
        if (path.length < 2) revert InvalidPath();
        // NOTE in memory array must have fixed length and cannot grow(evm need to know the memory used for gas calculation)
        uint256[] memory amounts = new uint256[](path.length);
        amounts[0] = amountIn;

        for (uint256 i; i < path.length - 1; i++) {
            (uint256 reserve0, uint256 reserve1) = getReserves(
                factory,
                path[i],
                path[i + 1]
            );
            // by putting output in amounts and use it as next input 
            amounts[i + 1] = getAmountOut(amounts[i], reserve0, reserve1);
        }

        return amounts;
    }

    // provide user with more functionality it is similar as getAmountOut but in reserve order
    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) public pure returns (uint256) {
        if (amountOut == 0) revert InsufficientAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();

        //   (x + x') * (y - y') = xy
        //   xy - xy' + x'y -x'y'= xy
        //   x'(y-y') = xy'
        //   x' = xy'/(y-y')
        //   y' is expected output and has no fee, fee is for input
        //   0.997 * input = x', that's why denominator need plus 997

        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;

        //  plus 1 to make sure we get expected output at the cost of have slightly higher input since rounded down
        return (numerator / denominator) + 1;
    }

    // similar to getAmountOut, but calculate in reverse order
    function getAmountsIn(
        address factory,
        uint256 amountOut,
        address[] memory path
    ) public returns (uint256[] memory) {
        if (path.length < 2) revert InvalidPath();
        uint256[] memory amounts = new uint256[](path.length);
        amounts[amounts.length - 1] = amountOut;

        for (uint256 i = path.length - 1; i > 0; i--) {
            (uint256 reserve0, uint256 reserve1) = getReserves(
                factory,
                path[i - 1],
                path[i]
            );
            amounts[i - 1] = getAmountIn(amounts[i], reserve0, reserve1);
        }

        return amounts;
    }
}
