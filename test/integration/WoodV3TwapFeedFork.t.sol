// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WoodV3TwapFeed, IEthUsdAggregator} from "../../src/pricing/WoodV3TwapFeed.sol";
import {IUniswapV3Pool} from "../../src/vendor/uniswap/IUniswapV3Pool.sol";

interface IUniswapV3PoolSwap {
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata)
        external
        returns (int256, int256);
}

/**
 * @title WoodV3TwapFeedForkTest
 * @notice `WoodV3TwapFeed` against the LIVE WOOD/WETH Uniswap V3 pool on Robinhood
 *         Chain mainnet (4663), with real swaps through the real pool bytecode.
 *
 *         On-chain facts (probed 2026-10-13): the pool is canonical Uniswap V3
 *         (its address is CREATE2 of the canonical init code hash under factory
 *         0xE51960f1…), WETH is token0, `observationCardinality` is 1, and the
 *         chain mints about 10 blocks per `block.timestamp` second.
 *
 * @dev Skips when ROBINHOOD_RPC_URL is unset; excluded from default CI by the
 *      `test/integration/**` path filter. Run:
 *        set -a; source .env; set +a
 *        forge test --match-path "test/integration/WoodV3TwapFeedFork.t.sol" -vv
 */
contract WoodV3TwapFeedForkTest is Test {
    address constant WOOD = 0xF8BC08092C06dB6148114DCf82AF881F1085f92b;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant V3_POOL = 0xF6831AaF374B353757F0dE6B3DD2a74697671C69;
    address constant ETH_USD_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;

    uint32 constant WINDOW = 1 hours;
    uint128 constant MIN_V3_LIQUIDITY = 1e22;
    /// @dev Looser than the deploy value: the warp ages the live Chainlink round.
    uint256 constant ETH_USD_MAX_AGE = 3 days;
    uint16 constant RING = uint16(WINDOW) + 60;
    /// @dev Each leg moves the pool about two ticks, so every swap is eligible to write.
    uint256 constant WETH_IN = 0.003e18;
    uint256 constant WOOD_IN = 2_200e18;
    uint160 constant MIN_SQRT_RATIO = 4295128739;
    uint160 constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    WoodV3TwapFeed internal feed;
    bool internal wethIsToken0;

    function _fork() internal returns (bool) {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(rpc);
        require(block.chainid == 4663, "not Robinhood mainnet");
        wethIsToken0 = IUniswapV3Pool(V3_POOL).token0() == WETH;
        feed = new WoodV3TwapFeed(V3_POOL, WOOD, WETH, ETH_USD_FEED, ETH_USD_MAX_AGE, WINDOW, MIN_V3_LIQUIDITY);
        deal(WETH, address(this), 1_000e18);
        deal(WOOD, address(this), 100_000_000e18);
        return true;
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        require(msg.sender == V3_POOL, "not the pool");
        // The positive delta is what the pool is owed.
        if (amount0Delta > 0) IERC20(IUniswapV3Pool(V3_POOL).token0()).transfer(V3_POOL, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(IUniswapV3Pool(V3_POOL).token1()).transfer(V3_POOL, uint256(amount1Delta));
    }

    function _swap(bool wethIn) internal {
        bool zeroForOne = wethIn == wethIsToken0;
        IUniswapV3PoolSwap(V3_POOL)
            .swap(
                address(this),
                zeroForOne,
                int256(wethIn ? WETH_IN : WOOD_IN),
                zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1,
                ""
            );
    }

    /// @dev `secs` seconds of the fastest possible writing: two tick-moving swaps
    ///      in two different blocks of every second.
    function _spam(uint256 secs) internal {
        for (uint256 i = 0; i < secs; i++) {
            vm.warp(vm.getBlockTimestamp() + 1);
            vm.roll(vm.getBlockNumber() + 1);
            _swap(true);
            vm.roll(vm.getBlockNumber() + 1);
            _swap(false);
        }
    }

    function _slot0() internal view returns (uint160 sqrtPriceX96, uint16 index, uint16 cardinality) {
        (sqrtPriceX96,, index, cardinality,,,) = IUniswapV3Pool(V3_POOL).slot0();
    }

    /// @notice A ring of one slot per window second serves the window through two swaps per second.
    function test_fork_ringOfOneSlotPerSecondSurvivesSwapSpam() public {
        if (!_fork()) return;
        IUniswapV3Pool(V3_POOL).increaseObservationCardinalityNext(RING);

        _spam(2 * uint256(WINDOW));

        (uint160 sqrtPriceX96, uint16 index, uint16 cardinality) = _slot0();
        assertEq(cardinality, RING, "the ring reached its target");
        // 14,400 swaps in 7,200 seconds: one observation per second, so the index wrapped once.
        assertEq(index, (2 * uint256(WINDOW)) % RING, "one write per second, not per block");

        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(updatedAt, vm.getBlockTimestamp());

        // Independent of the feed's tick math: spot from sqrtPriceX96, in USD at 8 decimals.
        (, int256 ethUsd,,,) = IEthUsdAggregator(ETH_USD_FEED).latestRoundData();
        uint256 priceX96 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96);
        uint256 spotX8 = wethIsToken0
            ? Math.mulDiv(uint256(ethUsd), 1 << 96, priceX96)
            : Math.mulDiv(uint256(ethUsd), priceX96, 1 << 96);
        assertApproxEqRel(uint256(answer), spotX8, 0.02e18, "the hour's mean sits at spot");
    }

    /// @notice Control: at the live cardinality of 1, any swap in the last hour makes the read `OLD`.
    function test_fork_control_theLiveRingOfOneCannotServeTheWindow() public {
        if (!_fork()) return;
        (,, uint16 cardinality) = _slot0();
        assertEq(cardinality, 1, "the live ring grew: re-read the header of this file");

        _spam(3);

        vm.expectRevert(bytes("OLD"));
        feed.latestRoundData();
    }
}
