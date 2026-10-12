// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Deployer} from "./Deployer.sol";
import {TestUSDC, TestXStock, TestXStockWrapper, TestDexRouter} from "../src/mocks/TestnetTokens.sol";

/// @notice Monad testnet (10143). The Arrow x Agama stack on public-faucet
///         stand-ins for USDC and the wrapped xStocks, priced by Chainlink Data
///         Streams reports verified on chain by Chainlink's VerifierProxy.
///
///   forge script script/DeployTestnet.s.sol --rpc-url monad_testnet --broadcast --slow \
///     --private-key $DEPLOYER_KEY
contract DeployTestnet is Script, Deployer {
    function run() external returns (Deployment memory d) {
        address admin = msg.sender;
        vm.startBroadcast();
        TestUSDC usdc = new TestUSDC();
        TestXStockWrapper wTsla = _pair("Tesla", "TSLA");
        TestXStockWrapper wNvda = _pair("NVIDIA", "NVDA");
        TestXStockWrapper wSpy = _pair("SP500", "SPY");
        TestXStockWrapper wAapl = _pair("Apple", "AAPL");

        Config memory cfg = Config({
            admin: admin,
            keeper: vm.envOr("KEEPER", admin),
            guardian: admin,
            treasury: admin,
            supplyCapUsdc: 1_000_000e6,
            borrowCapUsdc: 500_000e6,
            spCooldown: 1 hours,
            assets: Assets({
                usdc: address(usdc),
                wTsla: address(wTsla),
                wNvda: address(wNvda),
                wSpy: address(wSpy),
                wAapl: address(wAapl),
                verifierProxy: vm.envAddress("DS_VERIFIER_PROXY")
            })
        });
        d = _deployAll(cfg);

        // Stand-in venue that prices at the oracle: swaps work from the first
        // block, before any order book has depth.
        TestDexRouter dex = new TestDexRouter(usdc, 30);
        d.zap.setTarget(address(dex), true);
        d.zap.setSpender(address(dex), true);

        // Seed: Arrow lenders and the stability pool.
        for (uint256 i; i < 3; ++i) {
            usdc.faucet(admin, 10_000e6);
        }
        usdc.approve(address(d.pool), 20_000e6);
        d.pool.deposit(20_000e6, admin);
        usdc.approve(address(d.sp), 5_000e6);
        d.sp.depositUSDC(5_000e6, admin);
        vm.stopBroadcast();

        _write(d, cfg, address(dex));
    }

    function _pair(string memory name, string memory ticker) internal returns (TestXStockWrapper w) {
        TestXStock base = new TestXStock(string.concat("Test ", name, " xStock"), string.concat(ticker, "x"));
        w = new TestXStockWrapper(
            base, string.concat("Wrapped Test ", name, " xStock"), string.concat("w", ticker, "x")
        );
    }

    function _write(Deployment memory d, Config memory cfg, address dex) internal {
        string memory c = "contracts";
        vm.serializeAddress(c, "oracle", address(d.oracle));
        vm.serializeAddress(c, "agUSD", address(d.ag));
        vm.serializeAddress(c, "sagUSD", address(d.vault));
        vm.serializeAddress(c, "queue", address(d.queue));
        vm.serializeAddress(c, "pool", address(d.pool));
        vm.serializeAddress(c, "stabilityPool", address(d.sp));
        vm.serializeAddress(c, "factory", address(d.factory));
        vm.serializeAddress(c, "earnRouter", address(d.earn));
        vm.serializeAddress(c, "zapRouter", address(d.zap));
        vm.serializeAddress(c, "testDexRouter", dex);
        vm.serializeAddress(c, "verifierProxy", cfg.assets.verifierProxy);
        string memory contracts = vm.serializeAddress(c, "amplifyRouter", address(d.amplify));

        string memory a = "adapters";
        vm.serializeAddress(a, "TSLA", address(d.tsla));
        vm.serializeAddress(a, "NVDA", address(d.nvda));
        vm.serializeAddress(a, "SPY", address(d.spy));
        vm.serializeAddress(a, "AAPL", address(d.aapl));
        string memory adapters = vm.serializeAddress(a, "VAULT", address(d.vaultAdapter));

        string memory t = "tokens";
        vm.serializeAddress(t, "USDC", cfg.assets.usdc);
        vm.serializeAddress(t, "wTSLAx", cfg.assets.wTsla);
        vm.serializeAddress(t, "wNVDAx", cfg.assets.wNvda);
        vm.serializeAddress(t, "wSPYx", cfg.assets.wSpy);
        string memory tokens = vm.serializeAddress(t, "wAAPLx", cfg.assets.wAapl);

        string memory r = "root";
        vm.serializeUint(r, "chainId", block.chainid);
        vm.serializeUint(r, "deployedAtBlock", block.number);
        vm.serializeAddress(r, "admin", cfg.admin);
        vm.serializeAddress(r, "keeper", cfg.keeper);
        vm.serializeString(r, "contracts", contracts);
        vm.serializeString(r, "adapters", adapters);
        string memory json = vm.serializeString(r, "tokens", tokens);
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, path);
        console.log("written", path);
    }
}
