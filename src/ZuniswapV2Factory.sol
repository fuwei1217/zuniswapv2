// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.10;

import "./ZuniswapV2Pair.sol";
import "./interfaces/IZuniswapV2Pair.sol";

contract ZuniswapV2Factory {
    error IdenticalAddresses();
    error PairExists();
    error ZeroAddress();

    event PairCreated(
        address indexed token0,
        address indexed token1,
        address pair,
        uint256
    );

    mapping(address => mapping(address => address)) public pairs;
    address[] public allPairs;

    function createPair(address tokenA, address tokenB)
        public
        returns (address pair)
    {
        if (tokenA == tokenB) revert IdenticalAddresses();

        // sort address
        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);

        if (token0 == address(0)) revert ZeroAddress();

        if (pairs[token0][token1] != address(0)) revert PairExists();

        // the bytecode for contract creation, often used by create2
        bytes memory bytecode = type(ZuniswapV2Pair).creationCode;

        // salt encode both token0 and token1 address, so the address can be calculated knowing the token addresses
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            // according to the article , first 32 bytes befroe bytecode is the length of bytecode
            // 0 is the value sent to the contract
            // so add(bytecode, 32) is a pointer to the actual start of bytecode
            // mload(bytecode), 32 bytes lenght of bytecode
            // the parameter for create2 is : value, offset, size, salt
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }

        IZuniswapV2Pair(pair).initialize(token0, token1);

        pairs[token0][token1] = pair;
        // why need this?
        pairs[token1][token0] = pair;
        allPairs.push(pair);

        emit PairCreated(token0, token1, pair, allPairs.length);
    }
}
