// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
pragma abicoder v2;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./Pool.sol";


contract PoolFactory is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address[] public pools;

    mapping(address => bool) public isExisting;
    mapping(address => address[]) public contributions;

    uint256[2] public fees;
    uint256 public createFee;

    address payable public feeWallet;
    IMoonLock lock;


    constructor(
        uint256 fee1,
        uint256 fee2,
        address _feeWallet,
        address _lockContract
    ) {
        fees[0] = fee1;
        fees[1] = fee2;
        createFee = 3 * 10**17;
        feeWallet = payable(_feeWallet);
        lock = IMoonLock(_lockContract);
    }

    function getPools() public view returns (address[] memory a) {
        return pools;
    }

    function getContributions(address account) public view returns (address[] memory a) {
        return contributions[account];
    }

    function getFees() public view returns (uint256[2] memory a) {
        return fees;
    }

    function setValues(
        uint256 _newfee1,
        uint256 _newfee2,
        uint256 _createFee,
        address payable _newFeeWallet
    ) external onlyOwner {
        fees[0] = _newfee1;
        fees[1] = _newfee2;
        createFee = _createFee;
        feeWallet = _newFeeWallet;
    }

    function removePoolForToken(address token) external {
        isExisting[token] = false;
    }

    function recordContribution(address user, address pool) external {
        contributions[user].push(pool);
    }

   function estimateTokenAmount(
        uint256[2] memory _rateSettings,
        uint256[2] memory _capSettings,
        uint256 _liquidityPercent,
        uint256 _teamtoken
    ) public view returns (uint256) {
        uint256 tokenamount = _rateSettings[0]
            .mul(_capSettings[1])
            .mul(100)
            .div(100 - fees[0])
            .div(1e18);

        uint256 liquidityBnb = _capSettings[1]
            .mul(_liquidityPercent)
            .div(100)
            .mul(_rateSettings[1]);
        uint256 liquidityToken = liquidityBnb.div(1e18).mul(100).div(
            100 - fees[1]
        );

        uint256 totaltoken = tokenamount + liquidityToken + _teamtoken;

        return totaltoken;
    }

    function createPool(
        address[4] memory _addrs, // [0] = owner, [1] = token, [2] = router, [3] = governance
        uint256[2] memory _rateSettings, // [0] = rate, [1] = uniswap rate
        uint256[2] memory _contributionSettings, // [0] = min, [1] = max
        uint256[2] memory _capSettings, // [0] = soft cap, [1] = hard cap
        uint256[3] memory _timeSettings, // [0] = start, [1] = end, [2] = unlock seconds
        uint256[3] memory _vestings,
        bool _isWhitelist,
        uint256[5] memory _teamVestings, //[0] = total team token, [1] = first release minute, [2] = first release percent, [3] = period minutes, [4] = each cycle percent
        uint256 _liquidityPercent,
        uint256 _refundType,
        string memory _poolDetails
    ) external payable {
        uint256 totaltoken = estimateTokenAmount(
            _rateSettings,
            _capSettings,
            _liquidityPercent,
            _teamVestings[0]
        );

        if (isExisting[_addrs[1]] == false) {
            require(msg.value >= createFee, "Fee must pay");
            Pool pool = new Pool();
            pools.push(address(pool));
            for (uint256 i = pools.length - 1; i > 0; i--)
                pools[i] = pools[i - 1];
            pools[0] = address(pool);
            isExisting[_addrs[1]] = true;

            IERC20(_addrs[1]).approve(address(pool), totaltoken);

            IERC20(_addrs[1]).transferFrom(
                msg.sender,
                address(pool),
                totaltoken
            );
            _addrs[3] = feeWallet;
            pool.initialize(
                _addrs,
                _rateSettings,
                _contributionSettings,
                _capSettings,
                _timeSettings,
                fees,
                _vestings,
                _isWhitelist,
                _liquidityPercent,
                _refundType,
                _poolDetails,
                lock
            );

            if(_teamVestings[0] > 0)
            {
                pool.initializeVesting(_teamVestings);
            }    
         }
     }

    receive() external payable {}
}
