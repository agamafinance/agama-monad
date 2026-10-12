// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice TESTNET ONLY. The testnet deployment runs the Arrow x Agama stack
///         against these stand-ins for USDC and the xStocks. Anyone can mint
///         from the faucet.
contract TestUSDC is ERC20 {
    uint256 public constant FAUCET_CAP = 10_000e6;

    constructor() ERC20("Test USD Coin (Agama, Monad testnet)", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function faucet(address to, uint256 amount) external {
        require(amount <= FAUCET_CAP, "cap");
        _mint(to, amount);
    }
}

/// @notice Stand-in for an xStock base token (1 token tracks 1 share).
contract TestXStock is ERC20 {
    uint256 public constant FAUCET_CAP = 100e18;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function faucet(address to, uint256 amount) external {
        require(amount <= FAUCET_CAP, "cap");
        _mint(to, amount);
    }
}

/// @notice ERC-4626 wrapper over a TestXStock, mirroring the Backed wrappers
///         (wTSLAx etc.) that Arrow takes as collateral on mainnet.
///         `faucet` mints base tokens and wraps them in one call.
contract TestXStockWrapper is ERC4626 {
    constructor(TestXStock base, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC4626(IERC20(address(base)))
    {}

    function faucet(address to, uint256 amount) external returns (uint256 shares) {
        shares = previewDeposit(amount);
        TestXStock(asset()).faucet(address(this), amount);
        _mint(to, shares);
    }
}

/// @notice TESTNET ONLY. A venue that prices at the Arrow oracle (minus a small
///         spread), minting the stock from its faucet: swaps work before any
///         order book has depth. Called the way an aggregator is, so the zap
///         and the accounts go through the same allowlisted path.
contract TestDexRouter {
    uint256 internal constant BPS = 10_000;

    TestUSDC public immutable USDC;
    uint256 public spreadBps;

    event Swapped(address indexed buyer, address indexed wrapper, uint256 usdcIn, uint256 stockOut);

    constructor(TestUSDC usdc, uint256 spreadBps_) {
        USDC = usdc;
        spreadBps = spreadBps_;
    }

    /// @param wrapper     Test xStock wrapper to buy.
    /// @param usdcIn      USDC pulled from the caller (it approved this router).
    /// @param priceUsdc6  Price of one wrapper token, in USDC units (6 decimals).
    function swap(TestXStockWrapper wrapper, uint256 usdcIn, uint256 priceUsdc6)
        external
        returns (uint256 out)
    {
        require(priceUsdc6 > 0, "price");
        USDC.transferFrom(msg.sender, address(this), usdcIn);
        out = (usdcIn * 1e18) / priceUsdc6;
        out = (out * (BPS - spreadBps)) / BPS;
        wrapper.faucet(msg.sender, out);
        emit Swapped(msg.sender, address(wrapper), usdcIn, out);
    }

    /// @notice The other direction, which unwinding a leveraged stock position
    ///         needs: stock in, USDC out, same spread.
    /// @dev    Mints what it pays rather than holding an inventory, the same
    ///         way the buy side mints the stock. A testnet stand-in, not a market.
    function sell(TestXStockWrapper wrapper, uint256 stockIn, uint256 priceUsdc6)
        external
        returns (uint256 out)
    {
        require(priceUsdc6 > 0, "price");
        IERC20(address(wrapper)).transferFrom(msg.sender, address(this), stockIn);
        out = (stockIn * priceUsdc6) / 1e18;
        out = (out * (BPS - spreadBps)) / BPS;
        USDC.faucet(msg.sender, out);
        emit Swapped(msg.sender, address(wrapper), out, stockIn);
    }
}
