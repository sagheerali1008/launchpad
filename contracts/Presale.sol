//SPDX-License-Identifier: Unlicense
pragma solidity >0.6.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";

import "./interface/IStakePool.sol";
import "./interface/IUniswapV2Router02.sol";

contract Presale is ReentrancyGuard, Ownable, Pausable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    address WBNB = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IUniswapV2Router02 uniswapV2Router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    address public liquidityLocker;
    mapping(address => bool) whiteList;
    
    IStakePool public stakePool;
    IERC20 public wantToken;
    IERC20 public investToken = IERC20(WBNB); // WBNB in default
    uint public startTime;
    uint public endTime;
    uint public immutable hardCap;
    uint public softCap;
    uint public totalSupply;
    uint public price;
    address public immutable keeper;

    uint public decimals = 18;
    uint public investRate = 1;
    uint public txFee;
    uint public presaleFee = 500; // 5%
    uint public constant MAX_FEE = 10000;

    uint public totalInvest;
    mapping(address => uint) invested;
    EnumerableSet.AddressSet investors;
    mapping(address => uint) claimed;

    bool public enabledClaim = false;
    bool public addedLiquidity = false;
    uint public liquidityAlloc;
    uint public liquidityLockDuration;
    address public uniswapV2Pair;

    modifier whenNotStarted {
        require(block.timestamp < startTime, "already started");
        _;
    }

    modifier onProgress {
        require(block.timestamp < endTime && block.timestamp >= startTime, "!progress");
        _;
    }

    modifier whenFinished {
        require(block.timestamp > endTime, "!finished");
        _;
    }

    modifier whenNotFinished {
        require(block.timestamp <= endTime, "!finished");
        _;
    }

    modifier onlyKeeper {
        require(msg.sender == owner() || whiteList[msg.sender] == true || msg.sender == keeper, "!keeper");
        _;
    }

    modifier whiteListed {
        require(whiteList[msg.sender] == true || msg.sender == owner(), "!permission");
        _;
    }

    constructor (
        address _wantToken,
        uint _startTime,
        uint _duration,
        uint _hardCap,
        uint _softCap,
        uint _price,
        uint _liquidityAlloc,
        address _liquidityLocker,
        uint _liquidityLockDuration,
        address _stakePool,
        address _keeper
    ) public {
        stakePool = IStakePool(_stakePool);
        wantToken = IERC20(_wantToken);

        require(_duration > 0, "invalid duration");
        startTime = _startTime;
        endTime = _startTime.add(_duration);

        require(_hardCap > _softCap, "invalid caps");
        hardCap = _hardCap;
        softCap = _softCap;

        price = _price;
        liquidityAlloc = _liquidityAlloc;
        liquidityLocker = _liquidityLocker;
        liquidityLockDuration = _liquidityLockDuration;
        keeper = _keeper;

        whiteList[msg.sender] = true;
    }

    function getInvestorList() external view onlyKeeper returns (address[] memory) {
        address[] memory investorList = new address[](investors.length());
        for (uint i = 0; i < investors.length(); i++) {
            investorList[i] = investors.at(i);
        }

        return investorList;
    }

    function totalInvestable(address _investor) public view returns (uint) {
        uint totalAllocPoint = stakePool.totalAllocPoint();
        uint tierCount = stakePool.tierCount();
        uint totalInvestable = 0;

        for (uint i = 0; i < tierCount; i++) {
            (,uint allocPoint,,uint tierSupply) = stakePool.poolInfo(i);
            uint tierTotalAvailable = stakePool.totalAvailable(i);
            (,uint balance,) = stakePool.balanceOf(i, _investor);
            totalInvestable += hardCap.mul(allocPoint).div(totalAllocPoint).mul(balance).div(tierTotalAvailable);
        }

        return totalInvestable;
    }

    function investable(address _investor) public view returns (uint) {
        uint amount = totalInvestable(_investor);
        if (amount.mul(investRate) <= invested[_investor]) return 0;

        amount = amount.mul(investRate).sub(invested[_investor]);
        if (amount > hardCap.sub(totalInvest)) amount = hardCap.sub(totalInvest);

        return amount;
    }

    function claimable(address _investor) public view returns (uint) {
        if (totalInvest == 0) return 0;

        return totalSupply.mul(invested[_investor]).div(hardCap);
    }

    function investWithToken(uint amount) external onProgress nonReentrant {
        require(address(investToken) != WBNB, "should invest in token");
        require(totalInvest < hardCap, "exceeded hard cap");
        require(amount <= investable(msg.sender), "limited to invest");

        uint before = investToken.balanceOf(address(this));
        investToken.safeTransferFrom(msg.sender, address(this), amount);
        amount = investToken.balanceOf(address(this)).sub(before);

        invested[msg.sender] += amount;
        totalInvest += amount;
    }

    function invest() external payable onProgress nonReentrant {
        require(address(investToken) == WBNB, "should invest in BNB");
        require(totalInvest < hardCap, "exceeded hard cap");
        require(msg.value <= investable(msg.sender), "limited to invest");

        invested[msg.sender] += msg.value;
        totalInvest += msg.value;
    }

    function claim() external whenFinished nonReentrant {
        require(enabledClaim == true, "still not enabled to claim");
        require(claimed[msg.sender] == 0, "already claimed");

        uint amount = claimable(msg.sender);
        require(amount >= wantToken.balanceOf(address(this)), "exceeded amount to claim");

        wantToken.safeTransfer(msg.sender, amount);
        claimed[msg.sender] = block.timestamp;
    }

    function deposit(uint amount) external onlyKeeper whenNotStarted {
        require(amount > 0, "!amount");

        uint before = wantToken.balanceOf(address(this));
        wantToken.safeTransferFrom(msg.sender, address(this), amount);

        // if (txFee > 0) amount = amount.mul(MAX_FEE-txFee).div(MAX_FEE);
        totalSupply += wantToken.balanceOf(address(this)).sub(before);
    }

    function withdrawWantToken() external onlyKeeper whenFinished {
        uint investorOwned = totalSupply.mul(totalInvest).div(hardCap);
        wantToken.safeTransfer(msg.sender, totalSupply.sub(investorOwned));
    }

    function withdrawInvestToken() external onlyKeeper whenFinished {
        require(addedLiquidity == true, "!withdrawable");
        uint liquidated = totalInvest.mul(liquidityAlloc).div(MAX_FEE);
        uint withdrawable = totalInvest.sub(liquidated).sub(totalInvest.mul(presaleFee).div(MAX_FEE));
        if (address(investToken) == WBNB) {
            msg.sender.transfer(withdrawable);
        } else {
            investToken.safeTransfer(msg.sender, withdrawable);
        }
    }

    function withdrawPresaleFee() external whiteListed {
        require(addedLiquidity == true, "!withdrawable");
        if (address(investToken) == WBNB) {
            msg.sender.transfer(totalInvest.mul(presaleFee).div(MAX_FEE));
        } else {
            investToken.safeTransfer(msg.sender, totalInvest.mul(presaleFee).div(MAX_FEE));
        }
    }

    function addLiquidity() external whiteListed whenFinished {
        if (IUniswapV2Factory(uniswapV2Router.factory()).getPair(address(wantToken), uniswapV2Router.WETH()) == address(0)) {
            uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory())
                .createPair(address(wantToken), uniswapV2Router.WETH());
        }

        uint liquidityForInvest = totalInvest.mul(liquidityAlloc).div(MAX_FEE);
        uint decimalsDiff = 18-ERC20(address(wantToken)).decimals();
        uint liquidityForWant = liquidityForInvest.div(price).div(10**decimalsDiff);

        if (address(investToken) == WBNB) {
            _addLiquidity(liquidityForWant, liquidityForInvest);
        } else {
            _swapAndLiquidate(liquidityForWant, liquidityForInvest);
        }

        uint lpBalance = IERC20(uniswapV2Pair).balanceOf(address(this));
        IERC20(uniswapV2Pair).safeApprove(liquidityLocker, lpBalance);
        // liquidityLocker.lock(uniswapV2Pair, lpBalance, keeper, liquidityLockDuration);

        addedLiquidity = true;
    }

    function _swapAndLiquidate(uint wantTokens, uint investTokens) internal {
        address[] memory path = new address[](2);
        path[0] = address(wantToken);
        path[1] = uniswapV2Router.WETH();
        uint beforeBalance = address(this).balance;

        investToken.safeApprove(address(uniswapV2Router), investTokens);

        // make the swap
        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            investTokens,
            0, // accept any amount of ETH
            path,
            address(this), // The contract
            block.timestamp
        );

        _addLiquidity(wantTokens, address(this).balance.sub(beforeBalance));
    }

    function _addLiquidity(uint tokenAmount, uint bnbAmount) internal {
        // approve token transfer to cover all possible scenarios
        wantToken.safeApprove(address(uniswapV2Router), tokenAmount);

        // add the liquidity
        uniswapV2Router.addLiquidityETH{value: bnbAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            address(this),
            block.timestamp
        );
    }

    function _bulkTransferClaimed() internal {
        for (uint i = 0; i < investors.length(); i++) {
            address investor = investors.at(i);
            if (claimed[investor] > 0) continue; // already claimed

            uint amount = claimable(investor);
            require(amount >= wantToken.balanceOf(address(this)), "exceeded amount to claim");

            wantToken.safeTransfer(investor, amount);
            claimed[investor] = block.timestamp;
        }
    }

    function setEnableClaim(bool _flag, bool _isBulk) external whiteListed {
        enabledClaim = _flag;

        if (_flag == true && _isBulk == true) {
            _bulkTransferClaimed();
        }
    }

    function setSoftCap(uint _cap) external whiteListed {
        require(_cap < hardCap, "invalid soft cap");
        softCap = _cap;
    }

    function setInvestToken(address _token) external whiteListed whenNotStarted {
        investToken = IERC20(_token);
    }

    function setDecimals(uint _decimals) external whiteListed whenNotStarted {
        require(_decimals >=3 && _decimals <= 18, "!decimals");
        decimals = _decimals;
    }

    function setTxFee(uint256 _fee) external whiteListed whenNotStarted {
        require(_fee < MAX_FEE, "invalid fee");
        txFee = _fee;
    }

    function setInvestRate(uint _rate) external whiteListed {
        require(_rate > 0, "!rate");
        investRate = _rate;
    }

    function setPrice(uint _price) external whiteListed {
        require(_price > 0, "!price");
        price = _price;
    }

    function setPresaleFee(uint _fee) external whiteListed {
        require(_fee < MAX_FEE, "!fee");
        presaleFee = _fee;
    }

    function setLiquidityAlloc(uint _allocation) external whiteListed {
        require(_allocation < MAX_FEE, "!allocation");
        liquidityAlloc = _allocation;
    }

    function setUniswapRouter(address _router) external whiteListed {
        uniswapV2Router = IUniswapV2Router02(_router);
    }

    function setLquidityLocker(address _locker) external whiteListed {
        liquidityLocker = _locker;
    }

    function setLiquidityLockDuration(uint _duration) external whiteListed {
        liquidityLockDuration = _duration;
    }

    function setWhiteList(address _user, bool _flag) external onlyOwner {
        whiteList[_user] = _flag;
    }
}