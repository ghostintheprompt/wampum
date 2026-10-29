import SwiftUI
import AppKit
import WorkbenchCore

struct ResearchSectionsView: View {
    @ObservedObject var model: WorkbenchModel
    @State private var unit = ""
    @State private var instructions = ""
    @State private var selectedAttempt = ""
    @State private var reviewer = ""
    @State private var explanation = ""
    @State private var evidenceURL: URL?
    @State private var issue: String?
    private var attempts: [SectionGenerationAttempt] {
        model.session.researchCase?.sectionWorkflow?.attempts.filter { $0.sectionID == unit } ?? []
    }
    private var attempt: SectionGenerationAttempt? { attempts.first { $0.id == selectedAttempt } ?? attempts.last }
    private func loadUnit() {
        instructions = model.session.researchCase?.sectionDrafts?[unit] ?? model.session.researchCase?.sectionInstructions?[unit] ?? ""
        selectedAttempt = attempts.last?.id ?? ""; evidenceURL = nil; explanation = ""; issue = nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sections and substantive review").font(.title2)
            Text("Generation uses the exact allocation for this unit. Every returned attempt is preserved. A normal stop is not acceptance. Review the content and actual verification evidence before accepting; no code runs here.").font(.caption)
            Picker("Required section", selection: $unit) {
                ForEach(model.session.researchCase?.contract.requiredUnits ?? [], id: \.self) { Text($0).tag($0) }
            }.onChange(of: unit) { _, _ in loadUnit() }
            Text("Section requirements / identified repairs").font(.headline)
            TextEditor(text: $instructions).font(.system(size: 12, design: .monospaced)).frame(height: 90)
                .onChange(of: instructions) { _, text in
                    do { try model.saveSectionRequirementsDraft(unitID: unit, text: text) }
                    catch { issue = error.localizedDescription }
                }.disabled(model.busy)
            HStack {
                Button("Prepare Reviewed Generation…") {
                    do { try model.prepareResearchSection(unitID: unit, instructions: instructions) }
                    catch { issue = error.localizedDescription }
                }.disabled(model.busy || model.showRequestReview)
                Text("The exact request opens for approval; nothing is sent by this button.").font(.caption)
            }
            if let state = try? model.currentResearchSections().state(for: unit) {
                Text("Current section state: " + state.rawValue).font(.caption)
            } else { Text("Current source binding unavailable. Save exact coverage and resolve stale evidence before review.").font(.caption).foregroundStyle(.orange) }
            if let attempt {
                Picker("Preserved attempt", selection: $selectedAttempt) {
                    ForEach(attempts, id: \.id) { item in Text(item.id + " / " + (item.stopReason ?? "unknown stop")).tag(item.id) }
                }.onChange(of: selectedAttempt) { _, _ in evidenceURL = nil; explanation = "" }
                Text("Model: \(attempt.provenance.model) · input: \(attempt.inputTokens.map(String.init) ?? "unknown") · output: \(attempt.outputTokens.map(String.init) ?? "unknown")").font(.caption)
                Text("Request journal: " + attempt.provenance.requestID).font(.caption2).textSelection(.enabled)
                ScrollView { Text(attempt.body).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(minHeight: 120)
                HStack {
                    TextField("Reviewer attribution", text: $reviewer)
                    Button("Choose review evidence…") {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK { evidenceURL = panel.url }
                    }
                    Text(evidenceURL?.lastPathComponent ?? "No evidence selected").font(.caption)
                }
                TextField("Substantive completeness / correctness findings and what this evidence establishes", text: $explanation)
                HStack {
                    Button("Reject Attempt") { review(attempt, decision: .reject) }
                    Button("Accept After Review") { review(attempt, decision: .approve) }
                        .disabled(!attempt.structurallyComplete)
                    Text("Evidence files are hash-pinned local records, not authenticated proof.").font(.caption)
                }.disabled(model.busy || evidenceURL == nil)
            } else { Text("No generated attempts for this section.").foregroundStyle(.secondary); Spacer() }
            if let issue { Text(issue).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("Close") { model.showResearchSections = false }
                Spacer()
                Button("Assemble Accepted Sections as Draft…", action: model.saveResearchSectionsDraft)
                    .disabled(model.busy || model.session.researchCase?.sectionWorkflow?.attempts.isEmpty != false)
            }
            Text("All required sections must be currently accepted for assembly. Draft export does not satisfy the final quality-release gate.").font(.caption2)
        }.padding(22).frame(width: 960, height: 800)
            .onAppear { unit = model.session.researchCase?.activeSourceUnit ?? model.session.researchCase?.contract.requiredUnits.first ?? ""; loadUnit() }
    }
    private func review(_ attempt: SectionGenerationAttempt, decision: SectionReviewDecision) {
        do {
            guard let evidenceURL else { return }
            try model.reviewResearchSection(attemptID: attempt.id, expectedBinding: attempt.bindingHash,
                reviewer: reviewer, explanation: explanation, evidenceURL: evidenceURL, decision: decision)
            issue = nil; explanation = ""; self.evidenceURL = nil
        } catch { issue = error.localizedDescription }
    }
}
