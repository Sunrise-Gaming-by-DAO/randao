// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";


contract RandaoStaking is Initializable, OwnableUpgradeable {

    struct StakingInfo {
        uint amount;
        uint lastStakeTime;
    }

    mapping(address => StakingInfo) public stakes;
    IERC20 public TOKEN;            // should be SUNC token
    uint public MIN_STAKE_AMOUNT;   // minimum amount to stake to be able to participate into the RANDAO protocol

    event Stake(address account, uint amount);
    event Withdraw(address account, uint amount);
    event MinStakeAmountChanged(uint value);

    constructor() {
        _disableInitializers();
    }

    function initialize(IERC20 token, uint minAmount) public initializer {
        __Ownable_init();

        MIN_STAKE_AMOUNT = minAmount;
        TOKEN = token;
    }

    function setMinStakeAmount(uint value) public onlyOwner {
        if (value == MIN_STAKE_AMOUNT) 
            return;
        MIN_STAKE_AMOUNT = value;
        emit MinStakeAmountChanged(value);
    }

    function amountOf(address account) public view returns(uint) {
        return stakes[account].amount;
    }

    function stake(uint amount) public {
        require(amount > 0, "RandaoStaking: amount must greater than 0");

        StakingInfo storage info = stakes[msg.sender];

        uint newAccumulatedStake = info.amount + amount;
        if (newAccumulatedStake > MIN_STAKE_AMOUNT)
            amount = MIN_STAKE_AMOUNT > info.amount ? MIN_STAKE_AMOUNT - info.amount : 0;

        if (amount == 0)
            return;

        TOKEN.transferFrom(msg.sender, address(this), amount);

        info.amount += amount;
        info.lastStakeTime = block.timestamp;

        emit Stake(msg.sender, amount);
    }

    function withdraw(uint amount) public {
    StakingInfo storage info = stakes[msg.sender];

    if (amount == 0 && info.amount > MIN_STAKE_AMOUNT)
        amount = info.amount - MIN_STAKE_AMOUNT;

    if (amount > info.amount)
        amount = info.amount;

    if (amount == 0)
        return;

    TOKEN.transfer(msg.sender, amount);

    info.amount -= amount;

    emit Withdraw(msg.sender, amount);
    }
}