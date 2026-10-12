// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice The part of a Kuru order book (OrderBook.sol) this venue calls.
interface IKuruOrderBook {
    /// @param quoteSize Quote to spend, in the market's price precision.
    /// @return Base received, in base token decimals.
    function placeAndExecuteMarketBuy(
        uint96 quoteSize,
        uint256 minAmountOut,
        bool isMargin,
        bool isFillOrKill
    ) external payable returns (uint256);

    /// @param size Base to sell, in the market's size precision.
    /// @return Quote received, in quote token decimals.
    function placeAndExecuteMarketSell(uint96 size, uint256 minAmountOut, bool isMargin, bool isFillOrKill)
        external
        payable
        returns (uint256);

    /// @return pricePrecision, sizePrecision, base, baseDecimals, quote,
    ///         quoteDecimals, tickSize, minSize, maxSize, takerFeeBps, makerFeeBps
    function getMarketParams()
        external
        view
        returns (uint32, uint96, address, uint256, address, uint256, uint32, uint96, uint96, uint256, uint256);

    function bestBidAsk() external view returns (uint256, uint256);
}

/// @title KuruVenue
/// @notice Where Agama buys and sells stock on Monad: Kuru's on-chain order
///         book, one market per xStock against USDC.
///
///         The Arrow markets take the ERC-4626 wrapper as collateral while
///         the order book trades the base xStock, the token people hold. This
///         contract sits between the two: `buy` spends USDC on the book and
///         wraps what it gets, `sell` unwraps and sells. The zap router
///         allowlists it as both the call target and the spender, so Amplify,
///         Buy and Earn and the agents' compounding all route through Kuru with
///         nothing else changed: the accounts still measure what came back as a
///         balance delta and hold it against the oracle.
///
/// @dev    Holds nothing between transactions. What the book did not fill comes
///         back to the caller in the same call: USDC on a buy, the stock
///         (wrapped again) on a sell.
contract KuruVenue is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

    IERC20 public immutable USDC;

    /// @notice The Kuru market for each wrapper's base xStock.
    mapping(address wrapper => IKuruOrderBook) public marketOf;

    event MarketSet(address indexed wrapper, address indexed market);
    event Bought(address indexed caller, address indexed wrapper, uint256 usdcSpent, uint256 sharesOut);
    event Sold(address indexed caller, address indexed wrapper, uint256 sharesIn, uint256 usdcOut);

    error NoMarket(address wrapper);
    error MarketMismatch(address market);
    error AmountZero();
    error TooLittleOut(uint256 got, uint256 minOut);

    constructor(IERC20 usdc, address admin) {
        USDC = usdc;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
    }

    /// @notice USDC in, wrapped stock out, bought on the wrapper's Kuru market.
    /// @param usdcIn        USDC pulled from the caller (it approved this venue).
    /// @param minWrapperOut Floor on the wrapper shares sent back.
    function buy(address wrapper, uint256 usdcIn, uint256 minWrapperOut)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (usdcIn == 0) revert AmountZero();
        IKuruOrderBook market = _market(wrapper);
        (uint32 pricePrecision,,,,, uint256 quoteDecimals,,,,,) = market.getMarketParams();
        IERC20 base = IERC20(IERC4626(wrapper).asset());

        uint256 usdcBefore = USDC.balanceOf(address(this));
        uint256 baseBefore = base.balanceOf(address(this));
        USDC.safeTransferFrom(msg.sender, address(this), usdcIn);

        // The book takes quote in its own price precision: what does not fit a
        // unit stays here and goes back with the refund below.
        uint256 quoteSize = (usdcIn * pricePrecision) / 10 ** quoteDecimals;
        uint256 quoteUsed = (quoteSize * 10 ** quoteDecimals) / pricePrecision;
        USDC.forceApprove(address(market), quoteUsed);
        market.placeAndExecuteMarketBuy(uint96(quoteSize), 0, false, false);
        USDC.forceApprove(address(market), 0);

        uint256 got = base.balanceOf(address(this)) - baseBefore;
        if (got > 0) {
            base.forceApprove(wrapper, got);
            shares = IERC4626(wrapper).deposit(got, msg.sender);
        }
        if (shares < minWrapperOut) revert TooLittleOut(shares, minWrapperOut);

        uint256 refund = USDC.balanceOf(address(this)) - usdcBefore;
        if (refund > 0) USDC.safeTransfer(msg.sender, refund);
        emit Bought(msg.sender, wrapper, usdcIn - refund, shares);
    }

    /// @notice Wrapped stock in, USDC out, sold on the wrapper's Kuru market.
    /// @param sharesIn   Wrapper shares pulled from the caller (it approved this venue).
    /// @param minUsdcOut Floor on the USDC sent back.
    function sell(address wrapper, uint256 sharesIn, uint256 minUsdcOut)
        external
        nonReentrant
        returns (uint256 usdcOut)
    {
        if (sharesIn == 0) revert AmountZero();
        IKuruOrderBook market = _market(wrapper);
        (, uint96 sizePrecision,, uint256 baseDecimals,,,,,,,) = market.getMarketParams();
        IERC20 base = IERC20(IERC4626(wrapper).asset());

        uint256 usdcBefore = USDC.balanceOf(address(this));
        uint256 baseBefore = base.balanceOf(address(this));
        IERC20(wrapper).safeTransferFrom(msg.sender, address(this), sharesIn);
        uint256 baseIn = IERC4626(wrapper).redeem(sharesIn, address(this), address(this));

        uint256 size = (baseIn * sizePrecision) / 10 ** baseDecimals;
        if (size > 0) {
            uint256 baseUsed = (size * 10 ** baseDecimals) / sizePrecision;
            base.forceApprove(address(market), baseUsed);
            market.placeAndExecuteMarketSell(uint96(size), 0, false, false);
            base.forceApprove(address(market), 0);
        }

        usdcOut = USDC.balanceOf(address(this)) - usdcBefore;
        if (usdcOut < minUsdcOut) revert TooLittleOut(usdcOut, minUsdcOut);
        if (usdcOut > 0) USDC.safeTransfer(msg.sender, usdcOut);

        // Below the book's size step, or past its depth: wrapped and handed back.
        uint256 left = base.balanceOf(address(this)) - baseBefore;
        if (left > 0) {
            base.forceApprove(wrapper, left);
            IERC4626(wrapper).deposit(left, msg.sender);
        }
        emit Sold(msg.sender, wrapper, sharesIn, usdcOut);
    }

    function _market(address wrapper) internal view returns (IKuruOrderBook market) {
        market = marketOf[wrapper];
        if (address(market) == address(0)) revert NoMarket(wrapper);
    }

    // ---- Governance -----------------------------------------------------------

    /// @notice Point a wrapper at the Kuru market of its base xStock against USDC.
    function setMarket(address wrapper, IKuruOrderBook market) external onlyRole(GOVERNOR_ROLE) {
        (,, address base,, address quote,,,,,,) = market.getMarketParams();
        if (base != IERC4626(wrapper).asset() || quote != address(USDC)) {
            revert MarketMismatch(address(market));
        }
        marketOf[wrapper] = market;
        emit MarketSet(wrapper, address(market));
    }

    /// @notice Nothing should ever sit here between transactions; this is the
    ///         way out if the book ever leaves dust behind.
    function sweep(IERC20 token, address to) external onlyRole(GOVERNOR_ROLE) {
        token.safeTransfer(to, token.balanceOf(address(this)));
    }
}
