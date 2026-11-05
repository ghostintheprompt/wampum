import Foundation

/// Object-ID (BOLA / IDOR) sweep: run each identity against a list of object IDs and find where
/// an identity read an object it does not own. Unlike the single-URL identity matrix,
/// authorization here is PER OBJECT — each identity declares which object IDs it legitimately
/// owns, and a success on any other object is a horizontal access-control lead.
///
/// Like every tool here it only reads status and body hashes, proves nothing about intent, and
/// produces LEADS: a cross-tenant read is promoted only through the captured responses + the
/// evidence + `FindingVerification` path.

/// One test identity for the sweep. `ownedObjectIDs` is the operator's statement of what this
/// identity is *supposed* to access — not inferred from any response.
public struct BolaIdentity: Codable, Equatable, Sendable {
    public let label: String
    public let ownedObjectIDs: [String]
    public let headers: [String: String]
    public init(label: String, ownedObjectIDs: [String], headers: [String: String] = [:]) {
        self.label = label; self.ownedObjectIDs = ownedObjectIDs; self.headers = headers
    }
    public func owns(_ objectID: String) -> Bool { ownedObjectIDs.contains(objectID) }
}

/// One (identity, object) observation in the grid.
public struct BolaCell: Codable, Equatable, Sendable {
    public let identity: String
    public let objectID: String
    public let authorized: Bool      // does this identity own this object?
    public let status: Int
    public let bodySHA256: String
    public let bodyBytes: Int
    public init(identity: String, objectID: String, authorized: Bool, status: Int, bodySHA256: String, bodyBytes: Int) {
        self.identity = identity; self.objectID = objectID; self.authorized = authorized
        self.status = status; self.bodySHA256 = bodySHA256; self.bodyBytes = bodyBytes
    }
    var isSuccess: Bool { (200..<300).contains(status) }
}

public enum BolaSweep {
    /// Lead strength. strong = byte-identical to what an owner received (a real cross-tenant read).
    /// weak = empty or shared/boilerplate body (a uniform allow/deny page, not object data).
    public enum Confidence: String, Codable, Equatable, Sendable { case strong, moderate, weak }

    public struct Signal: Codable, Equatable, Sendable {
        public struct Hit: Codable, Equatable, Sendable {
            public let identity: String
            public let objectID: String
            public let byteIdenticalToOwner: Bool   // strongest: same bytes an owner received
            public let confidence: Confidence
            public init(identity: String, objectID: String, byteIdenticalToOwner: Bool, confidence: Confidence = .moderate) {
                self.identity = identity; self.objectID = objectID
                self.byteIdenticalToOwner = byteIdenticalToOwner; self.confidence = confidence
            }
        }
        public let crossTenant: [Hit]
        public let detail: String
        public var present: Bool { !crossTenant.isEmpty }
        public var strongHits: [Hit] { crossTenant.filter { $0.confidence == .strong } }
    }

    public static func evaluate(_ cells: [BolaCell]) throws -> Signal {
        guard !cells.isEmpty else { throw WorkbenchError.invalid("No cells to evaluate.") }
        let keys = cells.map { "\($0.identity)\u{1}\($0.objectID)" }
        guard Set(keys).count == keys.count else { throw WorkbenchError.invalid("Duplicate (identity, object) cells.") }

        // Boilerplate detector: a success body hash recurring across many DISTINCT objects is a
        // shared/static/denied response, not per-object data — demote reads that return it.
        var objectsPerHash: [String: Set<String>] = [:]
        for c in cells where c.isSuccess { objectsPerHash[c.bodySHA256, default: []].insert(c.objectID) }
        func isBoilerplate(_ hash: String) -> Bool { (objectsPerHash[hash]?.count ?? 0) >= 3 }

        var hits: [Signal.Hit] = []
        let byObject = Dictionary(grouping: cells, by: { $0.objectID })
        for (_, group) in byObject {
            let ownerHashes = Set(group.filter { $0.authorized && $0.isSuccess }.map(\.bodySHA256))
            for cell in group where !cell.authorized && cell.isSuccess {
                let identical = ownerHashes.contains(cell.bodySHA256)
                let confidence: Confidence = identical ? .strong
                    : (cell.bodyBytes == 0 || isBoilerplate(cell.bodySHA256)) ? .weak : .moderate
                hits.append(.init(identity: cell.identity, objectID: cell.objectID,
                                  byteIdenticalToOwner: identical, confidence: confidence))
            }
        }
        // Stable ordering: object then identity.
        hits.sort { ($0.objectID, $0.identity) < ($1.objectID, $1.identity) }

        let detail: String
        if hits.isEmpty {
            detail = "No cross-tenant access: every identity succeeded only on objects it owns. No BOLA/IDOR signal."
        } else {
            let strong = hits.filter { $0.confidence == .strong }
            let moderate = hits.filter { $0.confidence == .moderate }
            let weak = hits.filter { $0.confidence == .weak }
            let parts = hits.map { "\($0.identity)→\($0.objectID)\($0.byteIdenticalToOwner ? " (owner-identical)" : "")" }.joined(separator: ", ")
            detail = "\(hits.count) cross-tenant read(s): \(parts). Confidence — " +
                "strong \(strong.count) (owner-identical bytes; a real BOLA lead — reproduce + capture to promote), " +
                "moderate \(moderate.count) (distinct body; verify it is the victim's data), " +
                "weak \(weak.count) (empty or shared/boilerplate body; likely a uniform allow/deny, not a read)."
        }
        return Signal(crossTenant: hits, detail: detail)
    }
}
