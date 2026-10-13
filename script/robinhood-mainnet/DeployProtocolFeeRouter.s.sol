// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ScriptBase} from "../ScriptBase.sol";
import {DeploySalts} from "../DeploySalts.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {ProtocolFeeRouter} from "../../src/ProtocolFeeRouter.sol";

/// @title  DeployProtocolFeeRouter
/// @notice Mints the protocol-leg fee router (SHE-239) through CREATE3, owned by the Safe and in hold
///         mode, records it as `PROTOCOL_FEE_ROUTER`, and prints the `setProtocolFeeRecipient` call.
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
        address deployer = _readAddress("DEPLOYER");
        ProtocolConfig config = ProtocolConfig(_readAddress("PROTOCOL_CONFIG"));

        vm.startBroadcast();
        // `Create3Factory.deploy` is onlyOwner; fail here rather than with the factory's bare revert.
        require(msg.sender == deployer, "broadcaster != DEPLOYER in the address book");
        router = deploy(safe);
        vm.stopBroadcast();

        _patchAddress("PROTOCOL_FEE_ROUTER", address(router));

        console.log("ProtocolFeeRouter:", address(router));
        console.log("owner (Safe):", safe);
        console.log("NEXT, from the ProtocolConfig owner", Ownable(address(config)).owner(), "- before any proposal:");
        console.log("  target:", address(config));
        console.logBytes(abi.encodeCall(ProtocolConfig.setProtocolFeeRecipient, (address(router))));
        console.log("current protocolFeeRecipient:", config.protocolFeeRecipient());
    }

    /// @notice The router at its salt, owned by `safe`, with no allocations.
    /// @dev The caller must own the Create3Factory (`_c3Factory` bootstraps it at `msg.sender`).
    function deploy(address safe) public returns (ProtocolFeeRouter router) {
        require(safe.code.length != 0, "DeployProtocolFeeRouter: the Safe must be a contract, not an EOA");
        bytes memory initcode = abi.encodePacked(type(ProtocolFeeRouter).creationCode, abi.encode(safe));
        router = ProtocolFeeRouter(_c3(_c3Factory(msg.sender), DeploySalts.PROTOCOL_FEE_ROUTER, initcode));
        require(router.owner() == safe, "DeployProtocolFeeRouter: owner is not the Safe");
        require(router.allocations().length == 0, "DeployProtocolFeeRouter: not in hold mode");
    }
}
