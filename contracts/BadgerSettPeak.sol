pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20, SafeMath} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";

import {ISwap} from "./interfaces/ISwap.sol";
import {ICore} from "./interfaces/ICore.sol";
import {ISett} from "./interfaces/ISett.sol";
import {IPeak} from "./interfaces/IPeak.sol";
import {AccessControlDefended} from "./common/AccessControlDefended.sol";

import "hardhat/console.sol";

contract BadgerSettPeak is AccessControlDefended, IPeak {
    using SafeERC20 for IERC20;
    using SafeERC20 for ISett;
    using SafeMath for uint;
    using Math for uint;

    ICore public immutable core;

    struct CurvePool {
        IERC20 lpToken;
        ISwap swap;
        ISett sett;
    }
    mapping(uint => CurvePool) public pools;
    uint public numPools;

    // END OF STORAGE VARIABLES

    event Mint(address account, uint amount);
    event Redeem(address account, uint amount);

    /**
    * @param _core Address of the the Core contract
    */
    constructor(address _core) public {
        core = ICore(_core);
    }

    /**
    * @notice Mint bBTC with Sett LP token
    * @param poolId System internal ID of the whitelisted curve pool
    * @param inAmount Amount of Sett LP token to mint bBTC with
    * @return outAmount Amount of bBTC minted to user's account
    */
    function mint(uint poolId, uint inAmount)
        external
        override
        defend
        blockLocked
        returns(uint outAmount)
    {
        _lockForBlock(msg.sender);
        CurvePool memory pool = pools[poolId];
        outAmount = core.mint(_settToBtc(pool, inAmount), msg.sender);
        console.log("outAmount %d", outAmount);
        // will revert if user passed an unsupported poolId
        pool.sett.safeTransferFrom(msg.sender, address(this), inAmount);
        emit Mint(msg.sender, outAmount);
    }

    /**
    * @notice Redeem bBTC in Sett LP tokens
    * @dev There might not be enough Sett LP to fulfill the request, in which case the transaction will revert
    * @param poolId System internal ID of the whitelisted curve pool
    * @param inAmount Amount of bBTC to redeem
    * @return outAmount Amount of Sett LP token
    */
    function redeem(uint poolId, uint inAmount)
        external
        override
        defend
        blockLocked
        returns (uint outAmount)
    {
        _lockForBlock(msg.sender);
        CurvePool memory pool = pools[poolId];
        uint btc = core.redeem(inAmount, msg.sender);
        outAmount = _btcToSett(pool, btc);
        // console.log("redeem: btc %d, outAmount %d, bal %d", btc, outAmount, pool.sett.balanceOf(address(this)));
        console.log("redeem: outAmount %d, bal %d", outAmount, pool.sett.balanceOf(address(this)));
        // console.log("redeem: outAmount %d, bal %d, diff %d", outAmount, pool.sett.balanceOf(address(this)), outAmount.sub(pool.sett.balanceOf(address(this))));
        // will revert if the contract has insufficient funds.
        // This opens up a couple front-running vectors. @todo Discuss with Badger team about possibilities.
        pool.sett.safeTransfer(msg.sender, outAmount);
        emit Redeem(msg.sender, inAmount);
    }

    /* ##### View ##### */

    function calcMint(uint poolId, uint inAmount) override external view returns(uint bBtc) {
        (bBtc,) = core.btcToBbtc(_settToBtc(pools[poolId], inAmount));
    }

    function calcRedeem(uint poolId, uint bBtc) override external view returns(uint) {
        (uint btc,) = core.bBtcToBtc(bBtc);
        uint outAmount = _btcToSett(pools[poolId], btc);
        console.log("calcRedeem: btc %d, outAmount %d", btc, outAmount);
        return outAmount;
    }

    function portfolioValue()
        override
        external
        view
        returns (uint assets)
    {
        CurvePool memory pool;
        // We do not expect to have more than 3-4 pools, so this loop should be fine
        for (uint i = 0; i < numPools; i++) {
            pool = pools[i];
            assets = assets.add(
                _settToBtc(
                    pool,
                    pool.sett.balanceOf(address(this))
                )
            );
        }
    }

    /**
    * @param btc BTC amount scaled by 1e18
    */
    function _btcToSett(CurvePool memory pool, uint btc)
        internal
        view
        returns(uint)
    {
        return btc
            .mul(1e18)
            .div(pool.sett.getPricePerFullShare())
            .div(pool.swap.get_virtual_price());
    }

    function _settToBtc(CurvePool memory pool, uint amount)
        internal
        view
        returns(uint)
    {
        // will revert for amount > 1e41
        // It's not possible to supply that amount because btc supply is capped at 21e24
        return amount
            .mul(pool.sett.getPricePerFullShare())
            .mul(pool.swap.get_virtual_price())
            .div(1e36);
    }

    /* ##### Admin ##### */

    /**
    * @notice Manage whitelisted curve pools and their respective sett vaults
    */
    function modifyWhitelistedCurvePools(
        CurvePool[] calldata _pools
    )
        external
        onlyGovernance
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
}
