import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WorkbenchCore

private let acid = Color(red: 0.76, green: 0.83, blue: 0.57)
private let panel = Color(red: 0.105, green: 0.105, blue: 0.11)

/// Operator surface for the scope-gated external pen-test tools. Every action here routes
/// through the active case's authorized scope (the rules of engagement), explicit review,
/// and a receipt. With no case scope defined, outward actions fail closed.
struct ToolsPanel: View {
    @ObservedObject var model: WorkbenchModel
    @State private var dockerSub = "ps"
    @State private var dockerArgs = "-a"
    @State private var dockerTargets = ""
    @State private var burpURLs = ""
    @State private var burpTaskID = ""
    @State private var acMethod = "GET"
    @State private var acURL = ""
    @State private var apMethod = "GET"
    @State private var apURL = ""
    @State private var apHeaders = "Authorization: Bearer TEST-TOKEN"
    @State private var apChange = "revoke the test user's access"
    @State private var reconTool = "nmap"
    @State private var reconTarget = ""
    @State private var reconArgs = "-sV -Pn"
    @State private var reportProgram = ""
    @State private var tvMethod = "GET"
    @State private var tvURL = ""
    @State private var tvVariations = "ua-bot | User-Agent: test-bot/1.0 | 0 | rotate UA to a bot string\nburst | | 0 | repeat quickly"
    @State private var tvProfile = ""
    @State private var tvEnv = "prod"
    @State private var aiDiscoverHost = "127.0.0.1"
    @State private var aiEndpoint = "http://127.0.0.1:11434/api/generate"
    @State private var aiModel = ""
    @State private var aiSecret = "CANARY-7f3a-SECRET"
    @State private var aiRefusal = ""
    @State private var bolaMethod = "GET"
    @State private var bolaURL = ""
    @State private var bolaIDs = "0001, 0002, 0003"
    @State private var bolaIdentities = "owner-0001 | 0001 | Authorization: Bearer OWNER1\nattacker | | Authorization: Bearer ATTACKER"

    private func parseBolaIdentities(_ text: String) -> [BolaIdentity] {
        text.split(separator: "\n").compactMap { raw in
            let parts = raw.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard !parts.isEmpty, !parts[0].isEmpty else { return nil }
            let owned = parts.count > 1 ? parts[1].split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty } : []
            var headers: [String: String] = [:]
            if parts.count > 2 {
                for h in parts[2].split(separator: ";") {
                    let kv = h.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if kv.count == 2, !kv[0].isEmpty { headers[kv[0]] = kv[1] }
                }
            }
            return BolaIdentity(label: parts[0], ownedObjectIDs: owned, headers: headers)
        }
    }

    private func parseVariations(_ text: String) -> [RequestVariation] {
        text.split(separator: "\n").compactMap { raw in
            let parts = raw.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard !parts.isEmpty, !parts[0].isEmpty else { return nil }
            var headers: [String: String] = [:]
            if parts.count > 1 {
                for h in parts[1].split(separator: ";") {
                    let kv = h.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if kv.count == 2, !kv[0].isEmpty { headers[kv[0]] = kv[1] }
                }
            }
            let delay = parts.count > 2 ? (Int(parts[2]) ?? 0) : 0
            let note = parts.count > 3 ? parts[3] : ""
            return RequestVariation(label: parts[0], headerOverrides: headers, delayMs: delay, note: note)
        }
    }

    private func parseHeaders(_ text: String) -> [String: String] {
        var headers: [String: String] = [:]
        for h in text.split(whereSeparator: { $0 == ";" || $0 == "\n" }) {
            let kv = h.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, !kv[0].isEmpty { headers[kv[0]] = kv[1] }
        }
        return headers
    }
    @State private var acIdentities = "owner | authorized | Authorization: Bearer OWNER-TOKEN\nattacker | denied | Authorization: Bearer ATTACKER-TOKEN\nanon | denied |"

    // Parse one identity per line: "label | authorized|denied | Header: value; Header2: value2"
    private func parseIdentities(_ text: String) -> [ReplayIdentity] {
        text.split(separator: "\n").compactMap { raw in
            let parts = raw.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2, !parts[0].isEmpty else { return nil }
            let authorized = parts[1].lowercased().hasPrefix("auth")
            var headers: [String: String] = [:]
            if parts.count == 3 {
                for h in parts[2].split(separator: ";") {
                    let kv = h.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if kv.count == 2, !kv[0].isEmpty { headers[kv[0]] = kv[1] }
                }
            }
            return ReplayIdentity(label: parts[0], authorized: authorized, headers: headers)
        }
    }

    private var scopeEntries: [String] { model.session.researchCase?.contract.authorizedScope ?? [] }

    private func lines(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "\n" || $0 == " " }).map(String.init).filter { !$0.isEmpty }
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 14) {
                Text("EXTERNAL TOOLS / SCOPE-GATED").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(acid)
                if let id = model.session.researchCase?.contract.id {
                    Text("Engagement: \(id)").font(.caption)
                    Text(scopeEntries.isEmpty ? "Rules of engagement: NO scope defined — outward tool actions are blocked." : "In scope (RoE): \(scopeEntries.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(scopeEntries.isEmpty ? .orange : .secondary)
                } else {
                    Text("No research case active. Import a case contract with an authorized scope to enable outward tools.").font(.caption).foregroundStyle(.orange)
                }
                Divider()

                Text("DOCKER").font(.headline).foregroundStyle(acid)
                Text(model.dockerPath.isEmpty ? "Docker CLI not detected." : model.dockerPath).font(.caption2).foregroundStyle(.secondary)
                HStack { Text("docker").font(.system(.body, design: .monospaced)); TextField("subcommand (e.g. run)", text: $dockerSub).textFieldStyle(.roundedBorder).frame(width: 130) }
                TextField("arguments (space-separated)", text: $dockerArgs).textFieldStyle(.roundedBorder)
                TextField("in-scope target URL(s) — required for network actions", text: $dockerTargets).textFieldStyle(.roundedBorder)
                Button("Review & Run Docker…") { model.prepareDockerRun(subcommand: dockerSub, arguments: lines(dockerArgs), targets: lines(dockerTargets)) }
                    .disabled(model.running || model.busy || model.dockerPath.isEmpty)
                Text(DockerControl.assurance).font(.caption2).foregroundStyle(.secondary)

                Divider()
                Text("BURP SUITE PRO (REST, loopback)").font(.headline).foregroundStyle(acid)
                TextField("Burp REST base (http://127.0.0.1:1337)", text: $model.burpBase).textFieldStyle(.roundedBorder)
                TextField("API key (optional)", text: $model.burpAPIKey).textFieldStyle(.roundedBorder)
                TextField("target URL(s) to scan — must be in scope", text: $burpURLs).textFieldStyle(.roundedBorder)
                Button("Scope-Gate & Start Scan") { model.burpScan(urls: lines(burpURLs)) }
                    .disabled(model.busy)
                HStack { TextField("scan task id", text: $burpTaskID).textFieldStyle(.roundedBorder).frame(width: 140)
                         Button("Import Issues as Leads") { model.importBurpIssues(taskID: burpTaskID.trimmingCharacters(in: .whitespaces)) }
                             .disabled(model.busy || burpTaskID.trimmingCharacters(in: .whitespaces).isEmpty || model.session.researchCase == nil) }
                Text("Every target is authorized against the RoE scope and mirrored into Burp's scan scope before anything is sent. Imported issues are leads (sourceReport), not findings — reproduce and capture to promote one.").font(.caption2).foregroundStyle(.secondary)

                Divider()
                Text("ACCESS-CONTROL / IDENTITY MATRIX").font(.headline).foregroundStyle(acid)
                HStack { Picker("", selection: $acMethod) { ForEach(["GET","POST","PUT","PATCH","DELETE"], id: \.self) { Text($0).tag($0) } }.frame(width: 100).labelsHidden()
                         TextField("in-scope target URL (e.g. https://api.client.test/accounts/0001)", text: $acURL).textFieldStyle(.roundedBorder) }
                Text("One identity per line:  label | authorized|denied | Header: value; Header2: value2").font(.caption2).foregroundStyle(.secondary)
                TextEditor(text: $acIdentities).font(.system(size: 11, design: .monospaced)).frame(height: 70).border(Color.secondary.opacity(0.3))
                HStack { Button("Run Identity Matrix") { model.runIdentityMatrix(method: acMethod, urlString: acURL.trimmingCharacters(in: .whitespaces), identities: parseIdentities(acIdentities)) }
                             .disabled(model.replayBusy || model.busy || acURL.trimmingCharacters(in: .whitespaces).isEmpty || model.session.researchCase == nil)
                         if model.replayBusy { ProgressView().controlSize(.small) } }
                Text("Sends the same request under each identity (scope-gated, redirects refused), captures every response as evidence, and compares them. A broken-access-control signal is a lead backed by real captures — approve a claim citing them to promote a Finding.").font(.caption2).foregroundStyle(.secondary)

                Divider()
                Text("OBJECT-ID SWEEP (BOLA / IDOR)").font(.headline).foregroundStyle(acid)
                HStack { Picker("", selection: $bolaMethod) { ForEach(["GET","POST","PUT","PATCH","DELETE"], id: \.self) { Text($0).tag($0) } }.frame(width: 100).labelsHidden()
                         TextField("in-scope URL template with {id} (e.g. https://api.client.test/accounts/{id})", text: $bolaURL).textFieldStyle(.roundedBorder) }
                TextField("object IDs (comma/space separated)", text: $bolaIDs).textFieldStyle(.roundedBorder)
                Text("One identity per line:  label | owned-ids (comma sep) | Header: value; Header2: value2").font(.caption2).foregroundStyle(.secondary)
                TextEditor(text: $bolaIdentities).font(.system(size: 11, design: .monospaced)).frame(height: 56).border(Color.secondary.opacity(0.3))
                HStack { Button("Run Object-ID Sweep") { model.runBolaSweep(method: bolaMethod, urlTemplate: bolaURL.trimmingCharacters(in: .whitespaces), objectIDs: bolaIDs.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty }, identities: parseBolaIdentities(bolaIdentities)) }
                             .disabled(model.replayBusy || model.busy || bolaURL.trimmingCharacters(in: .whitespaces).isEmpty || model.session.researchCase == nil)
                         if model.replayBusy { ProgressView().controlSize(.small) } }
                if let b = model.bolaSignal {
                    Text(b.detail).font(.caption).foregroundStyle(b.present ? .orange : acid).textSelection(.enabled)
                }
                Text("Runs each identity against each object ID (scope-gated). Authorization is per object — each identity declares the IDs it owns; a success on an object it does not own is a cross-tenant read (BOLA/IDOR) lead, strongest when it returns the exact bytes an owner received. Every response is captured as evidence; approve a claim citing them to promote.").font(.caption2).foregroundStyle(.secondary)

                Divider()
                Text("SOURCE REVIEW (SEMGREP)").font(.headline).foregroundStyle(acid)
                Button("Import semgrep --json results…") {
                    let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let u = panel.url { model.importSemgrepResults(resultsPath: u.path) }
                }.disabled(model.busy || model.session.researchCase == nil)
                Text("Run semgrep yourself (semgrep --json -o out.json) on the available source, then import. Results are leads (sourceReport) — verify reachability and impact, capture, then promote.").font(.caption2).foregroundStyle(.secondary)
                Button("Import ffuf -o results…") {
                    let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let u = panel.url { model.importFfufResults(resultsPath: u.path) }
                }.disabled(model.busy || model.session.researchCase == nil)
                Text("Import ffuf path-discovery results (ffuf -o out.json) as leads. Run ffuf scope-gated against an in-scope target.").font(.caption2).foregroundStyle(.secondary)

                Divider()
                Text("RECON (NMAP / FFUF) — SCOPE-GATED RUN").font(.headline).foregroundStyle(acid)
                HStack { Picker("", selection: $reconTool) { Text("nmap").tag("nmap"); Text("ffuf").tag("ffuf") }.frame(width: 110).labelsHidden()
                         TextField(reconTool == "ffuf" ? "in-scope URL with FUZZ keyword" : "in-scope host / IP", text: $reconTarget).textFieldStyle(.roundedBorder) }
                TextField("arguments (space-separated)", text: $reconArgs).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Review & Run Recon…") { model.prepareReconRun(tool: reconTool == "ffuf" ? .ffuf : .nmap, target: reconTarget.trimmingCharacters(in: .whitespaces), extraArgs: lines(reconArgs)) }
                        .disabled(model.running || model.busy || reconTarget.trimmingCharacters(in: .whitespaces).isEmpty || model.session.researchCase == nil)
                    Button("Import nmap -oX / -oG results…") {
                        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let u = panel.url { model.importNmapResults(resultsPath: u.path) }
                    }.disabled(model.busy || model.session.researchCase == nil)
                }
                Text("Runs scope-gated against a target you review first — the host is authorized against the RoE before anything runs, and the output is receipted. Or run the tool yourself and import its output. Open ports/paths are leads (sourceReport) — verify impact and capture to promote.").font(.caption2).foregroundStyle(.secondary)

                Divider()
                Text("AUTHORIZATION PERSISTENCE (TEMPORAL)").font(.headline).foregroundStyle(acid)
                HStack { Picker("", selection: $apMethod) { ForEach(["GET","POST","PUT","PATCH","DELETE"], id: \.self) { Text($0).tag($0) } }.frame(width: 100).labelsHidden()
                         TextField("in-scope protected-action URL", text: $apURL).textFieldStyle(.roundedBorder) }
                TextField("credential headers (Header: value; …)", text: $apHeaders).textFieldStyle(.roundedBorder)
                TextField("authorization change you will make out-of-band", text: $apChange).textFieldStyle(.roundedBorder)
                HStack {
                    Button("1 · Capture Baseline") { model.captureAuthorizationBaseline(method: apMethod, urlString: apURL.trimmingCharacters(in: .whitespaces), label: "cred", headers: parseHeaders(apHeaders), change: apChange) }
                        .disabled(model.authCheckBusy || model.busy || apURL.trimmingCharacters(in: .whitespaces).isEmpty || model.session.researchCase == nil)
                    Button("2 · Re-check After Change") { model.recheckAuthorizationAfterChange() }
                        .disabled(model.authCheckBusy || model.busy || model.pendingAuthBaseline == nil)
                    if model.authCheckBusy { ProgressView().controlSize(.small) }
                }
                Text("Capture the protected action while the credential is valid, then revoke access / change ownership in the target, then re-check with the SAME credential. A success after the change is stale authorization — the credential outlived its authority. Only against an authorized test environment with canary data.").font(.caption2).foregroundStyle(.secondary)

                Divider()
                Text("TEST VARIATION / DETECTION (PURPLE TEAM)").font(.headline).foregroundStyle(acid)
                HStack { Picker("", selection: $tvMethod) { ForEach(["GET","POST","PUT","PATCH","DELETE"], id: \.self) { Text($0).tag($0) } }.frame(width: 100).labelsHidden()
                         TextField("in-scope target URL", text: $tvURL).textFieldStyle(.roundedBorder) }
                Text("Baseline is sent unmodified. One variation per line:  label | Header: value; Header2: value2 | delayMs | note").font(.caption2).foregroundStyle(.secondary)
                TextEditor(text: $tvVariations).font(.system(size: 11, design: .monospaced)).frame(height: 60).border(Color.secondary.opacity(0.3))
                HStack { TextField("profile name (optional — save & compare re-runs)", text: $tvProfile).textFieldStyle(.roundedBorder)
                         TextField("environment", text: $tvEnv).textFieldStyle(.roundedBorder).frame(width: 120) }
                HStack { Button("Run Detection Test") { model.runTestVariations(method: tvMethod, urlString: tvURL.trimmingCharacters(in: .whitespaces), baseline: RequestVariation(label: "baseline", note: "unmodified request"), variations: parseVariations(tvVariations), profileName: tvProfile.trimmingCharacters(in: .whitespaces), environment: tvEnv.trimmingCharacters(in: .whitespaces)) }
                             .disabled(model.replayBusy || model.busy || tvURL.trimmingCharacters(in: .whitespaces).isEmpty || model.session.researchCase == nil)
                         if model.replayBusy { ProgressView().controlSize(.small) } }
                if let s = model.variationSignal {
                    Text(s.detail).font(.caption).foregroundStyle(s.detectionObserved ? .orange : acid).textSelection(.enabled)
                }
                if let c = model.detectionComparison {
                    Text("Compared to prior run (\(c.priorEnvironment) → \(c.newEnvironment)): \(c.detail)").font(.caption).foregroundStyle(c.hasChanges ? .orange : .secondary).textSelection(.enabled)
                }
                Text("Sends the same request as baseline and under each recorded variation (scope-gated), captures every response as evidence, and reports whether the defense reacted differently. A differential is a LEAD — verify against the defense's telemetry and capture to promote. Variations are preserved test inputs, not a stealth mode.").font(.caption2).foregroundStyle(.secondary)

                Divider()
                Text("AI RED TEAM (LLM / AGENT)").font(.headline).foregroundStyle(acid)
                HStack { TextField("discover inference endpoints on in-scope host", text: $aiDiscoverHost).textFieldStyle(.roundedBorder)
                         Button("Discover") { model.discoverInferenceEndpoints(host: aiDiscoverHost.trimmingCharacters(in: .whitespaces)) }
                             .disabled(model.replayBusy || model.busy || aiDiscoverHost.trimmingCharacters(in: .whitespaces).isEmpty || model.session.researchCase == nil) }
                if !model.discoveredEndpoints.isEmpty {
                    Text("Endpoints: " + model.discoveredEndpoints.map { "\($0.path) [\($0.kind)]" }.joined(separator: ", ")).font(.caption2).foregroundStyle(acid).textSelection(.enabled)
                }
                TextField("in-scope AI endpoint (e.g. http://127.0.0.1:11434/api/generate)", text: $aiEndpoint).textFieldStyle(.roundedBorder)
                HStack { TextField("model", text: $aiModel).textFieldStyle(.roundedBorder)
                         TextField("canary secret marker", text: $aiSecret).textFieldStyle(.roundedBorder) }
                TextField("refusal probe (optional — tests guardrail robustness)", text: $aiRefusal).textFieldStyle(.roundedBorder)
                HStack { Button("Run AI Injection Suite") { model.runAIInjectionSuite(endpoint: aiEndpoint.trimmingCharacters(in: .whitespaces), model: aiModel.trimmingCharacters(in: .whitespaces), secretMarker: aiSecret.trimmingCharacters(in: .whitespaces), refusalProbe: aiRefusal.trimmingCharacters(in: .whitespaces)) }
                             .disabled(model.replayBusy || model.busy || aiEndpoint.trimmingCharacters(in: .whitespaces).isEmpty || aiModel.trimmingCharacters(in: .whitespaces).isEmpty || model.session.researchCase == nil)
                         if model.replayBusy { ProgressView().controlSize(.small) } }
                if let r = model.aiReport {
                    Text("\(r.successfulTechniques.count) technique(s) crossed: \(r.successfulTechniques.isEmpty ? "none" : r.successfulTechniques.joined(separator: ", "))").font(.caption).foregroundStyle(r.anyCrossing ? .orange : acid).textSelection(.enabled)
                    Text(r.detail).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text(model.aiStatus).font(.caption).foregroundStyle(acid).textSelection(.enabled)
                Text("Sends indirect-prompt-injection payloads and guardrail-robustness mutations to a scope-gated AI endpoint, captures every response as evidence, and rolls them into an attack graph. Every crossing is a LEAD — promote only through the evidence path. Authorized targets only; the case scope gates the endpoint host.").font(.caption2).foregroundStyle(.secondary)

                Divider()
                Text("WIRELESS (UTM / KALI + ALFA)").font(.headline).foregroundStyle(acid)
                let rf = model.session.researchCase?.contract.wirelessScope ?? []
                Text(rf.isEmpty ? "No RF scope in this case — add authorized BSSIDs to the contract (wirelessScope)." : "Authorized BSSIDs (RoE): " + rf.map { "\($0.bssid) ch\($0.channel)" }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(rf.isEmpty ? .orange : .secondary)
                HStack { TextField("UTM VM", text: $model.wirelessVM).textFieldStyle(.roundedBorder).frame(width: 110)
                         TextField("Adapter VID:PID", text: $model.wirelessAdapter).textFieldStyle(.roundedBorder).frame(width: 130)
                         Stepper("\(model.captureDuration)s", value: $model.captureDuration, in: 5...600, step: 5).frame(width: 110) }
                TextField("Authorization basis (RoE / ownership record)", text: $model.wirelessAuthorization).textFieldStyle(.roundedBorder)
                Toggle("Use SSH instead of the UTM guest agent", isOn: $model.wirelessUseSSH).font(.caption)
                if model.wirelessUseSSH {
                    HStack { TextField("host", text: $model.sshHost).textFieldStyle(.roundedBorder)
                             TextField("port", value: $model.sshPort, format: .number).textFieldStyle(.roundedBorder).frame(width: 70)
                             TextField("user", text: $model.sshUser).textFieldStyle(.roundedBorder).frame(width: 90) }
                    TextField("identity key path (optional)", text: $model.sshIdentity).textFieldStyle(.roundedBorder)
                }
                HStack { Button("Run Authorized Wireless Capture") { model.runWirelessCapture() }
                             .disabled(model.wirelessBusy || rf.isEmpty || model.session.researchCase == nil)
                         if model.wirelessBusy { ProgressView().controlSize(.small) } }
                Text("Capture runs in the Kali guest (monitor mode is Linux-only); Wampum orchestrates via utmctl, pulls the pcap back, verifies it against the RoE scope, and pins it as case evidence. Capture only networks you are authorized to test.").font(.caption2).foregroundStyle(.secondary)
                Text(model.wirelessStatus).font(.caption).foregroundStyle(acid).textSelection(.enabled)

                Divider()
                Text("FINDINGS — VERIFY & REPORT").font(.headline).foregroundStyle(acid)
                if let gate = model.findingGate, !gate.issues.isEmpty {
                    Text("Last chat reply — FindingGate: " + gate.issues.map { $0.message }.joined(separator: "; ")).font(.caption2).foregroundStyle(.orange)
                }
                let facts = model.session.researchCase?.ledger.facts ?? []
                if facts.isEmpty {
                    Text("No claims in the ledger yet. Propose and approve an evidence-backed claim, then verify it here.").font(.caption2).foregroundStyle(.secondary)
                } else {
                    ForEach(facts, id: \.id) { fact in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(fact.id).font(.system(size: 11, weight: .semibold, design: .monospaced))
                                Text(fact.content).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Button("Verify") { model.verifyFinding(factID: fact.id) }.font(.caption2)
                        }
                    }
                }
                if let v = model.findingVerdict {
                    Text(v.summary).font(.caption).foregroundStyle(v.isFinding ? acid : .orange).textSelection(.enabled)
                }
                HStack { TextField("program (e.g. HackerOne: acme)", text: $reportProgram).textFieldStyle(.roundedBorder)
                         Button("Generate Report") { model.generateFindingReport(program: reportProgram.trimmingCharacters(in: .whitespaces)) }
                             .disabled(model.session.researchCase == nil) }
                if let r = model.findingReport {
                    Text("\(r.findings.count) promoted finding(s), \(r.excluded.count) excluded.").font(.caption2).foregroundStyle(.secondary)
                    Button("Export Report Bundle…") {
                        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false; p.prompt = "Export Here"
                        if p.runModal() == .OK, let u = p.url { model.exportFindingReport(program: reportProgram.trimmingCharacters(in: .whitespaces), to: u) }
                    }
                }
                Button("Export Full Engagement Bundle…") {
                    let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false; p.prompt = "Export Here"
                    if p.runModal() == .OK, let u = p.url { model.exportEngagementBundle(to: u) }
                }.disabled(model.session.researchCase == nil)
                Text("The full engagement bundle is one auditable artifact for this client: report + complete case ledger + this engagement's receipts + copied evidence + in-scope network events, with a hashed manifest. Scoped to this engagement only.").font(.caption2).foregroundStyle(.secondary)
                Text(model.reportStatus).font(.caption).foregroundStyle(acid).textSelection(.enabled)
                Text("A report contains only promoted Findings (operator-approved + a host receipt that verifies on disk + clean FindingGate), each re-checked at generation. Severity and impact are operator-filled. Export is a per-engagement bundle, proven by reading the written report back and hashing it into a receipt.").font(.caption2).foregroundStyle(.secondary)

                Spacer()
                Text(model.toolStatus).font(.caption).textSelection(.enabled)
            }.padding(14).frame(minWidth: 360, idealWidth: 430, maxWidth: 560).background(panel)

            VStack(alignment: .leading, spacing: 8) {
                Text("TOOL RECEIPTS").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(acid)
                Text("A receipt records what Wampum asked a tool to do. Pin one as case evidence to let a verified result back a Finding.").font(.caption2).foregroundStyle(.secondary)
                if !model.output.isEmpty { ScrollView { Text(model.output).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 160) }
                let activeEngagement = model.session.researchCase?.contract.id
                // Scope receipts to the active engagement so one client's tool activity never shows
                // while working another's. With no case active, only unscoped/legacy receipts show.
                let visibleReceipts = model.toolReceipts.filter { $0.engagement == activeEngagement }
                let hiddenCount = model.toolReceipts.count - visibleReceipts.count
                if let id = activeEngagement { Text("Showing receipts for engagement: \(id)").font(.caption2).foregroundStyle(.secondary) }
                if hiddenCount > 0 { Text("\(hiddenCount) receipt(s) from other engagements hidden.").font(.caption2).foregroundStyle(.secondary) }
                List(visibleReceipts.reversed(), id: \.id) { receipt in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(receipt.tool) / \(receipt.action) — \(receipt.outcome.rawValue)").font(.system(size: 12, weight: .semibold, design: .monospaced))
                        if !receipt.targets.isEmpty { Text("targets: \(receipt.targets.joined(separator: ", "))").font(.caption2).foregroundStyle(.secondary) }
                        Text(receipt.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                        Button("Pin as Case Evidence") { model.pinToolReceiptAsEvidence(receipt) }
                            .font(.caption2).disabled(model.session.researchCase == nil)
                    }.padding(.vertical, 3)
                }.listStyle(.plain)
            }.padding(14).frame(minWidth: 320).background(panel)
        }
        .sheet(isPresented: $model.showDockerConfirmation) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Approve one docker command").font(.title2)
                if let plan = model.pendingDockerPlan {
                    Text(([plan.executable.path] + plan.arguments).joined(separator: " ")).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Text(plan.receipt.targets.isEmpty ? "No network target (local docker action)." : "In-scope targets: \(plan.receipt.targets.joined(separator: ", "))")
                    Text(DockerControl.assurance).font(.caption).foregroundStyle(.secondary)
                }
                HStack { Button("Cancel", action: model.cancelDockerRun); Spacer(); Button("Run This Command", action: model.allowDockerRun).buttonStyle(.borderedProminent) }
            }.padding(24).frame(width: 680)
        }
        .sheet(isPresented: $model.showReconConfirmation) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Approve one recon command").font(.title2)
                if let plan = model.pendingReconPlan {
                    Text(([plan.executable.path] + plan.arguments).joined(separator: " ")).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Text("In-scope target: \(plan.receipt.targets.joined(separator: ", "))")
                    Text("Scope-gated against the rules of engagement and run as an owned process you reviewed. Output is receipted. Results are leads until verified and captured.").font(.caption).foregroundStyle(.secondary)
                }
                HStack { Button("Cancel", action: model.cancelReconRun); Spacer(); Button("Run This Command", action: model.allowReconRun).buttonStyle(.borderedProminent) }
            }.padding(24).frame(width: 680)
        }
    }
}
