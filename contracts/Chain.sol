//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "./interfaces/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract Chain is Ownable, ReentrancyGuard {
    event Invested(address indexed investor, uint256 timestamp);
    event Withdrawn(address indexed withdrawer, uint256 amount, uint256 timestamp);
    event Reward(address indexed user, uint256 amount);

    struct User {
        uint256 deposited;
        uint256 timestamp;
        uint256 referralReward;
        uint256 reward;
        uint256 claimed;
        address addr;
        uint256 longestCount;
        uint256 referredCount;
        uint256 directCount;
        address referred;
    }

    struct UserPrivateData {
        uint256 referalDeposited;
        uint32 directRefrralTime;
        mapping(address => uint8) shareRatio;
    }

    mapping(address => User) private users;
    mapping(address => UserPrivateData) private userPrivateData;

    mapping(address => bool) public blacklist;
    mapping(address => bool) public canWithdraw;

    uint24 private constant DAY = 86400;
    bool public thirtyDayRewardPolicy;

    mapping(uint16 => uint256) private collections;
    uint256 private immutable decimal;
    uint256 private startTime;
    address public treasurer;
    IERC20 public immutable token;

    constructor(IERC20 _token, address _treasurer) {
        treasurer = _treasurer;
        token = _token;
        startTime = (block.timestamp/DAY) * DAY;
        decimal = _token.decimals();
    }

    function blacklistUser(address _add, bool _blacklist) external onlyOwner {
        require(blacklist[_add] != _blacklist, "invalid");
        blacklist[_add] = _blacklist;
    }

    function blacklistUserWithdrawal(address _add, bool _blacklist) external onlyOwner {
        require(canWithdraw[_add] != _blacklist, "invalid");
        canWithdraw[_add] = _blacklist;
    }

    function setTreasurer(address _treasurer) public onlyOwner {
        require(_treasurer != address(0), "zero address");
        treasurer = _treasurer;
    }

    function addReferral(address addr, uint256 amount, address referral) external nonReentrant {
        require(users[addr].addr != address(0), "already a member");
        require(users[referral].deposited > 0 || referral == address(0), "Invalid referrral");

        uint256 requiredAmountInWei = _invest(addr, amount, referral);

        users[addr] = User({
            deposited: requiredAmountInWei,
            timestamp: block.timestamp,
            referralReward: 0,
            reward: 0,
            claimed: 0,
            longestCount: 0,
            addr: addr,
            referredCount: 0,
            directCount: 0,
            referred: referral
        });

        _distributeBonus(referral, requiredAmountInWei);
    }

    function _distributeBonus(address link, uint256 amountInWei) internal {
        address userLink = link;
        uint32 currentTime = uint32(block.timestamp);
        User storage user;
        uint8 bonusPercentage;
        uint bonus;
        for(uint i = 0; i < 40; i++) {
            if (userLink == address(0)) break;
            user = users[userLink];
            if(i==0) {
                bonusPercentage = 20;
            } else if (i==1) {
                bonusPercentage = 10;
            } else if (i==2) {
                bonusPercentage = 5;
            } else if (i==3) {
                bonusPercentage = 4;
            } else {
                bonusPercentage = 2;
            }

            bonus = (amountInWei * bonusPercentage)/100;
            if ((!thirtyDayRewardPolicy || (((currentTime - userPrivateData[link].directRefrralTime)/DAY) <= 30)) && ((user.directCount * 4)>i)) user.referralReward += bonus;
            userLink = user.referred;
            if (i == user.longestCount) user.longestCount += 1;
            user.referredCount++;
        }
    }

    function topup(address addr, uint256 amount) external nonReentrant {
        require(users[addr].deposited > 0, "Invalid address");
        uint256 requiredAmountInWei = _invest(addr, amount, users[addr].referred);

        User storage user = users[addr];

        user.reward = _totalReward(user.addr);

        user.deposited += requiredAmountInWei;
        user.timestamp = block.timestamp;

        _distributeBonus(user.addr, requiredAmountInWei);
    }

    function _invest(address addr, uint256 amount, address link) internal returns(uint256) {
        require(amount >= 100, "Too Low");
        uint256 amountInWei = amount * (10**decimal);
        uint256 requiredAmountInWei = ((amount / 100) * 100) * (10**decimal);

        uint16 index = uint16((block.timestamp - startTime)/DAY);

        uint256 previousBalance = token.balanceOf(address(this));
        token.transferFrom(msg.sender, address(this), amountInWei);
        uint256 newBalance = token.balanceOf(address(this));

        require(
            (previousBalance + requiredAmountInWei) <= newBalance,
            "Insuff"
        );

        if (link != address(0)) {
            userPrivateData[link].directRefrralTime = uint32(block.timestamp);
            users[link].directCount += 1;
        }

        collections[index] += requiredAmountInWei;
        uint256 leftover = newBalance - (previousBalance + requiredAmountInWei);
        if (leftover > 0) token.transfer(msg.sender, leftover);

        emit Invested(addr, block.timestamp);
        return requiredAmountInWei;
    }

    function _totalReward(address link) internal view returns(uint256) {
        User storage user = users[link];
        uint256 dailyReward = (user.deposited * 5)/1000;
        uint16 time = uint16((block.timestamp - user.timestamp)/DAY);

        return ((dailyReward * time) + user.reward);
    }

    function myRewards(address addr) public view returns(uint256) {
        User memory user = users[addr];
        if (blacklist[addr] == true) return 0;
        uint256 reward = _totalReward(addr);
        return reward - user.claimed;
    }

    function claim() public {
        require(blacklist[msg.sender] == false, "blacklisted");
        User storage user = users[msg.sender];
        require(user.deposited != 0, "No Deposits");
        require(((block.timestamp - user.timestamp)/DAY) > 0, "Too Early");
        
        user.reward = _totalReward(user.addr);
        uint256 amountToClaim = user.reward + user.referralReward - user.claimed;
        user.claimed += amountToClaim;
    
        token.transfer(msg.sender, amountToClaim);

        emit Reward(user.addr, amountToClaim);
    }

    // NOTICE: Here user can withdraw any sum of amount, not compulsory 
    // to be the multiple of 100
    function withdraw(uint256 amount) public nonReentrant {
        require(canWithdraw[msg.sender] == true || msg.sender == treasurer, "Not Allowed");
        uint256 amountInWei = amount * (10 ** decimal);
        User memory user = users[msg.sender];
        if (msg.sender == treasurer) {
            _withdraw(treasurer, amountInWei);
        } else {
            require(user.deposited >= amount, "Low Balance");
            require(amount >= 10, "Too Low");

            uint256 adminAmountInWei = (amountInWei / 10);
            uint256 userAmountInWei = amountInWei - adminAmountInWei;

            uint256 rewardsAccumulated;

            if (blacklist[msg.sender] == false) rewardsAccumulated = _totalReward(user.addr);
            else rewardsAccumulated = user.reward;

            user.deposited -= amountInWei;
            user.timestamp = block.timestamp;
            user.reward = rewardsAccumulated;

            _withdraw(treasurer, adminAmountInWei);
            _withdraw(msg.sender, userAmountInWei);
        }
    }

    function withdrawAll() external nonReentrant {
        if (msg.sender == treasurer) {
            uint256 totalAmount = token.balanceOf(address(this));
            _withdraw(treasurer, totalAmount);
        } else {
            withdraw(users[msg.sender].deposited);
        }
    }

    function _withdraw(address withdrawer, uint256 amount) internal {
        require(amount <= token.balanceOf(address(this)), "Insuff");

        token.transfer(withdrawer, amount);
        emit Withdrawn(withdrawer, amount, block.timestamp);
    }

    function dailyCollection(uint16 index) public view onlyOwner returns(uint256){
        return collections[index];
    }

    function userDetails(address _add) public view returns (
        uint256 deposited,
        uint256 timestamp,
        uint256 referralReward,
        uint256 claimed,
        uint256 reward,
        uint256 longestCount,
        address addr,
        uint256 directCount,
        uint256 referredCount,
        address referred
    ) {
        User memory user = users[_add];
        deposited = user.deposited;
        timestamp = user.timestamp;
        referralReward = user.referralReward;
        reward = user.reward;
        claimed = user.claimed;
        addr = user.addr;
        longestCount = user.longestCount;
        directCount = user.directCount;
        referredCount = user.referredCount;
        referred = user.referred;
    }
}