import SwiftUI
import AppKit
import WorkbenchCore

struct ResearchQualityView: View {
    @ObservedObject var model: WorkbenchModel
    @State private var rubric = ""
    @State private var assessment = ""
    @State private var trial = ""
    @State private var reviewer = ""
    @State private var findings = ""
    @State private var gapPath = ""
    @State private var evidenceID = ""
    @State private var gapFindings = ""
    @State private var gapReviews: [ResearchRelease.GapReview] = []
    private var currentApproval: Bool {
        guard let evaluation = model.qualityEvaluation, let approval = model.session.researchCase?.releaseApproval,
              let hash = try? evaluation.digest() else { return false }
        return hash == approval.evaluationHash && model.qualityWorkflowHash == approval.workflowHash
    }
    private var gaps: [ResearchSourceCapture] {
        model.session.researchCase?.sources.filter { !$0.fullDocumentTextCoverage || $0.extractedText.isEmpty || !$0.warnings.isEmpty } ?? []
    }
    private func input(_ title: String, path: Binding<String>) -> some View {
        HStack {
            TextField(title, text: path)
            Button("Choose " + title + "…") {
                let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
            }
        }.disabled(model.evaluatingQuality)
    }
    private func clearEvaluation() { model.qualityEvaluation = nil; model.qualityWorkflowHash = nil; model.qualityDocumentPreview = ""; gapReviews = [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Whole-document quality review").font(.title2)
            Text("Recompute the supplied review records against the exact assembled document and all current files. This does not authenticate receipts, execute code, certify semantic truth or establish frontier-model equivalence.").font(.caption)
            input("Rubric", path: $rubric); input("Assessment", path: $assessment); input("Trial", path: $trial)
            HStack {
                Button("Recompute Quality Review") {
                    gapReviews = []
                    Task {
                        do {
                            let fresh = try await model.evaluateQualityRelease(.init(rubric: rubric, assessment: assessment, trial: trial))
                            if let approval = model.session.researchCase?.releaseApproval, try fresh.digest() == approval.evaluationHash {
                                gapReviews = approval.gapReviews
                                if reviewer.isEmpty { reviewer = approval.reviewer }; if findings.isEmpty { findings = approval.findings }
                            }
                        } catch { model.qualityIssue = error.localizedDescription }
                    }
                }.disabled(model.evaluatingQuality || rubric.isEmpty || assessment.isEmpty || trial.isEmpty)
                if model.evaluatingQuality { ProgressView().controlSize(.small); Text("Checking exact files and accepted sections…").font(.caption) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let evaluation = model.qualityEvaluation {
                        let report = evaluation.report
                        Text(evaluation.fixtureOnly ? "FIXTURE ONLY — no real model acceptance" : "Wampum trial: " + report.trialID).font(.headline)
                        Text(currentApproval ? "Operator signoff is recorded for this evaluated snapshot. Export rechecks all files." : (report.reviewRecordMeetsPolicy ? "Recomputed review records meet policy; operator signoff remains required." : "Review records do not meet policy."))
                        Text("Unallocated extracted source windows: \(evaluation.coverage.reduce(0) { $0 + $1.omittedWindowIndices.count })").font(.caption)
                        Text("Score: \(report.score.map { String(format: "%.2f", $0) } ?? "ungraded") · assessed weight: \(Int(report.assessedWeight))%")
                        Text("Artifact SHA256: " + report.artifactHash).font(.caption).textSelection(.enabled)
                        Text("Unrated: " + report.unratedCriteria.joined(separator: ", ")).font(.caption)
                        Text("Failed gates: " + report.failedGates.joined(separator: ", ")).font(.caption)
                        Text("Unevaluated gates: " + report.unverifiedGates.joined(separator: ", ")).font(.caption)
                        Text("Unmet units: " + report.unmetUnits.joined(separator: ", ")).font(.caption)
                        Text("Dimension / critical failures: " + (report.belowFloor + report.criticalFailures).joined(separator: ", ")).font(.caption)
                        DisclosureGroup("Inspect exact assembled Markdown") {
                            ScrollView { Text(model.qualityDocumentPreview).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 220)
                        }
                        DisclosureGroup("Inspect pinned evidence references") {
                            ForEach(evaluation.assessment.evidenceIndex, id: \.id) { evidence in
                                VStack(alignment: .leading) {
                                    Text(evidence.id + " / " + evidence.kind).font(.caption)
                                    Text(evidence.path + "\nSHA256: " + evidence.sha256).font(.caption2).textSelection(.enabled)
                                    Button("Reveal " + evidence.id + " in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: evidence.path)]) }
                                }.padding(.vertical, 4)
                            }
                        }
                        if !gaps.isEmpty {
                            Divider(); Text("Original-source review for extraction uncertainty").font(.headline)
                            Text("Every PDF, image, empty extraction or warning needs a separate review of the original. Cite source-review evidence already indexed in the assessment; allocating all extracted text does not resolve missing visual content.").font(.caption)
                            Picker("Source with uncertainty", selection: $gapPath) {
                                Text("Choose source").tag("")
                                ForEach(gaps, id: \.original.canonicalPath) { Text($0.original.canonicalPath).tag($0.original.canonicalPath) }
                            }
                            Picker("Pinned source-review evidence", selection: $evidenceID) {
                                Text("Choose evidence").tag("")
                                ForEach(evaluation.assessment.evidenceIndex.filter { $0.kind == "source-review" }, id: \.id) { Text($0.id).tag($0.id) }
                            }
                            TextField("What was inspected in the original, including remaining limitations", text: $gapFindings)
                            Button("Record Original-Source Review") {
                                guard let source = gaps.first(where: { $0.original.canonicalPath == gapPath }) else { return }
                                gapReviews.removeAll { $0.sourcePath == gapPath }
                                gapReviews.append(.init(source: source, evidenceID: evidenceID, findings: gapFindings))
                                gapFindings = ""
                            }.disabled(gapPath.isEmpty || evidenceID.isEmpty || gapFindings.trimmingCharacters(in: .whitespacesAndNewlines).count < 32)
                            Text("Recorded original-source reviews: \(gapReviews.count) / \(gaps.count)").font(.caption)
                        }
                        Divider()
                        TextField("Whole-document reviewer attribution", text: $reviewer)
                        Text("Whole-document findings: completeness, code and execution evidence, source credibility, limitations and documentation quality").font(.caption)
                        TextEditor(text: $findings).font(.system(size: 12, design: .monospaced)).frame(height: 95)
                        Button("Approve Exact Whole-Document Review") {
                            do {
                                let digest = try evaluation.digest(); let workflow = model.qualityWorkflowHash ?? ""
                                Task { do { try await model.approveQualityRelease(expectedEvaluationHash: digest, expectedWorkflowHash: workflow, reviewer: reviewer, findings: findings, gapReviews: gapReviews) } catch { model.qualityIssue = error.localizedDescription } }
                            } catch { model.qualityIssue = error.localizedDescription }
                        }.disabled(model.evaluatingQuality || !report.reviewRecordMeetsPolicy || evaluation.coverage.contains(where: { !$0.omittedWindowIndices.isEmpty }) || gapReviews.count != gaps.count || reviewer.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 || findings.trimmingCharacters(in: .whitespacesAndNewlines).count < 32)
                    } else { Text("All required sections must have current operator acceptance before whole-document scoring.").foregroundStyle(.secondary) }
                    if let issue = model.qualityIssue { Text(issue).foregroundStyle(.red).textSelection(.enabled) }
                    Text(model.status).font(.caption).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.disabled(model.evaluatingQuality)
            HStack {
                Button("Close") { model.showQualityReview = false }.disabled(model.evaluatingQuality)
                Spacer()
                Button("Save Operator-Reviewed Artifact…", action: model.saveQualityRelease)
                    .disabled(model.evaluatingQuality || !currentApproval)
            }
        }.padding(22).frame(width: 950, height: 800)
            .onAppear {
                if let paths = model.session.researchCase?.releaseApproval?.evaluation.paths { rubric = paths.rubric; assessment = paths.assessment; trial = paths.trial }
            }
            .onChange(of: rubric) { _, _ in clearEvaluation() }
            .onChange(of: assessment) { _, _ in clearEvaluation() }
            .onChange(of: trial) { _, _ in clearEvaluation() }
    }
}
