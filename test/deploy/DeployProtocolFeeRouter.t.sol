// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {ProtocolFeeRouter} from "../../src/ProtocolFeeRouter.sol";
import {DeploySalts} from "../../script/DeploySalts.sol";
import {DeployProtocolFeeRouter} from "../../script/robinhood-mainnet/DeployProtocolFeeRouter.s.sol";

contract DeployProtocolFeeRouterHarness is DeployProtocolFeeRouter {
    function predicted() external returns (address) {
        return _predict(_c3Factory(msg.sender), DeploySalts.PROTOCOL_FEE_ROUTER);
    }
}

/// @dev Every call is pranked as the script: `_c3Factory` bootstraps the CREATE3 factory at
///      `msg.sender` and `c3.deploy` is `onlyOwner`, called by the script itself.
contract DeployProtocolFeeRouterTest is Test {
    DeployProtocolFeeRouterHarness script;
    address safe = makeAddr("safe");

    function setUp() public {
        script = new DeployProtocolFeeRouterHarness();
        vm.etch(safe, hex"00");
    }

    function _deploy(address owner_) internal returns (ProtocolFeeRouter) {
        vm.prank(address(script));
        return script.deploy(owner_);
    }

    /// @notice The router lands at its CREATE3 salt, owned by the Safe, nothing pending, in hold mode.
    function test_deployMintsAtTheSaltForTheSafeInHoldMode() public {
        ProtocolFeeRouter router = _deploy(safe);
        vm.prank(address(script));
        assertEq(address(router), script.predicted());
        assertEq(router.owner(), safe);
        assertEq(router.pendingOwner(), address(0));
        assertEq(router.allocations().length, 0);
    }

    /// @notice A re-run adopts the router already at the salt instead of minting a second one.
    function test_aRerunAdoptsTheSameRouter() public {
        ProtocolFeeRouter first = _deploy(safe);
        assertEq(address(_deploy(safe)), address(first));
    }

    /// @notice An EOA owner is refused.
    function test_deployRefusesAnEoaOwner() public {
        address eoa = makeAddr("eoa");
        vm.prank(address(script));
        vm.expectRevert("DeployProtocolFeeRouter: the Safe must be a contract, not an EOA");
        script.deploy(eoa);
    }
}
