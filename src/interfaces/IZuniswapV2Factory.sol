// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.10;

interface IZuniswapV2Factory {
    // return pair address with token0 and token 1 address
    function pairs(address, address) external pure returns (address);

    // create pair given token 0 and token 1 address and returns pair address
    function createPair(address, address) external returns (address);
}
