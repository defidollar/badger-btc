pragma solidity 0.6.12;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20, SafeMath} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";

import {IPeak} from "./interfaces/IPeak.sol";
import {IbBTC} from "./interfaces/IbBTC.sol";
import {ICore} from "./interfaces/ICore.sol";

import {Initializable} from "./common/Initializable.sol";
import {GovernableProxy} from "./common/GovernableProxy.sol";

import "hardhat/console.sol";  // @todo remove

contract Core is GovernableProxy, Initializable, ICore {
    using SafeERC20 for IERC20;
    using SafeMath for uint;
    using Math for uint;

    enum PeakState { Extinct, Active, Dormant }
    struct Peak {
        PeakState state;
    }

    mapping(address => Peak) public peaks;
    address[] public peaksAddresses;

    IbBTC public bBtc;

    // END OF STORAGE VARIABLES

    event PeakWhitelisted(address indexed peak);

    /**
    * @dev Used to initialize contract state from the proxy
    */
    function initialize(IbBTC _bBtc) external notInitialized {
        require(
            address(_bBtc) != address(0),
            "0 address during initialization"
        );
        bBtc = _bBtc;
    }

    /**
    * @notice Mint bBTC
    * @dev Only whitelisted peaks can call this function
    * @param btc BTC amount supplied
    * @return _bBtc Badger BTC that was minted
    */
    function mint(uint btc) override external returns(uint) {
        require(peaks[msg.sender].state == PeakState.Active, "PEAK_INACTIVE");
        uint _totalSupply = bBtc.totalSupply();
        uint _bBtc;
        if (_totalSupply > 0) {
            _bBtc = btc.mul(_totalSupply).div(totalSystemAssets());
        } else {
            _bBtc = btc;
        }
        bBtc.mint(msg.sender, _bBtc);
        return _bBtc;
    }

    /**
    * @notice Redeem bBTC
    * @dev Only whitelisted peaks can call this function
    * @param _bBtc bBTC amount to redeem
    * @return btc that user should receive
    */
    function redeem(uint _bBtc) override external returns(uint) {
        require(peaks[msg.sender].state != PeakState.Extinct, "PEAK_EXTINCT");
        uint btc = _bBtc.mul(getPricePerFullShare()).div(1e18);
        bBtc.burn(msg.sender, _bBtc);
        return btc;
    }

    /* ##### View ##### */

    function getPricePerFullShare() override public view returns (uint) {
        uint _totalSupply = bBtc.totalSupply();
        if (_totalSupply > 0) {
            return totalSystemAssets().mul(1e18).div(_totalSupply);
        }
        return 1e18;
    }

    function totalSystemAssets() public view returns (uint _totalAssets) {
        for (uint i = 0; i < peaksAddresses.length; i++) {
            Peak memory peak = peaks[peaksAddresses[i]];
            if (peak.state == PeakState.Extinct) {
                continue;
            }
            _totalAssets = _totalAssets.add(
                IPeak(peaksAddresses[i]).portfolioValue()
            );
        }
    }

    /* ##### Admin ##### */

    /**
    * @notice Whitelist a new peak
    * @param peak Address of the contract that interfaces with the 3rd-party protocol
    */
    function whitelistPeak(address peak)
        external
        onlyOwner
    {
        require(
            peaks[peak].state == PeakState.Extinct,
            "Peak already exists"
        );
        peaksAddresses.push(peak);
        peaks[peak] = Peak(PeakState.Active);
        emit PeakWhitelisted(peak);
    }

    /**
    * @notice Change a peaks status
    */
    function setPeakStatus(address peak, PeakState state)
        external
        onlyOwner
    {
        require(
            peaks[peak].state != PeakState.Extinct,
            "Peak is extinct"
        );
        peaks[peak].state = state;
    }
}
