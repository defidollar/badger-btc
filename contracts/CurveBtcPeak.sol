pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20, SafeMath} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";

import {ISwap} from "./interfaces/ISwap.sol";
import {ICore} from "./interfaces/ICore.sol";
import {ISett} from "./interfaces/ISett.sol";
import {IPeak} from "./interfaces/IPeak.sol";

import {Initializable} from "./common/proxy/Initializable.sol";
import {GovernableProxy} from "./common/proxy/GovernableProxy.sol";

import "hardhat/console.sol"; // @todo remove

contract CurveBtcPeak is GovernableProxy, Initializable, IPeak {
    using SafeERC20 for IERC20;
    using SafeERC20 for ISett;
    using SafeMath for uint;
    using Math for uint;

    uint constant PRECISION = 1e4;

    ICore public immutable core;
    IERC20 public immutable bBtc;

    struct CurvePool {
        IERC20 lpToken;
        ISwap swap;
        ISett sett;
    }
    mapping(uint => CurvePool) public pools;

    uint public min;
    uint public redeemFeeFactor;
    uint public mintFeeFactor;
    uint public numPools;
    address public feeSink;

    // END OF STORAGE VARIABLES

    event Mint(address account, uint amount);
    event Redeem(address account, uint amount);
    event FeeCollected(uint amount);

    /**
    * @param _core Address of the the Core contract
    * @param _bBtc Address of the the bBTC token contract
    */
    constructor(address _core, address _bBtc) public {
        core = ICore(_core);
        bBtc = IERC20(_bBtc);
    }

    /**
    * @notice Mint bBTC with curve pool LP token
    * @param poolId System internal ID of the whitelisted curve pool
    * @param inAmount Amount of LP token to mint bBTC with
    * @return outAmount Amount of bBTC minted to user's account
    */
    function mintWithCurveLP(uint poolId, uint inAmount)
        external
        returns(uint outAmount)
    {
        CurvePool memory pool = pools[poolId];
        // will revert if user passed an unsupported poolId
        // not dividing by 1e18 allows us a gas optimization in core.mint
        outAmount = _mint(inAmount.mul(pool.swap.get_virtual_price()));
        pool.lpToken.safeTransferFrom(msg.sender, address(this), inAmount);
        _balanceFunds(pool);
    }

    /**
    * @notice Mint bBTC with Sett LP token
    * @param poolId System internal ID of the whitelisted curve pool
    * @param inAmount Amount of Sett LP token to mint bBTC with
    * @return outAmount Amount of bBTC minted to user's account
    */
    function mintWithSettLP(uint poolId, uint inAmount)
        external
        returns(uint outAmount)
    {
        CurvePool memory pool = pools[poolId];
        // not dividing by 1e18 allows us a gas optimization in core.mint
        outAmount = _mint(inAmount.mul(settToBtc(pool.swap, pool.sett)));
        // will revert if user passed an unsupported poolId
        pool.sett.safeTransferFrom(msg.sender, address(this), inAmount);
    }

    /**
    * @dev Mints bBTC to the user's account after charging mint fee
    * @param btc BTC supplied, scaled by 1e18
    * @return outAmount Amount of bBTC minted to user's account
    */
    function _mint(uint btc)
        internal
        returns(uint outAmount)
    {
        outAmount = core.mint(btc).mul(mintFeeFactor).div(PRECISION);
        bBtc.safeTransfer(msg.sender, outAmount);
        emit Mint(msg.sender, outAmount);
    }

    /**
    * @notice Redeem bBTC in curve pool LP token
    * @dev Might require a partial/full Sett withdrawal, and hence sett withdrawal fee might be charged on that amount
    * @param poolId System internal ID of the whitelisted curve pool
    * @param inAmount Amount of bBTC to redeem
    * @return outAmount Amount of curve pool LP token
    */
    function redeemInCurveLP(uint poolId, uint inAmount)
        external
        returns (uint outAmount)
    {
        bBtc.safeTransferFrom(msg.sender, address(this), inAmount);
        CurvePool memory pool = pools[poolId];
        outAmount = core.redeem(inAmount.mul(redeemFeeFactor).div(PRECISION))
            .div(crvLPToBtc(pool.swap));
        uint here = pool.lpToken.balanceOf(address(this));
        if (here < outAmount) {
            // withdraw only as much as needed from the vault
            uint withdraw = outAmount.sub(here)
                .mul(1e18)
                .div(pool.sett.getPricePerFullShare())
                .min(pool.sett.balanceOf(address(this))); // can't withdraw more than we have
            pool.sett.withdraw(withdraw);
            // since a withdrawal fee was charged, this is the most decent way to determine the outAmount
            outAmount = pool.lpToken.balanceOf(address(this));
        }
        pool.lpToken.safeTransfer(msg.sender, outAmount);
        emit Redeem(msg.sender, inAmount);
    }

    /**
    * @notice Redeem bBTC in Sett LP tokens
    * @dev There might not be enough Sett LP to fulfill the request, in which case the transaction will revert
    * @param poolId System internal ID of the whitelisted curve pool
    * @param inAmount Amount of bBTC to redeem
    * @return outAmount Amount of Sett LP token
    */
    function redeemInSettLP(uint poolId, uint inAmount)
        external
        returns (uint outAmount)
    {
        bBtc.safeTransferFrom(msg.sender, address(this), inAmount);
        uint btc = core.redeem(inAmount.mul(redeemFeeFactor).div(PRECISION));
        CurvePool memory pool = pools[poolId];
        outAmount = btc.div(settToBtc(pool.swap, pool.sett));
        // will revert if the contract has insufficient funds.
        // This opens up a couple front-running vectors. @todo Discuss with Badger team about possibilities.
        pool.sett.safeTransfer(msg.sender, outAmount);
        emit Redeem(msg.sender, inAmount);
    }

    /**
    * @notice Collect all the accumulated fee (denominated in bBTC)
    */
    function collectAdminFee() external {
        uint amount = bBtc.balanceOf(address(this));
        if (amount > 0) {
            bBtc.safeTransfer(feeSink, amount);
            emit FeeCollected(amount);
        }
    }

    /* ##### View ##### */

    // Sets minimum required on-hand to keep small withdrawals cheap
    function _balanceFunds(CurvePool memory pool) internal {
        uint here = pool.lpToken.balanceOf(address(this));
        uint total = pool.sett.balanceOf(address(this))
            .mul(pool.sett.getPricePerFullShare())
            .div(1e18)
            .add(here);
        uint shouldBeHere = total.mul(min).div(PRECISION);
        if (here <= shouldBeHere) {
            return;
        }
        // best effort at keeping min.div(PRECISION) funds here
        uint farm = here.sub(shouldBeHere);
        pool.lpToken.safeApprove(address(pool.sett), farm);
        pool.sett.deposit(farm);
    }

    function crvLPToBtc(ISwap swap) public view returns (uint) {
        return swap.get_virtual_price();
    }

    function settToBtc(ISwap swap, ISett sett) public view returns (uint) {
        return sett.getPricePerFullShare().mul(crvLPToBtc(swap)).div(1e18);
    }

    function portfolioValue() override external view returns (uint) {
        CurvePool memory pool;
        uint assets;
        // We do not expect to have more than 3-4 pools, so this loop should be fine
        for (uint i = 0; i < numPools; i++) {
            pool = pools[i];
            assets = pool.sett.balanceOf(address(this))
                .mul(pool.sett.getPricePerFullShare())
                .div(1e18)
                .add(pool.lpToken.balanceOf(address(this)))
                .mul(crvLPToBtc(pool.swap))
                .div(1e18)
                .add(assets);
        }
        return assets;
    }

    /* ##### Admin ##### */

    function modifyWhitelistedCurvePools(
        CurvePool[] calldata _pools
    )
        external
        onlyOwner
    {
        numPools = _pools.length;
        CurvePool memory pool;
        for (uint i = 0; i < numPools; i++) {
            pool = _pools[i];
            require(
                address(pool.lpToken) != address(0)
                && address(pool.swap) != address(0)
                && address(pool.sett) != address(0),
                "NULL_ADDRESS"
            );
            pools[i] = CurvePool(pool.lpToken, pool.swap, pool.sett);
        }
    }

    /**
    * @notice Set config
    * @param _min Keeps (_min / 1e14) of funds in vanilla Curve pool LP token and deposits the rest in corresponding Sett vault
    * @param _mintFeeFactor _mintFeeFactor = 9990 would mean a redeem fee of 0.1% (9990 / 1e4)
    * @param _redeemFeeFactor _redeemFeeFactor = 9990 would mean a redeem fee of 0.1% (9990 / 1e4)
    * @param _feeSink Address of the EOA/contract where accumulated fee will be transferred
    */
    function modifyConfig(
        uint _min,
        uint _mintFeeFactor,
        uint _redeemFeeFactor,
        address _feeSink
    )
        external
        onlyOwner
    {
        require(
            _min <= PRECISION
            && _mintFeeFactor <= PRECISION
            && _redeemFeeFactor <= PRECISION,
            "INVALID_PARAMETERS"
        );
        require(_feeSink != address(0), "NULL_ADDRESS");
        min = _min;
        mintFeeFactor = _mintFeeFactor;
        redeemFeeFactor = _redeemFeeFactor;
        feeSink = _feeSink;
    }
}
