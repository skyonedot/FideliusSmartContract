// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AddressArray} from "contracts/plugins/eth-contracts/utils/AddressArray.sol";

import {IPaymentProxy} from "./interface/PaymentProxyInterface.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

//import "forge-std/Test.sol";

interface PApproveAndCallFallBack {
    function receiveApproval(
        address from,
        uint256 _amount,
        address _token,
        bytes memory _data
    ) external;
}

interface PTransferEventCallBack {
    function onTransfer(address _from, address _to, uint256 _amount) external;
}

abstract contract PERCBaseUpgradable is Initializable {
    string public name; //The Token's name: e.g. GTToken
    uint8 public decimals; //Number of decimals of the smallest unit
    string public symbol; //An identifier: e.g. REP
    string public version = "GTT_0.1"; //An arbitrary versioning scheme

    using AddressArray for address[];
    address[] public transferListeners;
    address public payment_proxy;
    bool public proxy_required;

    ////////////////
    // Events
    ////////////////
    event Transfer(address indexed _from, address indexed _to, uint256 _amount);
    event Approval(
        address indexed _owner,
        address indexed _spender,
        uint256 _amount
    );

    event NewTransferListener(address _addr);
    event RemoveTransferListener(address _addr);

    /// @dev `Checkpoint` is the structure that attaches a block number to a
    ///  given value, the block number attached is the one that last changed the
    ///  value
    struct Checkpoint {
        // `fromBlock` is the block number that the value was generated from
        uint128 fromBlock;
        // `value` is the amount of tokens at a specific block number
        uint128 value;
    }

    // `parentToken` is the Token address that was cloned to produce this token;
    //  it will be 0x0 for a token that was not cloned
    PERCBaseUpgradable public parentToken;

    // `parentSnapShotBlock` is the block number from the Parent Token that was
    //  used to determine the initial distribution of the Clone Token
    uint public parentSnapShotBlock;

    // `creationBlock` is the block number that the Clone Token was created
    uint public creationBlock;

    // `balances` is the map that tracks the balance of each address, in this
    //  contract when the balance changes the block number that the change
    //  occurred is also included in the map
    mapping(address => Checkpoint[]) balances;

    // `allowed` tracks any extra transfer rights as in all PERC tokens
    mapping(address => mapping(address => uint256)) allowed;

    // Tracks the history of the `totalSupply` of the token
    Checkpoint[] totalSupplyHistory;

    // Flag that determines if the token is transferable or not.
    bool public transfersEnabled;

    ////////////////
    // Constructor
    ////////////////

    // /// @notice Constructor to create a PERCBaseUpgradable
    // /// @param _parentToken Address of the parent token, set to 0x0 if it is a
    // ///  new token
    // /// @param _parentSnapShotBlock Block of the parent token that will
    // ///  determine the initial distribution of the clone token, set to 0 if it
    // ///  is a new token
    // /// @param _tokenName Name of the new token
    // /// @param _decimalUnits Number of decimals of the new token
    // /// @param _tokenSymbol Token Symbol for the new token
    // /// @param _transfersEnabled If true, tokens will be able to be transferred
    // function initialize(
    //     PERCBaseUpgradable _parentToken,
    //     uint _parentSnapShotBlock,
    //     string memory _tokenName,
    //     uint8 _decimalUnits,
    //     string memory _tokenSymbol,
    //     bool _transfersEnabled,
    //     address _cproxy
    // ) public virtual initializer {
    //     __PERCBaseUpgradable_init(
    //         _parentToken,
    //         _parentSnapShotBlock,
    //         _tokenName,
    //         _decimalUnits,
    //         _tokenSymbol,
    //         _transfersEnabled,
    //         _cproxy
    //     );
    // }

    function __PERCBaseUpgradable_init(
        PERCBaseUpgradable _parentToken,
        uint _parentSnapShotBlock,
        string memory _tokenName,
        uint8 _decimalUnits,
        string memory _tokenSymbol,
        bool _transfersEnabled,
        address _cproxy
    ) internal onlyInitializing {
        name = _tokenName; // Set the name
        decimals = _decimalUnits; // Set the decimals
        symbol = _tokenSymbol; // Set the symbol
        parentToken = _parentToken;
        parentSnapShotBlock = _parentSnapShotBlock;
        transfersEnabled = _transfersEnabled;
        creationBlock = block.number;
        payment_proxy = _cproxy;
        proxy_required = true;
    }

    ///////////////////
    // PERC Methods
    ///////////////////

    /// @notice Send `_amount` tokens to `_to` from `msg.sender`
    /// @param _to The address of the recipient
    /// @param _amount The amount of tokens to be transferred
    /// @return success Whether the transfer was successful or not
    function transfer(
        address _to,
        uint256 _amount
    ) public returns (bool success) {
        require(transfersEnabled);
        IPaymentProxy(payment_proxy).transferRequest(
            address(this),
            msg.sender,
            _to,
            _amount
        );
        return doTransfer(msg.sender, _to, _amount);
    }

    modifier onlyProxy() {
        require(msg.sender == payment_proxy, "only for confirm proxy");
        _;
    }

    function confirmTransfer(
        address _to,
        uint256 _amount
    ) public onlyProxy returns (bool success) {
        require(transfersEnabled);
        if (_to != address(0)) {
            return doTransfer(msg.sender, _to, _amount);
        } else {
            return _destroyTokens(msg.sender, _amount);
        }
    }

    /// @notice Send `_amount` tokens to `_to` from `_from` on the condition it
    ///  is approved by `_from`
    /// @param _from The address holding the tokens being transferred
    /// @param _to The address of the recipient
    /// @param _amount The amount of tokens to be transferred
    /// @return success True if the transfer was successful
    function transferFrom(
        address _from,
        address _to,
        uint256 _amount
    ) public returns (bool success) {
        require(transfersEnabled);

        // The standard ERC 20 transferFrom functionality
        if (allowed[_from][msg.sender] < _amount) return false;
        allowed[_from][msg.sender] -= _amount;
        IPaymentProxy(payment_proxy).transferRequest(
            address(this),
            _from,
            _to,
            _amount
        );
        return doTransfer(_from, _to, _amount);
    }

    event TemporaryTransfer(
        bytes32 _hash,
        address _from,
        address _to,
        uint256 _amount
    );

    /// @dev This is the actual transfer function in the token contract, it can
    ///  only be called by other functions in this contract.
    /// @param _from The address holding the tokens being transferred
    /// @param _to The address of the recipient
    /// @param _amount The amount of tokens to be transferred
    /// @return True if the transfer was successful
    function doTransfer(
        address _from,
        address _to,
        uint _amount
    ) internal returns (bool) {
        if (_amount == 0) {
            return true;
        }
        require(parentSnapShotBlock < block.number);
        // Do not allow transfer to 0x0 or the token contract itself
        require((_to != address(0)) && (_to != address(this)));
        // If the amount being transfered is more than the balance of the
        //  account the transfer returns false
        uint256 previousBalanceFrom = balanceOfAt(_from, block.number);
        if (previousBalanceFrom < _amount) {
            return false;
        }
        // First update the balance array with the new value for the address
        //  sending the tokens
        updateValueAtNow(balances[_from], previousBalanceFrom - _amount);
        // Then update the balance array with the new value for the address
        //  receiving the tokens
        uint256 previousBalanceTo = balanceOfAt(_to, block.number);
        require(previousBalanceTo + _amount >= previousBalanceTo); // Check for overflow
        updateValueAtNow(balances[_to], previousBalanceTo + _amount);
        // An event to make the transfer easy to find on the blockchain
        if (!IPaymentProxy(payment_proxy).getTxLock()) {
            emit Transfer(_from, _to, _amount);
        } else {
            emit TemporaryTransfer(
                IPaymentProxy(payment_proxy).currentTransferRequestHash(),
                _from,
                _to,
                _amount
            );
        }
        onTransferDone(_from, _to, _amount);
        return true;
    }

    /// @param _owner The address that's balance is being requested
    /// @return balance The balance of `_owner` at the current block
    function balanceOf(address _owner) public view returns (uint256 balance) {
        return balanceOfAt(_owner, block.number);
    }

    /// @notice `msg.sender` approves `_spender` to spend `_amount` tokens on
    ///  its behalf. This is a modified version of the PERC approve function
    ///  to be a little bit safer
    /// @param _spender The address of the account able to transfer the tokens
    /// @param _amount The amount of tokens to be approved for transfer
    /// @return success True if the approval was successful
    function approve(
        address _spender,
        uint256 _amount
    ) public returns (bool success) {
        require(transfersEnabled);

        // To change the approve amount you first have to reduce the addresses`
        //  allowance to zero by calling `approve(_spender,0)` if it is not
        //  already 0 to mitigate the race condition described here:
        //  https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
        require((_amount == 0) || (allowed[msg.sender][_spender] == 0));

        allowed[msg.sender][_spender] = _amount;
        emit Approval(msg.sender, _spender, _amount);
        return true;
    }

    /// @dev This function makes it easy to read the `allowed[]` map
    /// @param _owner The address of the account that owns the token
    /// @param _spender The address of the account able to transfer the tokens
    /// @return remaining Amount of remaining tokens of _owner that _spender is allowed
    ///  to spend
    function allowance(
        address _owner,
        address _spender
    ) public view returns (uint256 remaining) {
        return allowed[_owner][_spender];
    }

    /// @notice `msg.sender` approves `_spender` to send `_amount` tokens on
    ///  its behalf, and then a function is triggered in the contract that is
    ///  being approved, `_spender`. This allows users to use their tokens to
    ///  interact with contracts in one function call instead of two
    /// @param _spender The address of the contract able to transfer the tokens
    /// @param _amount The amount of tokens to be approved for transfer
    /// @return success True if the function call was successful
    function approveAndCall(
        PApproveAndCallFallBack _spender,
        uint256 _amount,
        bytes memory _extraData
    ) public returns (bool success) {
        require(approve(address(_spender), _amount));

        _spender.receiveApproval(
            msg.sender,
            _amount,
            address(this),
            _extraData
        );

        return true;
    }

    /// @dev This function makes it easy to get the total number of tokens
    /// @return The total number of tokens
    function totalSupply() public view returns (uint) {
        return totalSupplyAt(block.number);
    }

    ////////////////
    // Query balance and totalSupply in History
    ////////////////

    /// @dev Queries the balance of `_owner` at a specific `_blockNumber`
    /// @param _owner The address from which the balance will be retrieved
    /// @param _blockNumber The block number when the balance is queried
    /// @return The balance at `_blockNumber`
    function balanceOfAt(
        address _owner,
        uint _blockNumber
    ) public view returns (uint) {
        // These next few lines are used when the balance of the token is
        //  requested before a check point was ever created for this token, it
        //  requires that the `parentToken.balanceOfAt` be queried at the
        //  genesis block for that token as this contains initial balance of
        //  this token
        if (
            (balances[_owner].length == 0) ||
            (balances[_owner][0].fromBlock > _blockNumber)
        ) {
            if (address(parentToken) != address(0)) {
                return
                    parentToken.balanceOfAt(
                        _owner,
                        min(_blockNumber, parentSnapShotBlock)
                    );
            } else {
                // Has no parent
                return 0;
            }

            // This will return the expected balance during normal situations
        } else {
            return getValueAt(balances[_owner], _blockNumber);
        }
    }

    /// @notice Total amount of tokens at a specific `_blockNumber`.
    /// @param _blockNumber The block number when the totalSupply is queried
    /// @return The total amount of tokens at `_blockNumber`
    function totalSupplyAt(uint _blockNumber) public view returns (uint) {
        // These next few lines are used when the totalSupply of the token is
        //  requested before a check point was ever created for this token, it
        //  requires that the `parentToken.totalSupplyAt` be queried at the
        //  genesis block for this token as that contains totalSupply of this
        //  token at this block number.
        if (
            (totalSupplyHistory.length == 0) ||
            (totalSupplyHistory[0].fromBlock > _blockNumber)
        ) {
            if (address(parentToken) != address(0)) {
                return
                    parentToken.totalSupplyAt(
                        min(_blockNumber, parentSnapShotBlock)
                    );
            } else {
                return 0;
            }

            // This will return the expected totalSupply during normal situations
        } else {
            return getValueAt(totalSupplyHistory, _blockNumber);
        }
    }

    ////////////////
    // Generate and destroy tokens
    ////////////////

    /// @notice Generates `_amount` tokens that are assigned to `_owner`
    /// @param _owner The address that will be assigned the new tokens
    /// @param _amount The quantity of tokens generated
    /// @return True if the tokens are generated correctly
    function _generateTokens(
        address _owner,
        uint _amount
    ) internal returns (bool) {
        uint curTotalSupply = totalSupply();
        require(curTotalSupply + _amount >= curTotalSupply); // Check for overflow
        uint previousBalanceTo = balanceOf(_owner);

        require(previousBalanceTo + _amount >= previousBalanceTo); // Check for overflow

        updateValueAtNow(totalSupplyHistory, curTotalSupply + _amount);

        updateValueAtNow(balances[_owner], previousBalanceTo + _amount);

        if (!IPaymentProxy(payment_proxy).getTxLock()) {
            emit Transfer(address(0), _owner, _amount);
        } else {
            emit TemporaryTransfer(
                IPaymentProxy(payment_proxy).currentTransferRequestHash(),
                address(0),
                _owner,
                _amount
            );
        }

        onTransferDone(address(0), _owner, _amount);
        return true;
    }

    /// @notice Burns `_amount` tokens from `_owner`
    /// @param _owner The address that will lose the tokens
    /// @param _amount The quantity of tokens to burn
    /// @return True if the tokens are burned correctly
    function _destroyTokens(
        address _owner,
        uint _amount
    ) internal returns (bool) {
        uint curTotalSupply = totalSupply();
        require(curTotalSupply >= _amount);
        uint previousBalanceFrom = balanceOf(_owner);
        require(previousBalanceFrom >= _amount);
        updateValueAtNow(totalSupplyHistory, curTotalSupply - _amount);
        updateValueAtNow(balances[_owner], previousBalanceFrom - _amount);
        if (!IPaymentProxy(payment_proxy).getTxLock()) {
            emit Transfer(_owner, address(0), _amount);
        } else {
            emit TemporaryTransfer(
                IPaymentProxy(payment_proxy).currentTransferRequestHash(),
                _owner,
                address(0),
                _amount
            );
        }
        onTransferDone(_owner, address(0), _amount);
        return true;
    }

    ////////////////
    // Enable tokens transfers
    ////////////////

    /// @notice Enables token holders to transfer their tokens freely if true
    /// @param _transfersEnabled True if transfers are allowed in the clone
    function _enableTransfers(bool _transfersEnabled) internal {
        transfersEnabled = _transfersEnabled;
    }

    ////////////////
    // Internal helper functions to query and set a value in a snapshot array
    ////////////////

    /// @dev `getValueAt` retrieves the number of tokens at a given block number
    /// @param checkpoints The history of values being queried
    /// @param _block The block number to retrieve the value at
    /// @return The number of tokens being queried
    function getValueAt(
        Checkpoint[] storage checkpoints,
        uint _block
    ) internal view returns (uint) {
        if (checkpoints.length == 0) return 0;

        // Shortcut for the actual value
        if (_block >= checkpoints[checkpoints.length - 1].fromBlock)
            return checkpoints[checkpoints.length - 1].value;
        if (_block < checkpoints[0].fromBlock) return 0;

        // Binary search of the value in the array
        uint minn = 0;
        uint max = checkpoints.length - 1;
        while (max > minn) {
            uint mid = (max + minn + 1) / 2;
            if (checkpoints[mid].fromBlock <= _block) {
                minn = mid;
            } else {
                max = mid - 1;
            }
        }
        return checkpoints[minn].value;
    }

    /// @dev `updateValueAtNow` used to update the `balances` map and the
    ///  `totalSupplyHistory`
    /// @param checkpoints The history of data being updated
    /// @param _value The new number of tokens
    function updateValueAtNow(
        Checkpoint[] storage checkpoints,
        uint _value
    ) internal {
        if (
            (checkpoints.length == 0) ||
            (checkpoints[checkpoints.length - 1].fromBlock < block.number)
        ) {
            Checkpoint memory newCheckPoint;
            // = checkpoints[
            //     checkpoints.length + 1
            // ];
            newCheckPoint.fromBlock = uint128(block.number);
            newCheckPoint.value = uint128(_value);
            checkpoints.push(newCheckPoint);
        } else {
            Checkpoint storage oldCheckPoint = checkpoints[
                checkpoints.length - 1
            ];
            oldCheckPoint.value = uint128(_value);
        }
    }

    function onTransferDone(
        address _from,
        address _to,
        uint256 _amount
    ) internal {
        for (uint i = 0; i < transferListeners.length; i++) {
            PTransferEventCallBack t = PTransferEventCallBack(
                transferListeners[i]
            );
            t.onTransfer(_from, _to, _amount);
        }
    }

    function _addTransferListener(address _addr) internal {
        transferListeners.push(_addr);
        emit NewTransferListener(_addr);
    }

    function _removeTransferListener(address _addr) internal {
        transferListeners.remove(_addr);
        emit RemoveTransferListener(_addr);
    }

    /// @dev Helper function to return a min betwen the two uints
    function min(uint a, uint b) internal pure returns (uint) {
        return a < b ? a : b;
    }

    //function () external payable {
    //require(false, "cannot transfer ether to this contract");
    //}
}