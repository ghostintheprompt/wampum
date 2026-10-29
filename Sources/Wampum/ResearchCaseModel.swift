import AppKit
import WorkbenchCore

extension WorkbenchModel {
    func importResearchContract() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose the operator-authored JSON contract. Importing replaces this session's case and clears its approved memory."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let contract = try JSONDecoder().decode(ResearchCaseContract.self, from: boundedResearchData(url))
            let state = try ResearchCaseState(contract: contract)
            let alert = NSAlert(); alert.messageText = "Use case \(contract.id)?"
            alert.informativeText = "\(contract.objective)\n\nRequired units: \(contract.requiredUnits.joined(separator: ", "))\n\nThe current session will be checkpointed. Conversation, notes, scope, attachments and document review state will be cleared to prevent cross-case carryover. Editor files remain on disk."
            alert.addButton(withTitle: "Use Case"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try replaceResearchCase(state); status = "Research case imported. Previous context checkpointed; no model request sent."
        } catch { self.error = error.localizedDescription }
    }
    /// Commit only after the prior case is recoverable and the new state is saved.
    func replaceResearchCase(_ state: ResearchCaseState) throws {
        guard !busy, !running, !showRequestReview, !showProposal, !showDocumentReview, !probing,
              !browser.connected, !browser.busy, !browser.disconnecting, !controller.enabled else {
            throw WorkbenchError.invalid("Finish active work and disconnect the browser before replacing a case.")
        }
        _ = try state.requestContext()
        try checkpointSession()
        var target = session
        target.researchCase = state; target.messages = []; target.notes = ""; target.scope = ""; target.prompt = ""
        target.images = []; target.documentJob = nil; target.documentCommand = nil
        target.browserGoal = nil; target.browserURL = nil
        if let lab = target.lab { target.lab = LabMemory(id: lab.id, title: lab.title, mode: lab.mode) }
        try saveEditorSession(target)
        session = target; includeEditor = false; command = ""; output = "No check run yet for this case."
        browser.goal = ""; browser.cancelPlan(); controller.prepared = false; controller.handoff = ""
        cancelRequestReview()
    }
    func captureCaseSource() {
        guard var state = session.researchCase else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Capture a source as untrusted research data. Originals remain unchanged."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let identity = try ResearchSourceIngestor.review(url: url)
            let capture = try ResearchSourceIngestor.capture(reviewed: identity)
            guard !state.sources.contains(where: { $0.original.canonicalPath == identity.canonicalPath }) else {
                throw WorkbenchError.invalid("Source already captured. Changed sources require an explicitly revised case.")
            }
            let alert = NSAlert(); alert.messageText = "Capture \(url.lastPathComponent)?"
            alert.informativeText = "Format: \(capture.format.rawValue)\nSHA256: \(identity.sha256)\n\(capture.warnings.joined(separator: "\n"))\nUse Inspect Case Coverage to select exact windows for a required output unit. Until you do, chat uses a labeled first-window excerpt. This does not establish complete document coverage."
            alert.addButton(withTitle: "Capture"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            state.sources.append(capture); _ = try state.requestContext()
            session.researchCase = state; persist(); status = "Source captured; no facts automatically approved."
        } catch { self.error = error.localizedDescription }
    }
    func importResearchLedger() {
        guard var state = session.researchCase else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        panel.message = "Review a case-bound evidence ledger JSON. This replaces approved memory only after explicit review."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let ledger = try JSONDecoder().decode(ResearchEvidence.Ledger.self, from: boundedResearchData(url))
            let memory = try ledger.approvedMemory(caseID: state.contract.id, contractHash: state.contract.digest())
            let alert = NSAlert(); alert.messageText = "Use these reviewed memory records?"
            alert.informativeText = memory.facts.map { "[\($0.meaning.rawValue)] \($0.content)" }.joined(separator: "\n\n") + "\n\nThese are local review records, not authenticated proof of execution. Sources and hashes were rechecked."
            alert.addButton(withTitle: "Use Reviewed Records"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            state.ledger = ledger; _ = try state.requestContext()
            session.researchCase = state; persist(); status = "Case memory updated after operator review."
        } catch { self.error = error.localizedDescription }
    }
    func inspectResearchCase() {
        guard session.researchCase != nil else { return }
        showSourceCoverage = true
    }
    func applySourcePlan(_ plan: ResearchSourcePlan, unitID: String, expectedRevision: String) throws {
        guard !busy, !running, !showRequestReview, !controller.enabled, !browser.busy,
              var state = session.researchCase else {
            throw WorkbenchError.invalid("Finish active requests or controller work before changing source selection.")
        }
        guard try state.sourceSelectionRevision() == expectedRevision else {
            throw WorkbenchError.invalid("Case sources or selection changed while editing. Reopen coverage and review again.")
        }
        state.sourcePlan = plan; state.activeSourceUnit = unitID
        _ = try state.requestContext()
        try checkpointSession()
        var target = session; target.researchCase = state
        try saveEditorSession(target); session = target
        status = "Exact source selection saved. Allocation is not proof of review or completion."
    }
    private func boundedResearchData(_ url: URL) throws -> Data {
        let pinned = try IntegrityCheck.hashFile(url.path, limit: 1_048_576)
        let data = try Data(contentsOf: url)
        let current = try IntegrityCheck.hashFile(url.path, limit: 1_048_576)
        guard current.0 == pinned.0, current.1 == pinned.1, Int64(data.count) == pinned.1,
              ResearchEvidence.hash(String(decoding: data, as: UTF8.self)) == pinned.0, data.count <= 1_048_576 else { throw WorkbenchError.invalid("Research record exceeds 1 MB.") }
        return data
    }
}
