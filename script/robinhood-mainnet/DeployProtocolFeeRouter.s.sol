// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ScriptBase} from "../ScriptBase.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {ProtocolFeeRouter} from "../../src/ProtocolFeeRouter.sol";

/// @title  DeployProtocolFeeRouter
/// @notice Deploys the protocol-leg fee router (SHE-239), owned by the Safe and in hold mode, records it
///         as `PROTOCOL_FEE_ROUTER`, and prints the `setProtocolFeeRecipient` call for the config owner.
/// @dev    Seat it AFTER DeployAll run 2 (whose validation pins the recipient to the deployer) and BEFORE
///         the first proposal: the governor snapshots the recipient at propose.
///
///   forge script script/robinhood-mainnet/DeployProtocolFeeRouter.s.sol:DeployProtocolFeeRouter \
///     --rpc-url robinhood --broadcast --sig "run(address)" <SAFE>
///
///   The Safe is an argument, not the book's `OWNER_MULTISIG`: during the deferred-handoff launch the
///   book names the deployer there.
contract DeployProtocolFeeRouter is ScriptBase {
    function run(address safe) external returns (ProtocolFeeRouter router) {
        address existing = _optionalAddress("PROTOCOL_FEE_ROUTER");
        require(existing == address(0) || existing.code.length == 0, "PROTOCOL_FEE_ROUTER already deployed");
        ProtocolConfig config = ProtocolConfig(_readAddress("PROTOCOL_CONFIG"));

        vm.startBroadcast();
        router = deploy(safe);
        vm.stopBroadcast();

        // A dry run's address is a simulation, so only a broadcast writes the book.
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) _patchAddress("PROTOCOL_FEE_ROUTER", address(router));

        console.log("ProtocolFeeRouter:", address(router));
        console.log("owner (Safe):", safe);
        console.log("NEXT, from the ProtocolConfig owner", Ownable(address(config)).owner(), "- before any proposal:");
        console.log("  target:", address(config));
        console.logBytes(abi.encodeCall(ProtocolConfig.setProtocolFeeRecipient, (address(router))));
        console.log("current protocolFeeRecipient:", config.protocolFeeRecipient());
    }

    /// @notice The router, owned by `safe`, with no allocations.
    function deploy(address safe) public returns (ProtocolFeeRouter router) {
        require(safe.code.length != 0, "DeployProtocolFeeRouter: the Safe must be a contract, not an EOA");
        router = new ProtocolFeeRouter(safe);
        require(router.owner() == safe, "DeployProtocolFeeRouter: owner is not the Safe");
        require(router.allocations().length == 0, "DeployProtocolFeeRouter: not in hold mode");
    }
}
