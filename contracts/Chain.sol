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
        bytes32 link;
        uint referredCount;
        uint directCount;
        bytes32 referred;
    }

    mapping(bytes32 => User) private users;
    mapping(address => bytes32) public referralLink;
    mapping(address => bool) public blacklist;
    mapping(bytes32 => uint32) private directRefrralTime;

    uint24 private constant DAY = 86400;
    bytes32 private constant ZERO_BYTES32 = 0x0000000000000000000000000000000000000000000000000000000000000000;

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

    function setTreasurer(address _treasurer) public onlyOwner {
        require(_treasurer != address(0), "zero address");
        treasurer = _treasurer;
    }

    function addReferral(address addr, uint256 amount, bytes32 referral) external nonReentrant {
        require(referralLink[addr] == ZERO_BYTES32, "already a member");
        require(users[referral].addr == msg.sender || referral == ZERO_BYTES32, "Invalid referrral");

        bytes32 link = keccak256(abi.encode(addr, referral));
        referralLink[addr] = link;

        uint256 requiredAmountInWei = _invest(addr, amount, referral);

        users[link] = User({
            deposited: requiredAmountInWei,
            timestamp: block.timestamp,
            referralReward: 0,
            reward: 0,
            claimed: 0,
            addr: addr,
            link: link,
            referredCount: 0,
            directCount: 0,
            referred: referral
        });

        _distributeBonus(referral, requiredAmountInWei);
    }

    function _distributeBonus(bytes32 link, uint256 amountInWei) internal {
        bytes32 userLink = link;
        uint32 currentTime = uint32(block.timestamp);
        User storage user;
        uint8 bonusPercentage;
        uint bonus;
        for(uint i = 0; i < 40; i++) {
            if (userLink == ZERO_BYTES32) break;
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
            if (((currentTime - directRefrralTime[link])/DAY) <= 30) user.referralReward += bonus;
            userLink = user.referred;
            if (i == user.referredCount) user.referredCount += 1;
        }
    }

    function topup(address addr, uint256 amount) external nonReentrant {
        require(users[referralLink[addr]].addr != address(0), "Invalid address");
        uint256 requiredAmountInWei = _invest(addr, amount, referralLink[addr]);

        User storage user = users[referralLink[addr]];

        user.reward = _totalReward(user.link);

        user.deposited += requiredAmountInWei;
        user.timestamp = block.timestamp;

        // _distributeBonus(referralLink[addr], requiredAmountInWei);
    }

    function _invest(address addr, uint256 amount, bytes32 link) internal returns(uint256) {
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

        if (link != ZERO_BYTES32) {
            directRefrralTime[link] = uint32(block.timestamp);
            users[link].directCount += 1;
        }

        collections[index] += requiredAmountInWei;
        uint256 leftover = newBalance - (previousBalance + requiredAmountInWei);
        if (leftover > 0) token.transfer(msg.sender, leftover);

        emit Invested(addr, block.timestamp);
        return requiredAmountInWei;
    }

    function _totalReward(bytes32 link) internal view returns(uint256) {
        User storage user = users[link];
        uint256 dailyReward = (user.deposited * 5)/1000;
        uint16 time = uint16((block.timestamp - user.timestamp)/DAY);

        return ((dailyReward * time) + user.referralReward + user.reward);
    }

    function myRewards() public view returns(uint256) {
        User memory user = users[referralLink[msg.sender]];
        uint256 reward = _totalReward(user.link);
        return reward - user.claimed;
    }

    function claim() public {
        require(blacklist[msg.sender] == false, "blacklisted");
        User storage user = users[referralLink[msg.sender]];
        require(user.deposited != 0, "No Deposits");
        require(((block.timestamp - user.timestamp)/DAY) > 0, "Too Early");
        
        user.reward = _totalReward(user.link);
        uint256 amountToClaim = user.reward - user.claimed;
        user.claimed += amountToClaim;
    
        token.transfer(msg.sender, amountToClaim);

        emit Reward(user.addr, amountToClaim);
    }

    // NOTICE: Here user can withdraw any sum of amount, not compulsory 
    // to be the multiple of 100
    function withdraw(uint256 amount) public nonReentrant {

        uint256 amountInWei = amount * (10 ** decimal);
        User memory user = users[referralLink[msg.sender]];
        if (msg.sender == treasurer) {
            _withdraw(treasurer, amountInWei);
        } else {
            require(user.deposited >= amount, "Low Balance");

            uint256 adminAmountInWei = ((amountInWei * 10) / 100);
            uint256 userAmountInWei = amountInWei - adminAmountInWei;

            uint256 rewardsAccumulated = _totalReward(user.link);

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
            withdraw(users[referralLink[msg.sender]].deposited);
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
        address addr, 
        bytes32 link,
        uint256 referredCount,
        bytes32 referred
    ) {
        User memory user = users[referralLink[_add]];
        deposited = user.deposited;
        timestamp = user.timestamp;
        referralReward = user.referralReward;
        reward = user.reward;
        claimed = user.claimed;
        addr = user.addr;
        link = user.link;
        referredCount = user.referredCount;
        referred = user.referred;
    }
}