import Foundation

/// Orchestrates a wireless capture in a UTM Linux guest (e.g. Kali with the Alfa passed
/// through) via `utmctl`. The capture itself runs in the guest — the radio and its driver
/// live in the Linux kernel — but Wampum drives the whole sequence and stays the evidence
/// custodian: it generates the RoE-bounded guest scope file, runs the capture script, pulls
/// the results back, and re-checks every returned manifest against the wireless scope before
/// anything becomes evidence.
///
/// This type is pure: it builds the exact `utmctl` argument vectors and verifies data. The
/// app layer runs the commands (they need stdin/stdout piping for `file push`/`pull`).
/// `exec`, `file` and `ip-address` require the QEMU guest agent in the guest; SSH is the
/// documented fallback when it is not installed.
public enum UTMControl {
    public static func detect() -> URL? {
        let path = "/Applications/UTM.app/Contents/MacOS/utmctl"
        return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    /// A guest path Wampum writes to / reads from. Constrained to avoid surprises.
    public static func isSafeGuestPath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("..") && !path.contains("\0") && !path.contains("\n") && path.count <= 4096
    }

    public enum Step {
        case start, stop, status, ipAddress
        case exec(cmd: String)
        case filePush(guestPath: String)
        case filePull(guestPath: String)
    }

    /// The utmctl argument vector for a step against the given VM (UUID or exact name).
    /// `--hide` keeps the capture from stealing the UTM window.
    public static func argv(vm: String, _ step: Step) throws -> [String] {
        guard !vm.isEmpty, !vm.contains("\0"), !vm.contains("\n") else { throw WorkbenchError.invalid("Invalid VM identifier.") }
        switch step {
        case .start:     return ["start", "--hide", vm]
        case .stop:      return ["stop", vm]
        case .status:    return ["status", vm]
        case .ipAddress: return ["ip-address", "--hide", vm]
        case .exec(let cmd):
            guard !cmd.isEmpty, !cmd.contains("\0") else { throw WorkbenchError.invalid("Empty or invalid guest command.") }
            return ["exec", "--hide", vm, "--cmd", cmd]
        case .filePush(let path):
            guard isSafeGuestPath(path) else { throw WorkbenchError.invalid("Unsafe guest destination path.") }
            return ["file", "push", "--hide", vm, path]
        case .filePull(let path):
            guard isSafeGuestPath(path) else { throw WorkbenchError.invalid("Unsafe guest source path.") }
            return ["file", "pull", "--hide", vm, path]
        }
    }

    // MARK: - Guest scope file

    private struct GuestScope: Encodable {
        struct Target: Encodable { let bssid: String; let channel: Int; let essid: String? }
        let engagement_id: String
        let `operator`: String
        let authorization: String
        let duration_seconds: Int
        let targets: [Target]
    }

    /// Build the scope.json bytes the guest capture script consumes. Every selected target is
    /// re-authorized against the wireless scope here; an out-of-scope selection fails closed.
    public static func guestScopeData(engagementID: String, operator op: String, authorization: String,
                                      durationSeconds: Int, scope: WirelessScope, select bssids: [String]) throws -> Data {
        guard !engagementID.isEmpty else { throw WorkbenchError.invalid("Engagement id is required.") }
        guard !authorization.isEmpty else { throw WorkbenchError.invalid("Authorization basis is required (the RoE / ownership record).") }
        guard durationSeconds >= 1, durationSeconds <= 86_400 else { throw WorkbenchError.invalid("Duration must be 1…86400 seconds.") }
        let targets = try scope.select(bssids)
        guard !targets.isEmpty else { throw WorkbenchError.invalid("Select at least one in-scope BSSID to capture.") }
        let guest = GuestScope(engagement_id: engagementID, operator: op, authorization: authorization,
                               duration_seconds: durationSeconds,
                               targets: targets.map { .init(bssid: $0.bssid, channel: $0.channel, essid: $0.essid) })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(guest)
    }

    // MARK: - Manifest verification

    public struct GuestManifest: Decodable {
        public struct Target: Decodable { public let bssid: String; public let channel: Int; public let essid: String? }
        public struct File: Decodable, Equatable { public let path: String; public let sha256: String; public let bytes: Int64 }
        public let engagement_id: String
        public let targets: [Target]
        public let files: [File]
    }

    /// Parse and verify a guest manifest. Fail-closed: the engagement must match and EVERY
    /// captured target must be inside the wireless scope, or nothing is accepted as evidence.
    /// Returns the capture files to pin (after the host copies them locally).
    public static func verify(manifest data: Data, scope: WirelessScope, engagementID: String) throws -> [GuestManifest.File] {
        let manifest: GuestManifest
        do { manifest = try JSONDecoder().decode(GuestManifest.self, from: data) }
        catch { throw WorkbenchError.invalid("Guest manifest is not readable: \(error.localizedDescription)") }
        guard manifest.engagement_id == engagementID else {
            throw WorkbenchError.invalid("Manifest engagement '\(manifest.engagement_id)' does not match this case '\(engagementID)'.")
        }
        guard !manifest.targets.isEmpty, !manifest.files.isEmpty else {
            throw WorkbenchError.invalid("Manifest has no captured targets or files.")
        }
        for target in manifest.targets where !scope.contains(bssid: target.bssid) {
            throw WorkbenchError.invalid("Manifest contains an out-of-scope capture: \(target.bssid). Rejected; nothing pinned.")
        }
        for file in manifest.files {
            guard file.sha256.count == 64, file.sha256.allSatisfy({ "0123456789abcdef".contains($0) }), file.bytes >= 0,
                  !file.path.contains("/"), !file.path.contains(".."), !file.path.isEmpty else {
                throw WorkbenchError.invalid("Manifest file entry is malformed: \(file.path)")
            }
        }
        return manifest.files
    }
}
