// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

contract ReentrancyGuard {
    uint256 private _guardCounter;

    constructor() {
        _guardCounter = 1;
    }

    modifier nonReentrant() {
        _guardCounter += 1;
        uint256 localCounter = _guardCounter;
        _;
        require(
            localCounter == _guardCounter,
            "ReentrancyGuard: reentrant call"
        );
    }
}
