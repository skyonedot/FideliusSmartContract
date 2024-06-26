// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface TokenBankInterface {
    function issue(
        address token_addr,
        address payable _to,
        uint _amount
    ) external returns (bool success);

    function balance(address erc20_token_addr) external view returns (uint);
}
