import Foundation

/// One authorized wireless target in a rules-of-engagement scope.
public struct WirelessTarget: Codable, Sendable, Equatable {
    public let bssid: String      // normalized AA:BB:CC:DD:EE:FF
    public let channel: Int
    public let essid: String?
    public init(bssid: String, channel: Int, essid: String? = nil) {
        self.bssid = WirelessScope.normalize(bssid); self.channel = channel
        self.essid = essid?.isEmpty == true ? nil : essid
    }
}

/// The RF rules of engagement: the exact BSSIDs a wireless capture is authorized to touch.
/// Fail-closed like `AuthorizedScope` — an empty scope authorizes no capture. This is what
/// keeps an Alfa capture (run in the Kali guest) inside the engagement: Wampum only ever
/// instructs the guest to capture these BSSIDs, and it re-checks every returned manifest
/// against them before anything becomes evidence.
public struct WirelessScope: Codable, Sendable, Equatable {
    public let targets: [WirelessTarget]
    public init(_ targets: [WirelessTarget]) {
        var seen = Set<String>(); var kept: [WirelessTarget] = []
        for t in targets where seen.insert(t.bssid).inserted { kept.append(t) }
        self.targets = kept
    }
    public var isEmpty: Bool { targets.isEmpty }
    public var bssids: [String] { targets.map(\.bssid) }

    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().replacingOccurrences(of: "-", with: ":")
    }
    public static func isValidBSSID(_ bssid: String) -> Bool {
        normalize(bssid).range(of: "^([0-9A-F]{2}:){5}[0-9A-F]{2}$", options: .regularExpression) != nil
    }
    /// Valid 2.4/5/6 GHz channel numbers in the ranges tools accept.
    public static func isValidChannel(_ channel: Int) -> Bool {
        (1...14).contains(channel) || (32...177).contains(channel) || (1...233).contains(channel)
    }
    public func validate() throws {
        guard targets.count <= 200 else { throw WorkbenchError.invalid("Wireless scope has too many targets (max 200).") }
        for t in targets {
            guard Self.isValidBSSID(t.bssid) else { throw WorkbenchError.invalid("Wireless target BSSID is not a valid MAC: \(t.bssid)") }
            guard Self.isValidChannel(t.channel) else { throw WorkbenchError.invalid("Wireless target channel is out of range: \(t.channel)") }
        }
    }
    public func contains(bssid: String) -> Bool { bssids.contains(Self.normalize(bssid)) }

    /// Authorize a single BSSID, returning its normalized form. Fail-closed.
    @discardableResult
    public func authorize(bssid: String) throws -> String {
        guard Self.isValidBSSID(bssid) else { throw WorkbenchError.invalid("Not a valid BSSID: \(bssid)") }
        guard !isEmpty else { throw WorkbenchError.invalid("No wireless scope is defined for this case. Declare the authorized BSSIDs in the case contract before any capture.") }
        let normalized = Self.normalize(bssid)
        guard bssids.contains(normalized) else { throw WorkbenchError.invalid("BSSID \(normalized) is outside the case's authorized wireless scope.") }
        return normalized
    }
    /// The subset of scope the operator selects for a given capture run, each re-authorized.
    public func select(_ bssids: [String]) throws -> [WirelessTarget] {
        try bssids.map { b in
            let normalized = try authorize(bssid: b)
            guard let target = targets.first(where: { $0.bssid == normalized }) else { throw WorkbenchError.invalid("BSSID not in scope: \(normalized)") }
            return target
        }
    }
}
