import Foundation

public struct ResearchSectionRequest: Codable, Sendable {
    public let caseID: String
    public let contractHash: String
    public let unitID: String
    public let sources: [SectionSource]
    public init(state: ResearchCaseState, additionalSources: [SectionSource] = []) throws {
        guard let unit = state.activeSourceUnit,
              let instructions = state.sectionInstructions?[unit],
              !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkbenchError.invalid("Select an output unit and write its substantive section requirements first.")
        }
        _ = try state.requestContext()
        let workflow = try state.currentSectionWorkflow(additionalSources: additionalSources)
        caseID = state.contract.id; contractHash = try state.contract.digest(); unitID = unit; sources = try workflow.sources(for: unit)
    }
}

extension ResearchCaseState {
    /// Unit allocations/requirements stale their own section. Approved memory and operator context bind every section.
    public func currentSectionWorkflow(additionalSources: [SectionSource] = []) throws -> ResearchSectionWorkflow {
        guard let plan = sourcePlan else { throw WorkbenchError.invalid("Save an exact source selection before generating sections.") }
        _ = try requestContext()
        guard (sectionInstructions ?? [:]).allSatisfy({ contract.requiredUnits.contains($0.key) && $0.value.utf8.count <= 16_384 }) else {
            throw WorkbenchError.invalid("Section requirements contain an unknown unit or exceed 16 KB.")
        }
        var bindings = additionalSources
        for unit in contract.requiredUnits {
            bindings.append(.init(id: "allocation:" + unit, contentHash: ResearchSectionWorkflow.hash(try plan.requestSources(contract: contract, captures: sources, unitID: unit)), sectionID: unit))
            bindings.append(.init(id: "requirements:" + unit, contentHash: ResearchSectionWorkflow.hash(Data((sectionInstructions?[unit] ?? "").utf8)), sectionID: unit))
        }
        let memory = try ledger.approvedMemory(caseID: contract.id, contractHash: contract.digest())
        bindings.append(.init(id: "approved-memory", contentHash: ResearchSectionWorkflow.hash(try memory.promptJSON(validating: ledger))))
        let hash = try contract.digest()
        if var workflow = sectionWorkflow {
            guard workflow.caseID == contract.id, workflow.requiredSectionIDs == contract.requiredUnits else {
                throw WorkbenchError.invalid("Section history belongs to a different case or requirement list; preserve it in its original case.")
            }
            try workflow.revise(contractHash: hash, sources: bindings)
            return workflow
        }
        return try ResearchSectionWorkflow(caseID: contract.id, contractHash: hash, requiredSectionIDs: contract.requiredUnits, sources: bindings)
    }
}
