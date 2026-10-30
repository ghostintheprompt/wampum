import Foundation

/// Scope-gated control of the local Docker CLI, open for authorized client engagements.
///
/// "Open within the rules of engagement": any docker subcommand runs under per-invocation
/// operator review — Wampum does not maintain an artificial allowlist that would block
/// legitimate client work. The security rules it does enforce are the ones that matter: a
/// network-capable subcommand requires an operator-declared target that is in the case's
/// authorized scope (the RoE), execution is a direct owned process (no shell), and every
/// invocation produces a receipt.
///
/// Honest boundary: wrapping the `docker` client process does NOT contain what the Docker
/// daemon runs — a container's own network egress is outside Wampum's control. Containment
/// here is the declared-target scope gate, operator review and the receipt, not a sandbox.
public enum DockerControl {
    public static let assurance = "Wampum gates and records the docker command it issues. It does NOT contain a container's runtime network egress; the daemon, not Wampum, runs the container. Declare the engagement targets so they are scope-checked against the rules of engagement, and treat container behavior as outside this boundary."

    /// Subcommands that can reach the network / start workloads: a declared in-scope target
    /// is required before Wampum will plan one.
    public static let networkCapable: Set<String> = ["run", "exec", "build", "pull", "push", "start", "compose", "attach", "cp", "import", "login"]
    /// Read-only / inspection subcommands that do not themselves reach an engagement target,
    /// so they may run with no declared target.
    public static let readOnly: Set<String> = ["ps", "images", "inspect", "logs", "version", "info", "port", "top", "stats", "diff", "history", "stop", "kill", "rm", "rmi", "tag", "save", "load", "create", "pause", "unpause", "wait", "events", "system"]

    /// A subcommand needs a declared in-scope target unless it is known read-only. Unknown
    /// subcommands are treated conservatively as network-capable so they cannot slip the gate.
    public static func requiresTarget(_ name: String) -> Bool { !readOnly.contains(name) }

    public static func detect() -> URL? {
        for path in ["/opt/homebrew/bin/docker", "/usr/local/bin/docker", "/usr/bin/docker"] where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    public struct Plan {
        public let executable: URL
        public let arguments: [String]
        public let receipt: ToolReceipt
    }

    /// Validate and build an owned-process plan for one docker invocation. Fails closed:
    /// unknown subcommand, a network-capable subcommand with no declared target, or any
    /// out-of-scope declared target all throw and nothing is planned.
    public static func plan(executable: URL, subcommand: String, arguments: [String], targets: [String], scope: AuthorizedScope) throws -> Plan {
        let name = subcommand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty, !name.hasPrefix("-"), name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            throw WorkbenchError.invalid("Docker subcommand is required and must be a plain subcommand name.")
        }
        for argument in arguments {
            guard !argument.contains("\0"), !argument.contains("\n") else { throw WorkbenchError.invalid("Docker argument contains a control character.") }
        }
        if requiresTarget(name) && targets.isEmpty {
            throw WorkbenchError.invalid("'\(name)' can reach the network or start a workload. Declare the in-scope engagement target(s) so they can be authorized against the rules of engagement.")
        }
        let hosts = try ToolScopeGate.authorize(targets: targets, scope: scope)
        let argv = [name] + arguments
        let plan = try CommandPlan.ownedTool(executable: executable, arguments: argv)
        let receipt = ToolReceipt(tool: "docker", action: name, targets: hosts,
                                  argument: ([executable.path] + argv).joined(separator: " "),
                                  detail: requiresTarget(name) ? "Network-capable; container egress is outside Wampum's control." : "Local docker action.")
        return Plan(executable: plan.executable, arguments: plan.arguments, receipt: receipt)
    }
}
