pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20, SafeMath} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";

import {ISaddleSwap as ISwap} from "../interfaces/ISwap.sol";
import {ICore} from "../interfaces/ICore.sol";
import {ISett} from "../interfaces/ISett.sol";
import {IPeak} from "../interfaces/IPeak.sol";

import {AccessControlDefended} from "../common/AccessControlDefended.sol";

contract SaddlePeak is AccessControlDefended, IPeak {
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
    * @notice Mint bBTC with Sett LP token
    * @param poolId System internal ID of the whitelisted curve pool
    * @param inAmount Amount of Sett LP token to mint bBTC with
    * @return outAmount Amount of bBTC minted to user's account
    */
    function mint(uint poolId, uint inAmount)
        external
        defend
        blockLocked
        returns(uint outAmount)
    {
        _lockForBlock(msg.sender);
        CurvePool memory pool = pools[poolId];
        // not dividing by 1e18 allows us a gas optimization in core.mint
        uint btc = inAmount.mul(pool.swap.getVirtualPrice());
        outAmount = core.mint(btc).mul(mintFeeFactor).div(PRECISION);
        // will revert if user passed an unsupported poolId
        pool.lpToken.safeTransferFrom(msg.sender, address(this), inAmount);
        bBtc.safeTransfer(msg.sender, outAmount);
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
        defend
        blockLocked
        returns (uint outAmount)
    {
        _lockForBlock(msg.sender);
        bBtc.safeTransferFrom(msg.sender, address(this), inAmount);
        uint btc = core.redeem(inAmount.mul(redeemFeeFactor).div(PRECISION));
        CurvePool memory pool = pools[poolId];
        outAmount = btc.div(pool.swap.getVirtualPrice());
        // will revert if the contract has insufficient funds.
        pool.lpToken.safeTransfer(msg.sender, outAmount);
        emit Redeem(msg.sender, inAmount);
    }

    /**
    * @notice Collect all the accumulated fee (denominated in bBTC)
    */
    function collectAdminFee() external {
        uint amount = bBtc.balanceOf(address(this));
        if (amount > 0 && feeSink != address(0)) {
            bBtc.safeTransfer(feeSink, amount);
            emit FeeCollected(amount);
        }
    }

    function portfolioValue() override external view returns (uint) {
        CurvePool memory pool;
        uint assets;
        // We do not expect to have more than 3-4 pools, so this loop should be fine
        for (uint i = 0; i < numPools; i++) {
            pool = pools[i];
            assets = pool.lpToken.balanceOf(address(this))
                .mul(pool.swap.getVirtualPrice())
                .div(1e18)
                .add(assets);
        }
        return assets;
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
                && address(pool.sett) == address(0), // "Sett not yet supported for SaddlePeak"
                "NULL_ADDRESS"
            );
            pools[i] = CurvePool(pool.lpToken, pool.swap, pool.sett);
        }
    }

    /**
    * @notice Set config
    * @param _mintFeeFactor _mintFeeFactor = 9990 would mean a redeem fee of 0.1% (9990 / 1e4)
    * @param _redeemFeeFactor _redeemFeeFactor = 9990 would mean a redeem fee of 0.1% (9990 / 1e4)
    * @param _feeSink Address of the EOA/contract where accumulated fee will be transferred
    */
    function modifyConfig(
        uint _mintFeeFactor,
        uint _redeemFeeFactor,
        address _feeSink
    )
        external
        onlyGovernance
    {
        require(
            _mintFeeFactor <= PRECISION
            && _redeemFeeFactor <= PRECISION,
            "INVALID_PARAMETERS"
        );
        require(_feeSink != address(0), "NULL_ADDRESS");
        mintFeeFactor = _mintFeeFactor;
        redeemFeeFactor = _redeemFeeFactor;
        feeSink = _feeSink;
    }
}
