import SwiftUI
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
                Text("Every target is authorized against the RoE scope and mirrored into Burp's scan scope before anything is sent. Confirm the v0.1 scan schema against your Burp build.").font(.caption2).foregroundStyle(.secondary)

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

                Spacer()
                Text(model.toolStatus).font(.caption).textSelection(.enabled)
            }.padding(14).frame(minWidth: 360, idealWidth: 430, maxWidth: 560).background(panel)

            VStack(alignment: .leading, spacing: 8) {
                Text("TOOL RECEIPTS").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(acid)
                Text("A receipt records what Wampum asked a tool to do. Pin one as case evidence to let a verified result back a Finding.").font(.caption2).foregroundStyle(.secondary)
                if !model.output.isEmpty { ScrollView { Text(model.output).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 160) }
                List(model.toolReceipts.reversed(), id: \.id) { receipt in
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
    }
}
