import AppKit
import WorkbenchCore

extension WorkbenchModel {
    var researchReviewOpen: Bool { showQualityReview || showResearchSections || showSourceCoverage }
    func openQualityReview() {
        guard session.researchCase != nil else { return }
        qualityEvaluation = nil; qualityWorkflowHash = nil; qualityDocumentPreview = ""; qualityIssue = nil; showQualityReview = true
    }
    func sectionWorkflowHash() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return ResearchSectionWorkflow.hash(try encoder.encode(currentResearchSections()))
    }
    private func qualityWorkAllowed() throws {
        guard !evaluatingQuality, !busy, !running, !showRequestReview, !controller.enabled, !persistenceBlocked else {
            throw WorkbenchError.invalid("Finish active inference, checks, request reviews and controller work before quality review.")
        }
    }
    /// The worker sees a value snapshot. Freshness is rechecked on the main actor after its file work.
    private func computeQuality(_ paths: ResearchRelease.Paths, state: ResearchCaseState, workflow: ResearchSectionWorkflow, body: Data) async throws -> ResearchRelease.Evaluation {
        try await Task.detached(priority: .userInitiated) {
            let evaluation = try ResearchRelease.evaluate(paths: paths, state: state, body: body)
            try ResearchRelease.validateExecutionRecords(evaluation, body: body)
            let journals = try ResearchRelease.validateSectionJournals(evaluation, workflow: workflow, state: state)
            try ResearchRelease.validatePins(evaluation.pins + journals)
            return evaluation.includingJournals(journals)
        }.value
    }
    @discardableResult func evaluateQualityRelease(_ paths: ResearchRelease.Paths) async throws -> ResearchRelease.Evaluation {
        try qualityWorkAllowed()
        guard let state = session.researchCase else { throw WorkbenchError.invalid("No research case.") }
        let workflow = try currentResearchSections(); let workflowHash = try sectionWorkflowHash()
        let body = try researchSectionsDraft().bytes
        let directory = store.directory.appendingPathComponent("quality-reviews/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try IntegrityCheck.writeNew(encoder.encode(paths), to: directory.appendingPathComponent("inputs.json").path)
        evaluatingQuality = true; qualityIssue = nil
        defer { evaluatingQuality = false }
        do {
            let evaluation = try await computeQuality(paths, state: state, workflow: workflow, body: body)
            try IntegrityCheck.writeNew(encoder.encode(evaluation), to: directory.appendingPathComponent("evaluation.json").path)
            let (rubricData, _) = try ResearchRelease.read(paths.rubric)
            let rubric = try JSONDecoder().decode(ResearchQuality.Rubric.self, from: rubricData)
            let workspace = try Workspace(root: URL(fileURLWithPath: paths.rubric).deletingLastPathComponent())
            let inputs = try [paths.rubric, paths.assessment, paths.trial, workspace.resolve(rubric.policyFile).path,
                              workspace.resolve(rubric.taskFile).path, workspace.resolve(rubric.sourceManifestFile).path]
            // Preserve all exact review/policy/task/source-inventory inputs, not just their hashes.
            for (index, path) in inputs.enumerated() {
                let (data, pin) = try ResearchRelease.read(path)
                guard evaluation.pins.contains(pin) else { throw WorkbenchError.invalid("Quality input changed before archival.") }
                try IntegrityCheck.writeNew(data, to: directory.appendingPathComponent("input-\(index).json").path)
            }
            guard try sectionWorkflowHash() == workflowHash, try researchSectionsDraft().documentHash == evaluation.report.artifactHash else {
                throw WorkbenchError.invalid("Case or accepted sections changed during quality review. The evaluated snapshot was retained; review again.")
            }
            qualityEvaluation = evaluation; qualityWorkflowHash = workflowHash
            qualityDocumentPreview = String(decoding: body, as: UTF8.self)
            status = evaluation.report.reviewRecordMeetsPolicy ? "Recomputed quality records meet policy. Explicit whole-document review is still required." : "Quality records do not meet policy. Failed and ungraded conditions remain unresolved."
            return evaluation
        } catch {
            qualityEvaluation = nil; qualityWorkflowHash = nil; qualityIssue = error.localizedDescription
            let record = try JSONSerialization.data(withJSONObject: ["outcome": "refused", "detail": error.localizedDescription], options: [.sortedKeys])
            try? IntegrityCheck.writeNew(record, to: directory.appendingPathComponent("refusal.json").path)
            throw error
        }
    }
    func approveQualityRelease(expectedEvaluationHash: String, expectedWorkflowHash: String, reviewer: String, findings: String, gapReviews: [ResearchRelease.GapReview]) async throws {
        guard let original = qualityEvaluation else { throw WorkbenchError.invalid("Recompute a complete quality review first.") }
        let fresh = try await evaluateQualityRelease(original.paths)
        guard try fresh.digest() == expectedEvaluationHash, qualityWorkflowHash == expectedWorkflowHash,
              let state = session.researchCase else { throw WorkbenchError.invalid("Inputs changed after preview; inspect the new evaluation before approving.") }
        try ResearchRelease.validateCoverage(state: state, evaluation: fresh, reviews: gapReviews)
        let approval = try ResearchRelease.Approval(evaluation: fresh, workflowHash: expectedWorkflowHash, reviewer: reviewer, findings: findings, gapReviews: gapReviews)
        try checkpointSession()
        var target = session; target.researchCase?.releaseApproval = approval
        try saveEditorSession(target); session = target
        status = fresh.fixtureOnly ? "Fixture-only whole-document review recorded. This is not a model acceptance result." : "Explicit whole-document review recorded. Export will recheck all inputs."
    }
    /// Recompute rather than trusting the stored evaluation or an imported passed report.
    @discardableResult func writeQualityRelease(to url: URL, expectedApprovalHash: String) async throws -> URL {
        try qualityWorkAllowed()
        guard let state = session.researchCase, let approval = state.releaseApproval else { throw WorkbenchError.invalid("Explicit whole-document approval is missing.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard ResearchSectionWorkflow.hash(try encoder.encode(approval)) == expectedApprovalHash else { throw WorkbenchError.invalid("Approval changed after save preview.") }
        let workflow = try currentResearchSections(); let workflowHash = try sectionWorkflowHash()
        let body = try researchSectionsDraft().bytes
        let directory = store.directory.appendingPathComponent("quality-exports/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try IntegrityCheck.writeNew(encoder.encode(approval), to: directory.appendingPathComponent("approval.json").path)
        evaluatingQuality = true; defer { evaluatingQuality = false }
        do {
            let fresh = try await computeQuality(approval.evaluation.paths, state: state, workflow: workflow, body: body)
            guard try fresh.digest() == approval.evaluationHash, workflowHash == approval.workflowHash,
                  try sectionWorkflowHash() == workflowHash,
                  let current = session.researchCase?.releaseApproval,
                  ResearchSectionWorkflow.hash(try encoder.encode(current)) == expectedApprovalHash else {
                throw WorkbenchError.invalid("Release inputs, accepted sections or approval changed. Fresh operator review is required.")
            }
            try ResearchRelease.validateCoverage(state: state, evaluation: fresh, reviews: approval.gapReviews)
            _ = try ResearchRelease.Approval(evaluation: fresh, workflowHash: workflowHash, reviewer: approval.reviewer, findings: approval.findings, gapReviews: approval.gapReviews)
            let journalPins = try ResearchRelease.validateSectionJournals(fresh, workflow: workflow, state: state)
            try ResearchRelease.validatePins(fresh.pins + journalPins)
            try IntegrityCheck.writeNew(body, to: url.path)
            let (readback, pin) = try ResearchRelease.read(url.path, limit: Int64(body.count))
            guard readback == body, pin.sha256 == fresh.report.artifactHash else { throw WorkbenchError.invalid("Released document readback differs from the reviewed bytes.") }
            try ResearchRelease.validatePins(fresh.pins + journalPins)
            let receipt = directory.appendingPathComponent("receipt.json")
            let data = try JSONSerialization.data(withJSONObject: ["outcome": "operator-reviewed-export", "fixtureOnly": fresh.fixtureOnly,
                "caseID": state.contract.id, "artifactHash": pin.sha256, "bytes": pin.bytes, "outputPath": pin.path,
                "evaluationHash": approval.evaluationHash, "workflowHash": workflowHash, "reviewer": approval.reviewer,
                "reviewRecordMeetsPolicy": fresh.report.reviewRecordMeetsPolicy,
                "limitation": "Supplied local evidence and explicit operator review; not authenticated execution proof, independent semantic certification or frontier-model equivalence."], options: [.sortedKeys])
            try IntegrityCheck.writeNew(encoder.encode(fresh), to: directory.appendingPathComponent("evaluation.json").path)
            try IntegrityCheck.writeNew(data, to: receipt.path)
            status = fresh.fixtureOnly ? "Fixture-only artifact exported and byte-checked. Receipt: " + receipt.path : "Operator-reviewed artifact exported and byte-checked. Receipt: " + receipt.path
            return receipt
        } catch {
            let data = try JSONSerialization.data(withJSONObject: ["outcome": "failed", "outputPath": url.path, "detail": error.localizedDescription], options: [.sortedKeys])
            try? IntegrityCheck.writeNew(data, to: directory.appendingPathComponent("failure.json").path)
            throw error
        }
    }
    func saveQualityRelease() {
        do {
            guard let approval = session.researchCase?.releaseApproval else { throw WorkbenchError.invalid("Approve a current whole-document review first.") }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let hash = ResearchSectionWorkflow.hash(try encoder.encode(approval))
            let panel = NSSavePanel(); panel.nameFieldStringValue = approval.evaluation.fixtureOnly ? "Research-fixture-review.md" : "Research-operator-reviewed.md"
            panel.message = approval.evaluation.fixtureOnly ? "Fixture-only export; it does not establish real model/document acceptance." : "Export the exact operator-reviewed document. All files and accepted sections will be rechecked."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            Task { do { try await writeQualityRelease(to: url, expectedApprovalHash: hash) } catch { self.qualityIssue = error.localizedDescription } }
        } catch { qualityIssue = error.localizedDescription }
    }
}
