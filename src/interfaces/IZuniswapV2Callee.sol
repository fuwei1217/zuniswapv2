// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.10;

interface IZuniswapV2Callee {
    // callback function for flash swap, could do some checking if token has been loaned 
    // and make sure to repay before return
    function zuniswapV2Call(
        address sender,
        uint256 amount0Out,
        uint256 amount1Out,
        bytes calldata data
    ) external;
}
