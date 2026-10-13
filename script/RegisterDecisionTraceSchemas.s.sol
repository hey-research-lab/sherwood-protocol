// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ScriptBase} from "./ScriptBase.sol";
import {ISchemaRegistry, SchemaRecord} from "eas-contracts/ISchemaRegistry.sol";
import {ISchemaResolver} from "eas-contracts/resolver/ISchemaResolver.sol";

/// @title  RegisterDecisionTraceSchemas
/// @notice Registers the six decision-trace v1 schemas on the SchemaRegistry
///         that DeployEAS put on this chain (`EAS_SCHEMA_REGISTRY` in
///         chains/{chainId}.json). See
///         docs/superpowers/specs/2026-10-11-decision-trace-v1-design.md
///         (sherwoodagent/sherwood).
///
///         The definitions and UIDs are copied verbatim from
///         cli/src/lib/decision-trace-schemas.ts in sherwoodagent/sherwood
///         (#655). They are FROZEN: no space after commas, resolver
///         address(0), revocable false. UIDs carry no chainId, so the same
///         definitions reproduce the same UIDs anywhere.
///
///         `register` is permissionless, so the signer only pays gas; it is
///         not part of any UID.
///
///   Usage:
///     forge script script/RegisterDecisionTraceSchemas.s.sol:RegisterDecisionTraceSchemas \
///       --rpc-url robinhood --account <keystore> --broadcast
contract RegisterDecisionTraceSchemas is ScriptBase {
    struct SchemaSpec {
        string name;
        string definition;
        bytes32 expectedUid;
    }

    function _schemas() internal pure returns (SchemaSpec[] memory s) {
        s = new SchemaSpec[](6);
        s[0] = SchemaSpec(
            "DECISION_THESIS",
            "address asset,uint8 direction,uint64 horizonSeconds,uint16 confidenceBps,string thesisURI,bytes32 thesisHash,bool encrypted,bytes32 modelConfigHash,bytes32 dataSnapshotHash,uint8 license",
            0x95b0720e62cdf21bb240d42e372ff60ea7546df04b6717823b74527bfa9dc432
        );
        s[1] = SchemaSpec(
            "DECISION_PROPOSAL_LINK",
            "uint256 proposalId,bytes32 thesisUID,uint8 provenanceClass,uint8 license",
            0x90a0674cfce5c8eeb385bb0c087e37813120b4e8c0ae4077e33cacb6c65a693d
        );
        s[2] = SchemaSpec(
            "DECISION_EXECUTION_LINK",
            "uint256 proposalId,bytes32[] txHashes,int32 realizedSlippageBps,uint8 license",
            0x091c3f7679ec8ca52d021c061f4c80d06afefe0d340bd5d33213bde197b6219a
        );
        s[3] = SchemaSpec(
            "DECISION_KILL",
            "uint256 proposalId,uint8 reasonCode,string note,uint8 license",
            0x14a431fe1a7cfb82df2b06b82aa79847d9463b93dd82f827c30a039e0d70e9e2
        );
        s[4] = SchemaSpec(
            "DECISION_OUTCOME",
            "uint256 proposalId,int256 pnlBps,int256 maxDrawdownBps,uint64 measuredAt,string note,uint8 license",
            0xf624adf161afba5e011a182d075062e51c526c549b6702dd968d9152fc01ddf1
        );
        s[5] = SchemaSpec(
            "DECISION_AGENT_VERSION",
            "uint256 agentId,bytes32 modelConfigHash,string label,uint8 license",
            0x0e2d47265aa9ba55804ba8781e65c181e24879cffe3342ca1b2cafda07b67f95
        );
    }

    function run() external {
        SchemaSpec[] memory specs = _schemas();
        ISchemaRegistry registry = ISchemaRegistry(_readAddress("EAS_SCHEMA_REGISTRY"));
        require(address(registry).code.length > 0, "EAS_SCHEMA_REGISTRY has no code");

        // Same pre-flight as DeployEAS: a typo caught here costs nothing, caught
        // after registration it is permanent.
        for (uint256 i = 0; i < specs.length; ++i) {
            bytes32 computed = keccak256(abi.encodePacked(specs[i].definition, address(0), false));
            require(computed == specs[i].expectedUid, string.concat("UID mismatch (pre-flight): ", specs[i].name));
        }

        console.log("SchemaRegistry:", address(registry));

        vm.startBroadcast();
        for (uint256 i = 0; i < specs.length; ++i) {
            // Skip rather than try/catch: a resumed run sends no reverting tx.
            if (registry.getSchema(specs[i].expectedUid).uid != bytes32(0)) {
                console.log("already registered %s - verifying", specs[i].name);
                continue;
            }
            bytes32 uid = registry.register(specs[i].definition, ISchemaResolver(address(0)), false);
            require(uid == specs[i].expectedUid, string.concat("UID mismatch (registered): ", specs[i].name));
            console.log("registered %s -> %s", specs[i].name, vm.toString(uid));
        }
        vm.stopBroadcast();

        for (uint256 i = 0; i < specs.length; ++i) {
            _verify(registry, specs[i]);
        }
        console.log("All six verified. Block:", block.number);
    }

    function _verify(ISchemaRegistry registry, SchemaSpec memory spec) internal view {
        SchemaRecord memory rec = registry.getSchema(spec.expectedUid);
        require(rec.uid == spec.expectedUid, string.concat("schema absent at pinned UID: ", spec.name));
        require(
            keccak256(bytes(rec.schema)) == keccak256(bytes(spec.definition)),
            string.concat("definition drift: ", spec.name)
        );
        require(!rec.revocable, string.concat("revocable drift: ", spec.name));
        require(address(rec.resolver) == address(0), string.concat("unexpected resolver: ", spec.name));
    }
}
