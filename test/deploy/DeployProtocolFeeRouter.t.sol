// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {ProtocolFeeRouter} from "../../src/ProtocolFeeRouter.sol";
import {DeployProtocolFeeRouter} from "../../script/robinhood-mainnet/DeployProtocolFeeRouter.s.sol";

contract DeployProtocolFeeRouterTest is Test {
    DeployProtocolFeeRouter script;
    address safe = makeAddr("safe");

    function setUp() public {
        script = new DeployProtocolFeeRouter();
        vm.etch(safe, hex"00");
    }

    /// @notice The router comes out owned by the Safe, nothing pending, in hold mode.
    function test_deployHandsTheRouterToTheSafeInHoldMode() public {
        ProtocolFeeRouter router = script.deploy(safe);
        assertEq(router.owner(), safe);
        assertEq(router.pendingOwner(), address(0));
        assertEq(router.allocations().length, 0);
    }

    /// @notice An EOA owner is refused.
    function test_deployRefusesAnEoaOwner() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert("DeployProtocolFeeRouter: the Safe must be a contract, not an EOA");
        script.deploy(eoa);
    }
}
