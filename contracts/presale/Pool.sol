// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "../interfaces/IUniswapV2Router02.sol";
import "../interfaces/IUniswapV2Factory.sol";
import "../interfaces/IMoonLock.sol";

interface IPoolFactory {
  function removePoolForToken(address token) external;
  function recordContribution(address user, address pool) external;
}

library PoolLibrary {
  using SafeMathUpgradeable for uint256;


  function getContributionAmount(
    uint256 contributed,
    uint256 minContribution,
    uint256 maxContribution,
    uint256 availableToBuy
  ) internal pure returns (uint256, uint256) {
        // Bought all their allocation
        if (contributed >= maxContribution) {
            return (0, 0);
        }
        uint256 remainingAllocation = maxContribution.sub(contributed);

        // How much bnb is one token
        if (availableToBuy > remainingAllocation) {
            if (contributed > 0) {
                return (0, remainingAllocation);
            } else {
                return (minContribution, remainingAllocation);
            }
        } else {
             if (contributed > 0) {
                return (0, availableToBuy);
            } else {
                if (availableToBuy < minContribution) {
                    return (0, availableToBuy);
                } else {
                    return (minContribution, availableToBuy);
                }
            }
        }
  }

  function convertCurrencyToToken(
    uint256 amount, 
    uint256 rate
  ) internal pure returns (uint256) {
    return amount.mul(rate).div(1e18);
  }

  function addLiquidity(
    address router,
    address token,
    uint256 liquidityBnb,
    uint256 liquidityToken,
    address pool
  ) internal returns (uint256 liquidity) {
    IERC20Upgradeable(token).approve(router, liquidityToken);
    (,, liquidity) = IUniswapV2Router02(router).addLiquidityETH{value: liquidityBnb}(
        token,
        liquidityToken,
        liquidityToken,
        liquidityBnb,
        pool,
        block.timestamp
    );
  }

  function calculateFeeAndLiquidity(
    uint256 totalRaised,
    uint256 ethFeePercent,
    uint256 tokenFeePercent,
    uint256 totalVolumePurchased,
    uint256 liquidityPercent,
    uint256 liquidityListingRate
  ) internal pure returns (uint256 bnbFee, uint256 tokenFee, uint256 liquidityBnb, uint256 liquidityToken) {
    bnbFee = totalRaised.mul(ethFeePercent).div(100);
    tokenFee = totalVolumePurchased.mul(tokenFeePercent).div(100);
    liquidityBnb = totalRaised.sub(bnbFee).mul(liquidityPercent).div(100);
    liquidityToken = liquidityBnb.mul(liquidityListingRate).div(1e18);
  }
}

contract Pool is OwnableUpgradeable {
    using SafeMathUpgradeable for uint256;
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using AddressUpgradeable for address payable;

    uint constant MINIMUM_LOCK_DAYS = 5 minutes;

    enum PoolState {
        inUse,
        completed,
        cancelled
    }

    address public factory;
    address public router;
    address public governance;

    address public token;
    uint256 public rate;
    uint256 public minContribution;
    uint256 public maxContribution;
    uint256 public softCap;
    uint256 public hardCap;

    uint256 public startTime;
    uint256 public endTime;

    uint256 private tokenFeePercent;
    uint256 private ethFeePercent;

    uint256 public liquidityListingRate;
    uint256 public liquidityUnlockTime;
    uint256 public liquidityLockDays;
    uint256 public liquidityPercent;
    uint256 public refundType;

    string public poolDetails;

    PoolState public poolState;

    address pair;

    uint256 public totalRaised;
    uint256 public totalVolumePurchased;
    uint256 public totalClaimed;
    uint256 public totalRefunded;

    bool public completedKyc;

    mapping(address => uint256) public contributionOf;
    mapping(address => uint256) public purchasedOf;
    mapping(address => uint256) public claimedOf;
    mapping(address => uint256) public refundedOf;

    uint256 public teamVestingLockId;
    uint256 public liquidityLockId;

    bool public useWhitelisting;
    uint256 public publicStartTime;
    mapping(address => bool) public whitelistedUsers;
    address[] public whitelisted;
    uint256 public whitelistedNum;
    uint256[3] public vestings;
    uint256[5] public teamVestings;

    IMoonLock public lock;


    event Contributed(
        address indexed user,
        uint256 amount,
        uint256 volume,
        uint256 total,
        uint256 timestamp
    );

    event WithdrawnContribution(address indexed user, uint256 amount);

    event Claimed(address indexed user, uint256 volume, uint256 total);

    event Finalized(uint256 liquidity, uint256 timestamp);

    event Cancelled(uint256 timestamp);

    event PoolUpdated(uint256 timestamp);

    event KycUpdated(bool completed, uint256 timestamp);

    event LiquidityWithdrawn(uint256 amount, uint256 timestamp);

    event VestingTokenWithdrawn(uint256 amount, uint256 timestamp);


    modifier inProgress() {
        require(poolState == PoolState.inUse, "Pool is either completed or cancelled");
        require(block.timestamp < endTime, "Pool ended");
        require(block.timestamp > startTime, "Pool didnt start");
        require(totalRaised < hardCap, "Hardcap reached");
        _;
    }

    modifier onlyOperator() {
        require(msg.sender == owner() || msg.sender == governance, "Only operator");
        _;
    }

    modifier onlyGovernance() {
        require(msg.sender == governance, "Only governance");
        _;
    }

    receive() external payable {
        if (msg.value > 0) contribute();
    }


    function initialize(
        address[4] memory _addrs, // [0] = owner, [1] = token, [2] = router, [3] = governance
        uint256[2] memory _rateSettings, // [0] = rate, [1] = uniswap rate
        uint256[2] memory _contributionSettings, // [0] = min, [1] = max
        uint256[2] memory _capSettings, // [0] = soft cap, [1] = hard cap
        uint256[3] memory _timeSettings, // [0] = start, [1] = end, [2] = unlock seconds
        uint256[2] memory _feeSettings, // [0] = token fee percent, [1] = eth fee percent
        uint256[3] memory _vestings, //[0] = first release percent, [1] = period minutes, [2] = each cycle percent
        bool _useWhitelisting,
        uint256 _liquidityPercent,
        uint256 _refundType,
        string memory _poolDetails,
        IMoonLock _lock
    ) external initializer {
        require(factory == address(0), "Pool: Forbidden");
        require(_addrs[0] != address(0), "Invalid owner address");
        require(_contributionSettings[0] <= _contributionSettings[1], "Min contribution amount must be less than or equal to max");
        require(_capSettings[0].mul(2) >= _capSettings[1] && _capSettings[0] <= _capSettings[1], "Softcap must be >= 50% of hardcap");
        require(_timeSettings[0] > block.timestamp, "Start time should be in the future");
        require(_timeSettings[0] < _timeSettings[1], "End time must be after start time");
        require(_timeSettings[2] >= MINIMUM_LOCK_DAYS, "Liquidity unlock time must be at least 30 days after pool is finalized");
        require(
            _feeSettings[0] >= 0 &&
            _feeSettings[0] <= 100 &&
            _feeSettings[1] >= 0 &&
            _feeSettings[1] <= 100,
            "Invalid fee settings. Must be percentage (0 -> 100)"
        );
        require (_rateSettings[0] >= _rateSettings[1], "Liquidity listing rate must be less than or equal to pool listing rate");
        require(_liquidityPercent >= 51 && _liquidityPercent <= 100, "Invalid liquidity percentage");
        require(_refundType == 0 || _refundType == 1, "Refund type must be 0 (refund) or 1 (burn)");
        
        __Ownable_init();
        transferOwnership(_addrs[0]);
        factory = msg.sender;
        token = _addrs[1];
        router = _addrs[2];
        governance = _addrs[3];
        rate = _rateSettings[0];
        liquidityListingRate = _rateSettings[1];
        minContribution = _contributionSettings[0];
        maxContribution = _contributionSettings[1];
        softCap = _capSettings[0];
        hardCap = _capSettings[1];
        startTime = _timeSettings[0];
        endTime = _timeSettings[1];
        liquidityLockDays = _timeSettings[2];
        tokenFeePercent = _feeSettings[0];
        ethFeePercent = _feeSettings[1];
        liquidityPercent = _liquidityPercent;
        refundType = _refundType;
        poolDetails = _poolDetails;
        poolState = PoolState.inUse;
        vestings = _vestings;
        lock = _lock;

        if(_useWhitelisting)
        {
            publicStartTime = _timeSettings[1];
        }
        else{
            publicStartTime = 0;
        }

    }

    function initializeVesting(
        uint256[5] memory _teamVestings //[0] = total team token, [1] = first release minute, [2] = first release percent, [3] = period minutes, [4] = each cycle percent
    ) external {
        require(factory == msg.sender, "Only Pool Factory");
        require(teamVestingLockId == 0, "Already initialized");

        teamVestings = _teamVestings;

        IERC20Upgradeable(token).approve(address(lock),_teamVestings[0]);
        teamVestingLockId = lock.vestingLock(address(this), token, false, _teamVestings[0], _teamVestings[1],  _teamVestings[2],  _teamVestings[3],  _teamVestings[4], "Team Lock");
    }

    function contribute() public payable inProgress {
        require(msg.value > 0, "Cant contribute 0");
        
        if (publicStartTime > block.timestamp) {
            require(whitelistedUsers[msg.sender], "sender is not in whitelist");
        }
        uint256 userTotalContribution = contributionOf[msg.sender].add(msg.value);
        // Allow to contribute with an amount less than min contribution
        // if the remaining contribution amount is less than min
        if (hardCap.sub(totalRaised) >= minContribution) {
            require(userTotalContribution >= minContribution, "Min contribution not reached");
        }
        require(userTotalContribution <= maxContribution, "Contribute more than allowed");
        require(totalRaised.add(msg.value) <= hardCap, "Buying amount exceeds hard cap");
        
        if (contributionOf[msg.sender] == 0) {
            IPoolFactory(factory).recordContribution(msg.sender, address(this));
        }
        contributionOf[msg.sender] = userTotalContribution;
        totalRaised = totalRaised.add(msg.value);
        
        uint256 volume = msg.value.mul(rate).div(1e18);
        require(volume > 0, "too small Contribution");

        purchasedOf[msg.sender] = purchasedOf[msg.sender].add(volume);
        totalVolumePurchased = totalVolumePurchased.add(volume);

        emit Contributed(msg.sender, msg.value, volume, totalVolumePurchased, block.timestamp);
    }

    function claim() public {
        require(poolState == PoolState.completed, "Owner has not closed the pool yet");
        require(claimedOf[msg.sender] < purchasedOf[msg.sender], "Already claimed");

        uint256 amount = 0;
        if(vestings[0] > 0 && vestings[1] > 0 && vestings[2] > 0)
        {
                amount = purchasedOf[msg.sender].mul(vestings[0]).div(100);
                amount = amount.add(
                    purchasedOf[msg.sender].mul(
                                (block.timestamp.sub(endTime))
                                    .div(vestings[1])
                        ).mul(vestings[2]).div(100)
                );

        }
        else{
            amount = purchasedOf[msg.sender];
        }
       
        if (amount > purchasedOf[msg.sender]) amount = purchasedOf[msg.sender];
        amount = amount.sub(claimedOf[msg.sender]);
        require(amount > 0, "There is no claimed amount");


        claimedOf[msg.sender] = claimedOf[msg.sender].add(amount);
        totalClaimed = totalClaimed.add(amount);
        
        IERC20Upgradeable(token).safeTransfer(msg.sender, amount);

        emit Claimed(msg.sender, amount, totalClaimed);
    }

    function withdrawContribution() external {
        if (poolState == PoolState.inUse) {
            require(block.timestamp >= endTime, "Pool is still in progress");
            require(totalRaised < softCap, "Soft cap reached");
        } else {
            require(poolState == PoolState.cancelled, "Cannot withdraw contribution because pool is completed");
        }
        require(refundedOf[msg.sender] == 0, "Already withdrawn contribution");

        uint256 refundAmount = contributionOf[msg.sender];
        refundedOf[msg.sender] = refundAmount;
        totalRefunded = totalRefunded.add(refundAmount);
        contributionOf[msg.sender] = 0;

        payable(msg.sender).sendValue(refundAmount);
        emit WithdrawnContribution(msg.sender, refundAmount);
    }

    function finalize() external onlyOperator {
        require(poolState == PoolState.inUse, "Pool was finialized or cancelled");
        require(
            totalRaised == hardCap || hardCap.sub(totalRaised) < minContribution ||
                (totalRaised >= softCap && block.timestamp >= endTime),
            "It is not time to finish"
        );

        poolState = PoolState.completed;

        liquidityUnlockTime = block.timestamp + liquidityLockDays;
        (
            uint256 bnbFee,
            uint256 tokenFee,
            uint256 liquidityBnb,
            uint256 liquidityToken
        ) = PoolLibrary.calculateFeeAndLiquidity(
            totalRaised, 
            ethFeePercent, 
            tokenFeePercent, 
            totalVolumePurchased, 
            liquidityPercent, 
            liquidityListingRate
        );
       
        uint256 remainingBnb = address(this).balance.sub(liquidityBnb).sub(bnbFee);
        uint256 remainingToken = 0;

        uint256 totalTokenSpent = liquidityToken.add(tokenFee).add(totalVolumePurchased);
        uint256 balance = IERC20Upgradeable(token).balanceOf(address(this));
        if (balance > totalTokenSpent) {
            remainingToken = balance.sub(totalTokenSpent);
        }

        // Pay platform fees
        if (bnbFee > 0) {
             payable(governance).sendValue(bnbFee);
        }
        if (tokenFee > 0) {
             IERC20Upgradeable(token).safeTransfer(governance, tokenFee);
        }
       

        // Refund remaining
        if (remainingBnb > 0) {
            payable(owner()).sendValue(remainingBnb);
        }
       
       if (remainingToken > 0) {
            // 0: refund, 1: burn
            if (refundType == 0) {
                IERC20Upgradeable(token).safeTransfer(owner(), remainingToken);
            } else {
                IERC20Upgradeable(token).safeTransfer(address(0xdead), remainingToken);
            }
       }

        uint256 liquidity = PoolLibrary.addLiquidity(
            router,
            token,
            liquidityBnb,
            liquidityToken,
            address(this)
        );

        address swapFactory = IUniswapV2Router02(router).factory();
        pair = IUniswapV2Factory(swapFactory).getPair(
            IUniswapV2Router02(router).WETH(),
            token
        );
        uint256 pairamount = IERC20Upgradeable(pair).balanceOf(address(this));
        IERC20Upgradeable(pair).approve(address(lock), pairamount);
        liquidityLockId = lock.lock(address(this), pair, true, pairamount, liquidityUnlockTime, "liquidity lock");

        IERC20Upgradeable(token).approve(address(lock), totalVolumePurchased);

        endTime = block.timestamp;
        

        emit Finalized(liquidity, block.timestamp);
    }

    function cancel() external onlyOperator {
        require (poolState == PoolState.inUse, "Pool was either finished or cancelled");
        poolState = PoolState.cancelled;
        IPoolFactory(factory).removePoolForToken(token);
        IERC20Upgradeable(token).safeTransfer(owner(), IERC20Upgradeable(token).balanceOf(address(this)));
        emit Cancelled(block.timestamp);
    }

    function withdrawLeftovers() external onlyOperator {
        require(block.timestamp >= endTime, "It is not time to withdraw leftovers");
        require(totalRaised < softCap, "Soft cap reached, call finalize() instead");
        IERC20Upgradeable(token).safeTransfer(owner(), IERC20Upgradeable(token).balanceOf(address(this)));
    }

    function withdrawLiquidity() external onlyOperator {
        require(poolState == PoolState.completed, "Pool has not been finalized");
        require(liquidityLockId != 0, "No Lock yet");

        lock.unlock(liquidityLockId);

        uint256 pairamount = IERC20Upgradeable(pair).balanceOf(address(this));

        IERC20Upgradeable(pair).transfer(owner(), pairamount);
    }

    function emergencyWithdraw(address token_, address to_, uint256 amount_) external onlyGovernance {
        require(token_ != pair, "Cannot withdraw liquidity. Use withdrawLiquidity() instead");
        IERC20Upgradeable(token_).safeTransfer(to_, amount_);
    }

    function emergencyWithdraw(address payable to_, uint256 amount_) external onlyGovernance {
        to_.sendValue(amount_);
    }

    function updatePoolDetails(string memory details_) external onlyOperator {
        poolDetails = details_;
        emit PoolUpdated(block.timestamp);
    }

    function updateCompletedKyc(bool completed_) external onlyGovernance {
        completedKyc = completed_;
        emit KycUpdated(completed_, block.timestamp);
    }

    function setGovernance(address governance_) external onlyGovernance {
        governance = governance_;
    }

    function setWhitelistedUsers(address[] calldata users,bool add)
        external
        onlyOwner
    {
        if(add)
        {
            for (uint8 i = 0; i < users.length; i++) {
                        if (!whitelistedUsers[users[i]]) {
                            whitelistedUsers[users[i]] = true;
                            whitelisted.push(users[i]);
                            whitelistedNum++;
                        }
                    }
        }
        else{
                for (uint8 i = 0; i < users.length; i++) {
                            if (whitelistedUsers[users[i]]) {
                                whitelistedUsers[users[i]] = false;
                                for (uint8 j = 0; j < whitelistedNum; j++) {
                                    if (whitelisted[j] == users[i]) {
                                        whitelisted[j] = whitelisted[whitelistedNum - 1];
                                        whitelisted.pop();
                                        whitelistedNum--;
                                        break;
                                    }
                                }
                            }
                        }
        }
        
    }

    function setPublicSaleStartTime (uint256 _publicStartTime) external onlyOwner {
        publicStartTime = _publicStartTime;
    }


    function getWhiteLists() public view returns (address[] memory) {
        return whitelisted;
    }

    function getContributionAmount(address user_) public view returns (uint256, uint256) {
        uint256 contributed = contributionOf[user_];
        uint256 availableToBuy = remainingContribution();
        return PoolLibrary.getContributionAmount(
            contributed, 
            minContribution, 
            maxContribution, 
            availableToBuy
        );
    }

    function liquidityBalance() public view returns (uint256) {
        if (pair == address(0)) return 0;
        return IERC20Upgradeable(pair).balanceOf(address(this));
    }

    function remainingContribution() public view returns (uint256) {
        return hardCap.sub(totalRaised);
    }

    function convert(uint256 amountInWei) public view returns (uint256) {
        return PoolLibrary.convertCurrencyToToken(amountInWei, rate);
    }

    function getUpdatedState() public view returns (uint256, uint8, bool, uint256, string memory) {
        return (totalRaised, uint8(poolState), completedKyc, liquidityUnlockTime, poolDetails);
    }

    function withdrawVestingToken() external onlyOwner {
        require(teamVestingLockId != 0, "No Lock yet");

        uint256 withdrawable = lock.withdrawableTokens(teamVestingLockId);
        lock.unlock(teamVestingLockId);
        IERC20Upgradeable(token).safeTransfer(owner(), withdrawable);
    }

    function getPoolData()
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            string memory a,
            PoolState,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        return (
            startTime,
            endTime,
            rate,
            softCap,
            hardCap,
            liquidityPercent,
            liquidityLockDays,
            totalRaised,
            poolDetails,
            poolState,
            liquidityListingRate,
            refundType,
            minContribution,
            maxContribution
        );
    }

    function getUserPool(address account)
            external
            view
            returns (
                uint256,
                bool
            )
        {
            return (
                contributionOf[account],
                whitelistedUsers[account]
            );
        }
}