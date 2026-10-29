import SwiftUI
import WorkbenchCore

struct ResearchCoverageView: View {
    @ObservedObject var model: WorkbenchModel
    @State private var state: ResearchCaseState
    @State private var revision: String
    @State private var available: [String: [ResearchSourceWindow]]
    @State private var plan: ResearchSourcePlan?
    @State private var unit: String
    @State private var sourcePath: String
    @State private var failure: String?

    init(model: WorkbenchModel, state: ResearchCaseState) {
        self.model = model; _state = State(initialValue: state)
        _revision = State(initialValue: (try? state.sourceSelectionRevision()) ?? "")
        var windows: [String: [ResearchSourceWindow]] = [:]
        var issue: String?
        do {
            for source in state.sources {
                windows[source.original.canonicalPath] = try source.windows(maxUTF8Bytes: ResearchSourcePlan.windowBytes)
            }
            let initialPlan = try state.sourcePlan ?? ResearchSourcePlan(contract: state.contract)
            _plan = State(initialValue: initialPlan)
            do { try initialPlan.validate(contract: state.contract, captures: state.sources) }
            catch { issue = error.localizedDescription }
        } catch { _plan = State(initialValue: nil); issue = error.localizedDescription }
        _available = State(initialValue: windows); _failure = State(initialValue: issue)
        _unit = State(initialValue: state.activeSourceUnit ?? state.contract.requiredUnits.first ?? "")
        _sourcePath = State(initialValue: state.sources.first?.original.canonicalPath ?? "")
    }
    private var coverage: [ResearchSourceCoverage] {
        (try? plan?.coverage(contract: state.contract, captures: state.sources, unitID: unit)) ?? []
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Source selection and coverage").font(.title2)
            Text("Select exact extracted-text windows for each required output unit. Save the active unit before requesting its answer. Selected means allocated for inclusion, not read, accepted or verified.").font(.caption)
            Picker("Required output unit", selection: $unit) {
                ForEach(state.contract.requiredUnits, id: \.self) { Text($0).tag($0) }
            }
            Picker("Captured source", selection: $sourcePath) {
                ForEach(state.sources, id: \.original.canonicalPath) { source in
                    Text(source.original.canonicalPath).tag(source.original.canonicalPath)
                }
            }
            if let capture = state.sources.first(where: { $0.original.canonicalPath == sourcePath }) {
                Text("Original SHA256: " + capture.original.sha256).font(.caption).textSelection(.enabled)
                if let report = coverage.first(where: { $0.sourcePath == sourcePath }) {
                    Text("This unit: \(report.selectedWindowIndices.count) selected / \(report.omittedWindowIndices.count) omitted windows; \(report.selectedUTF8Bytes) of \(report.totalExtractedUTF8Bytes) extracted UTF-8 bytes.").font(.caption)
                    Text(report.completeTextExtraction ? "Plain text extraction; allocation still requires substantive review." : "Visual/extraction coverage is not certified. Review the original document.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(capture.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(available[sourcePath] ?? [], id: \.index) { window in
                            VStack(alignment: .leading, spacing: 4) {
                                Toggle("Window \(window.index + 1) — UTF-8 bytes [\(window.startUTF8), \(window.endUTF8))", isOn: Binding(
                                    get: { plan?.windows.contains { $0.unitID == unit && $0.sourcePath == sourcePath && $0.windowIndex == window.index } ?? false },
                                    set: { value in plan?.setSelected(value, unitID: unit, capture: capture, window: window) }))
                                DisclosureGroup("Inspect exact source text") {
                                    Text(window.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    Text("SHA256: " + window.sha256).font(.caption2).textSelection(.enabled)
                                }
                            }.padding(8).background(Color.secondary.opacity(0.08))
                        }
                    }
                }
            } else { Text("No captured sources. Capture a source from the File menu first.") }
            if let failure { Text(failure).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("Cancel") { model.showSourceCoverage = false }
                Spacer()
                Text("Other units retain their own selections.").font(.caption)
                Button("Save Selection and Active Unit") {
                    do {
                        guard let plan else { return }
                        try model.applySourcePlan(plan, unitID: unit, expectedRevision: revision)
                        model.showSourceCoverage = false
                    } catch { failure = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(plan == nil || revision.isEmpty || model.busy || model.showRequestReview)
            }
        }.padding(22).frame(width: 900, height: 680)
    }
}
