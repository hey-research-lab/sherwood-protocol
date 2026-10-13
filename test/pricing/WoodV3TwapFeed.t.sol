// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {WoodV3TwapFeed} from "src/pricing/WoodV3TwapFeed.sol";
import {ExposureLedger} from "src/ExposureLedger.sol";
import {MockUniswapV3Pool} from "test/mocks/MockUniswapV3Pool.sol";
import {MockUniswapV3PoolRing} from "test/mocks/MockUniswapV3PoolRing.sol";
import {MockAggregatorV3} from "test/mocks/MockAggregatorV3.sol";

/// @dev A pool whose `observe` hands back a seated cumulative pair, so a test can
///      give the feed a delta that does not divide by the window.
contract SeatedCumulativesPool {
    address public immutable token0;
    address public immutable token1;
    uint128 public liquidity = 2e22;
    int56 internal _from;
    int56 internal _to;

    constructor(address token0_, address token1_, int56 from_, int56 to_) {
        (token0, token1, _from, _to) = (token0_, token1_, from_, to_);
    }

    function observe(uint32[] calldata) external view returns (int56[] memory c, uint160[] memory s) {
        c = new int56[](2);
        s = new uint160[](2);
        (c[0], c[1]) = (_from, _to);
    }
}

/// @dev The only sWOOD reads the ledger makes.
contract TwapFeedSwood {
    function coolDownPeriod() external pure returns (uint256) {
        return 7 days;
    }
}

abstract contract WoodV3TwapFeedFixture is Test {
    address internal constant WOOD = address(uint160(0xD00D));
    address internal constant WETH = address(uint160(0xE7E7));

    uint128 internal constant MIN_V3_LIQUIDITY = 1e22;
    uint128 internal constant V3_LIQUIDITY = 2e22;
    uint32 internal constant WINDOW = 1 hours;
    uint256 internal constant ETH_MAX_AGE = 26 hours;
    int256 internal constant ETH_USD_X8 = 3000e8;

    /// @dev `1.0001 ** -136339` is 1.2e-6 WETH per WOOD, $0.0036 at $3,000/ETH.
    ///      A tick is a 0.01% step, so answers are held to 0.1%, not to the wei.
    int24 internal constant TICK = -136_339;
    int24 internal constant TICKS_PER_DOUBLING = 6932;
    uint256 internal constant ANSWER_X8 = 360_000;

    MockAggregatorV3 internal ethUsd;

    function _newPool(address token0, address token1, int24 twapTick) internal returns (MockUniswapV3Pool p) {
        p = new MockUniswapV3Pool(token0, token1, 3000, 60, makeAddr("v3Factory"));
        p.setLiquidity(V3_LIQUIDITY);
        p.setTicks(twapTick, twapTick);
    }

    function _feed(address pool) internal returns (WoodV3TwapFeed) {
        return new WoodV3TwapFeed(pool, WOOD, WETH, address(ethUsd), ETH_MAX_AGE, WINDOW, MIN_V3_LIQUIDITY);
    }

    function _answer(WoodV3TwapFeed feed) internal view returns (uint256) {
        (, int256 a,,,) = feed.latestRoundData();
        return uint256(a);
    }
}

contract WoodV3TwapFeedTest is WoodV3TwapFeedFixture {
    MockUniswapV3Pool internal pool;
    WoodV3TwapFeed internal feed;

    function setUp() public {
        vm.warp(1_800_000_000);
        ethUsd = new MockAggregatorV3(8, ETH_USD_X8);
        pool = _newPool(WOOD, WETH, TICK);
        feed = _feed(address(pool));
    }

    /// @notice The answer is the pool's mean tick over the window, in USD at 8 decimals.
    function test_answersTheWindowMeanTickInUsd() public view {
        assertApproxEqRel(_answer(feed), ANSWER_X8, 0.001e18);
        assertEq(feed.decimals(), 8);
    }

    /// @notice A pool holding WOOD as token1 prices WETH in WOOD, and the feed inverts it.
    function test_answersTheSamePriceWhenWoodIsToken1() public {
        WoodV3TwapFeed flipped = _feed(address(_newPool(WETH, WOOD, -TICK)));
        assertApproxEqRel(_answer(flipped), ANSWER_X8, 0.001e18);
    }

    /// @notice Spot standing at twice the average does not move the answer.
    function test_readsTheAverageNotSpot() public {
        pool.setTicks(TICK + TICKS_PER_DOUBLING, TICK);
        assertApproxEqRel(_answer(feed), ANSWER_X8, 0.001e18);
    }

    /// @notice A mean tick with a remainder rounds toward negative infinity, as v3-periphery does.
    function test_roundsANegativeMeanTickDown() public {
        int56 exact = int56(TICK - 1) * int56(uint56(WINDOW));
        WoodV3TwapFeed floored = _feed(address(new SeatedCumulativesPool(WOOD, WETH, 0, exact)));
        // One short of TICK * WINDOW: truncation would answer TICK, the floor answers TICK - 1.
        int56 inexact = int56(TICK) * int56(uint56(WINDOW)) - 1;
        WoodV3TwapFeed remainder = _feed(address(new SeatedCumulativesPool(WOOD, WETH, 0, inexact)));

        assertEq(_answer(remainder), _answer(floored));
        assertLt(_answer(remainder), _answer(feed));
    }

    /// @notice `updatedAt` is the read time: nothing has to be called for the answer to stay fresh.
    function test_updatedAtIsTheReadTime() public {
        vm.warp(vm.getBlockTimestamp() + 10 days);
        ethUsd.setUpdatedAt(vm.getBlockTimestamp());

        (,, uint256 startedAt, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(updatedAt, vm.getBlockTimestamp());
        assertEq(startedAt, vm.getBlockTimestamp());
    }

    /// @notice In-range liquidity below the floor is refused; exactly the floor answers.
    function test_revertsBelowTheLiquidityFloor() public {
        pool.setLiquidity(MIN_V3_LIQUIDITY);
        assertApproxEqRel(_answer(feed), ANSWER_X8, 0.001e18);

        pool.setLiquidity(MIN_V3_LIQUIDITY - 1);
        vm.expectRevert(WoodV3TwapFeed.PriceUnavailable.selector);
        feed.latestRoundData();
    }

    /// @notice An ETH/USD round older than the max age is refused; exactly the max age answers.
    function test_revertsOnAStaleEthLeg() public {
        uint256 published = vm.getBlockTimestamp();
        vm.warp(published + ETH_MAX_AGE);
        assertApproxEqRel(_answer(feed), ANSWER_X8, 0.001e18);

        vm.warp(published + ETH_MAX_AGE + 1);
        vm.expectRevert(WoodV3TwapFeed.PriceUnavailable.selector);
        feed.latestRoundData();
    }

    /// @notice A non-positive ETH/USD answer is refused.
    function test_revertsOnANonPositiveEthAnswer() public {
        ethUsd.setAnswer(-1);
        vm.expectRevert(WoodV3TwapFeed.PriceUnavailable.selector);
        feed.latestRoundData();
    }

    /// @notice A pool that cannot serve the window makes the feed unavailable, never wrong.
    function test_revertsWhenThePoolCannotServeTheWindow() public {
        pool.setObserveReverts(true);
        vm.expectRevert(bytes("OLD"));
        feed.latestRoundData();
    }

    /// @notice A pool holding anything other than exactly {WOOD, WETH} is refused at construction.
    function test_constructor_refusesAPoolOfOtherTokens() public {
        address other = _newPoolAddress(WOOD, makeAddr("notWeth"));
        vm.expectRevert(WoodV3TwapFeed.InvalidParameter.selector);
        _feed(other);
    }

    /// @notice A window under `MIN_WINDOW` is refused; exactly `MIN_WINDOW` deploys.
    function test_constructor_refusesAWindowBelowTheMinimum() public {
        uint32 min = feed.MIN_WINDOW();
        new WoodV3TwapFeed(address(pool), WOOD, WETH, address(ethUsd), ETH_MAX_AGE, min, MIN_V3_LIQUIDITY);

        vm.expectRevert(WoodV3TwapFeed.InvalidParameter.selector);
        new WoodV3TwapFeed(address(pool), WOOD, WETH, address(ethUsd), ETH_MAX_AGE, min - 1, MIN_V3_LIQUIDITY);
    }

    /// @notice A zero liquidity floor or a zero ETH/USD max age is refused.
    function test_constructor_refusesZeroBounds() public {
        vm.expectRevert(WoodV3TwapFeed.InvalidParameter.selector);
        new WoodV3TwapFeed(address(pool), WOOD, WETH, address(ethUsd), ETH_MAX_AGE, WINDOW, 0);

        vm.expectRevert(WoodV3TwapFeed.InvalidParameter.selector);
        new WoodV3TwapFeed(address(pool), WOOD, WETH, address(ethUsd), 0, WINDOW, MIN_V3_LIQUIDITY);
    }

    /// @notice An ETH/USD feed reporting more than 18 decimals is refused at construction.
    function test_constructor_refusesAnEthFeedAboveEighteenDecimals() public {
        address wide = address(new MockAggregatorV3(19, ETH_USD_X8));
        vm.expectRevert(WoodV3TwapFeed.InvalidParameter.selector);
        new WoodV3TwapFeed(address(pool), WOOD, WETH, wide, ETH_MAX_AGE, WINDOW, MIN_V3_LIQUIDITY);
    }

    /// @notice A price that rounds to zero at 8 decimals is unavailable, not zero.
    function test_revertsWhenThePriceRoundsToZero() public {
        WoodV3TwapFeed dust = _feed(address(_newPool(WOOD, WETH, -800_000)));
        vm.expectRevert(WoodV3TwapFeed.PriceUnavailable.selector);
        dust.latestRoundData();
    }

    /// @notice A mean tick outside the V3 tick range is unavailable.
    function test_revertsOnAMeanTickOutsideTheTickRange() public {
        int56 below = (int56(-887_272) - 1) * int56(uint56(WINDOW));
        WoodV3TwapFeed out = _feed(address(new SeatedCumulativesPool(WOOD, WETH, 0, below)));
        vm.expectRevert(WoodV3TwapFeed.PriceUnavailable.selector);
        out.latestRoundData();
    }

    function _newPoolAddress(address token0, address token1) internal returns (address) {
        return address(_newPool(token0, token1, TICK));
    }
}

/// @notice The same feed against a REAL observation ring (v1 audit F2: the ring is
///         written by any swapper, so `observe` is only as deep as the ring is sized).
contract WoodV3TwapFeedRingTest is WoodV3TwapFeedFixture {
    MockUniswapV3PoolRing internal ring;
    WoodV3TwapFeed internal feed;
    int24 internal wiggle;

    function setUp() public {
        vm.warp(1_800_000_000);
        ethUsd = new MockAggregatorV3(8, ETH_USD_X8);
        ring = new MockUniswapV3PoolRing(WOOD, WETH, TICK, V3_LIQUIDITY);
        feed = _feed(address(ring));
    }

    /// @dev The fastest a ring can be written: one tick-moving swap in every second.
    function _spam(uint256 secs) internal {
        for (uint256 i = 0; i < secs; i++) {
            vm.warp(vm.getBlockTimestamp() + 1);
            wiggle = wiggle == 0 ? int24(1) : int24(0);
            ring.swap(TICK + wiggle);
        }
        ethUsd.setUpdatedAt(vm.getBlockTimestamp());
    }

    /// @notice A ring with one slot per second of the window cannot be evicted by swap spam.
    function test_aRingOfOneSlotPerWindowSecondSurvivesPerSecondSwaps() public {
        ring.increaseObservationCardinalityNext(uint16(WINDOW) + 1);
        _spam(3 * uint256(WINDOW));

        assertApproxEqRel(_answer(feed), ANSWER_X8, 0.001e18);
    }

    /// @notice Control for the test above: the same spam evicts a ring sized below the window.
    function test_control_perSecondSwapsEvictAnUndersizedRing() public {
        ring.increaseObservationCardinalityNext(uint16(WINDOW) / 2);
        _spam(3 * uint256(WINDOW));

        vm.expectRevert(bytes("OLD"));
        feed.latestRoundData();
    }

    /// @notice After the ring is grown the feed answers once its oldest observation is a window old.
    function test_answersAWindowAfterTheOldestObservation() public {
        ring.increaseObservationCardinalityNext(uint16(WINDOW) + 1);
        _spam(uint256(WINDOW) - 1);
        vm.expectRevert(bytes("OLD"));
        feed.latestRoundData();

        _spam(1);
        assertApproxEqRel(_answer(feed), ANSWER_X8, 0.001e18);
    }
}

/// @notice The ledger prices WOOD off the feed with no keeper and a bound of one window.
contract WoodV3TwapFeedLedgerTest is WoodV3TwapFeedFixture {
    uint256 internal constant CAP_X8 = 720_000; // 2x the feed

    /// @notice Ten days with nothing called: the ledger still resolves the haircut feed price.
    function test_ledgerReadsWithNoKeeper() public {
        vm.warp(1_800_000_000);
        ethUsd = new MockAggregatorV3(8, ETH_USD_X8);
        WoodV3TwapFeed feed = _feed(address(_newPool(WOOD, WETH, TICK)));

        address owner = makeAddr("owner");
        ExposureLedger ledger = new ExposureLedger(owner, address(new TwapFeedSwood()), 7 days);
        vm.startPrank(owner);
        ledger.setWoodUsdPrice(CAP_X8);
        ledger.setWoodFeed(address(feed), WINDOW);
        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + 10 days);
        ethUsd.setUpdatedAt(vm.getBlockTimestamp());

        uint256 haircutBps = ledger.woodHaircutBps();
        assertEq(ledger.woodPriceX8(), (_answer(feed) * haircutBps) / 10_000);
    }
}
