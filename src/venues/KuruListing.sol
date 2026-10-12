// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Kuru's market factory (Router.sol).
interface IKuruRouter {
    /// @param marketType 0: two ERC-20s.
    function deployProxy(
        uint8 marketType,
        address base,
        address quote,
        uint96 sizePrecision,
        uint32 pricePrecision,
        uint32 tickSize,
        uint96 minSize,
        uint96 maxSize,
        uint256 takerFeeBps,
        uint256 makerFeeBps,
        uint96 kuruAmmSpread
    ) external returns (address market);
}

/// @notice Kuru's MarginAccount: where resting orders draw their funds from.
interface IKuruMarginAccount {
    function deposit(address user, address token, uint256 amount) external payable;
    function withdraw(uint256 amount, address token) external;
    function getBalance(address user, address token) external view returns (uint256);
}

/// @notice The limit-order side of a Kuru order book, for whoever quotes it.
interface IKuruMaker {
    function batchUpdate(
        uint32[] calldata buyPrices,
        uint96[] calldata buySizes,
        uint32[] calldata sellPrices,
        uint96[] calldata sellSizes,
        uint40[] calldata orderIdsToCancel,
        bool postOnly
    ) external;
}

/// @title KuruListing
/// @notice How Agama lists a test xStock on Kuru, shared by the listing script
///         and the tests so both create the same market.
///
///         Prices are quoted to the cent (price precision 1e4, tick 100: the
///         four stocks sit between $100 and $1,000, well inside a uint32 at
///         that precision) and sizes to a ten-thousandth of a share. No fees:
///         the venue is checked against the oracle on every swap, and a fee
///         would only widen what that check has to tolerate. The AMM spread is
///         the minimum Kuru accepts; nobody deposits in the vault, the book's
///         depth comes from quoted orders.
library KuruListing {
    /// Monad testnet (10143), docs.kuru.io/contracts/Contract-addresses.
    address internal constant ROUTER = 0x7EFbE105Ca7415dE98F96622173458ac1c054630;
    address internal constant MARGIN_ACCOUNT = 0xd029C2D98ff85D8F64799017fE00a59B1159CE02;

    uint32 internal constant PRICE_PRECISION = 1e4;
    uint32 internal constant TICK_SIZE = 100;
    uint96 internal constant SIZE_PRECISION = 1e4;
    uint96 internal constant MIN_SIZE = 1;
    uint96 internal constant MAX_SIZE = 1e12;
    uint96 internal constant AMM_SPREAD_BPS = 10;

    function list(address base, address usdc) internal returns (address market) {
        market = IKuruRouter(ROUTER)
            .deployProxy(
                0,
                base,
                usdc,
                SIZE_PRECISION,
                PRICE_PRECISION,
                TICK_SIZE,
                MIN_SIZE,
                MAX_SIZE,
                0,
                0,
                AMM_SPREAD_BPS
            );
    }

    /// @notice A USDC price with 6 decimals, on the book's grid (rounded down).
    function toBookPrice(uint256 usdc6) internal pure returns (uint32) {
        uint256 p = (usdc6 * PRICE_PRECISION) / 1e6;
        return uint32(p - (p % TICK_SIZE));
    }

    /// @notice A whole-token amount with 18 decimals, in book size units.
    function toBookSize(uint256 amount18) internal pure returns (uint96) {
        return uint96((amount18 * SIZE_PRECISION) / 1e18);
    }
}
