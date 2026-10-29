import Foundation
import CryptoKit

/// Durable records are supplied data, not authenticated receipts or evidence of execution.
public enum SectionWorkflowError: Error { case invalid(String) }

public struct SectionSource: Codable, Equatable, Sendable {
    public let id: String
    public let contentHash: String
    public init(id: String, contentHash: String) { self.id = id; self.contentHash = contentHash }
}

public struct SectionModelProvenance: Codable, Equatable, Sendable {
    public let model: String
    public let modelDigest: String?
    public let requestID: String
    public init(model: String, modelDigest: String? = nil, requestID: String) {
        self.model = model; self.modelDigest = modelDigest; self.requestID = requestID
    }
}

public struct SectionReviewEvidence: Codable, Equatable, Sendable {
    public let reference: String
    public let contentHash: String
    public let explanation: String
    public init(reference: String, contentHash: String, explanation: String) {
        self.reference = reference; self.contentHash = contentHash; self.explanation = explanation
    }
}

public struct SectionGenerationAttempt: Codable, Equatable, Sendable {
    public let id: String
    public let sectionID: String
    public let caseID: String
    public let contractHash: String
    public let body: String
    public let bodyHash: String
    public let stopReason: String?
    public let outputTokens: Int?
    public let inputTokens: Int?
    public let sources: [SectionSource]
    public let provenance: SectionModelProvenance
    public init(id: String = UUID().uuidString, sectionID: String, caseID: String,
                contractHash: String, body: String, stopReason: String?, outputTokens: Int?,
                inputTokens: Int? = nil, sources: [SectionSource], provenance: SectionModelProvenance) {
        self.id = id; self.sectionID = sectionID; self.caseID = caseID; self.contractHash = contractHash
        self.body = body; self.bodyHash = ResearchSectionWorkflow.hash(Data(body.utf8))
        self.stopReason = stopReason; self.outputTokens = outputTokens; self.inputTokens = inputTokens
        self.sources = sources; self.provenance = provenance
    }
    public var bindingHash: String { get throws { try ResearchSectionWorkflow.recordHash(self) } }
    /// Structural eligibility only; this does not establish semantic completeness.
    public var structurallyComplete: Bool {
        guard stopReason == "stop", !MarkdownArtifact.hasUnclosedFence(body) else { return false }
        let prose = body.components(separatedBy: .newlines).filter {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return !line.isEmpty && !line.hasPrefix("#") && !line.hasPrefix("```") && !line.hasPrefix("~~~")
        }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholders = ["todo", "tbd", "placeholder", "coming soon", "...", "[insert content]"]
        let normalized = prose.lowercased()
        let unfinished = normalized.range(of: "(^|\\s)(todo|tbd|placeholder)(:|\\s|$)|\\[insert[^\\]]*\\]", options: .regularExpression) != nil
        return prose.count >= 24 && !placeholders.contains(normalized) && !unfinished
    }
}

public enum SectionReviewDecision: String, Codable, Sendable { case approve, reject }
public struct SectionHumanReview: Codable, Equatable, Sendable {
    public let id: String
    public let attemptID: String
    public let bindingHash: String
    public let reviewer: String
    public let decision: SectionReviewDecision
    public let evidence: [SectionReviewEvidence]
    public init(id: String = UUID().uuidString, attemptID: String, bindingHash: String,
                reviewer: String, decision: SectionReviewDecision, evidence: [SectionReviewEvidence]) {
        self.id = id; self.attemptID = attemptID; self.bindingHash = bindingHash
        self.reviewer = reviewer; self.decision = decision; self.evidence = evidence
    }
}

public enum SectionReviewState: String, Codable, Sendable { case missing, incomplete, awaitingReview, rejected, stale, accepted }
public enum SectionAssemblyStatus: String, Codable, Sendable { case draft, hostReviewed }

/// The host must authenticate/inspect this supplied record separately. Strings cannot prove provenance.
public struct SectionHostQualityGate: Codable, Equatable, Sendable {
    public let caseID: String
    public let contractHash: String
    public let documentHash: String
    public let reviewer: String
    public let evidence: [SectionReviewEvidence]
    public init(caseID: String, contractHash: String, documentHash: String, reviewer: String,
                evidence: [SectionReviewEvidence]) {
        self.caseID = caseID; self.contractHash = contractHash; self.documentHash = documentHash
        self.reviewer = reviewer; self.evidence = evidence
    }
}

public struct SectionAssembly: Codable, Equatable, Sendable {
    public let bytes: Data
    public let documentHash: String
    public let status: SectionAssemblyStatus
    public let qualityGate: SectionHostQualityGate?
    public init(bytes: Data, status: SectionAssemblyStatus = .draft, qualityGate: SectionHostQualityGate? = nil) {
        self.bytes = bytes; self.documentHash = ResearchSectionWorkflow.hash(bytes)
        self.status = status; self.qualityGate = qualityGate
    }
}

public struct ResearchSectionWorkflow: Codable, Sendable {
    public let caseID: String
    public let requiredSectionIDs: [String]
    public private(set) var contractHash: String
    public private(set) var sources: [SectionSource]
    public private(set) var attempts: [SectionGenerationAttempt]
    public private(set) var reviews: [SectionHumanReview]
    public init(caseID: String, contractHash: String, requiredSectionIDs: [String], sources: [SectionSource]) throws {
        self.caseID = caseID; self.contractHash = contractHash; self.requiredSectionIDs = requiredSectionIDs
        self.sources = sources; attempts = []; reviews = []
        try validate()
    }
    public static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    fileprivate static func recordHash<T: Encodable>(_ record: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return hash(try encoder.encode(record))
    }
    private static func meaningful(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private static func validHash(_ value: String) -> Bool { value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }
    private static func validSources(_ sources: [SectionSource]) -> Bool {
        Set(sources.map(\.id)).count == sources.count && sources.allSatisfy { meaningful($0.id) && validHash($0.contentHash) }
    }
    private static func validEvidence(_ evidence: [SectionReviewEvidence]) -> Bool {
        !evidence.isEmpty && evidence.allSatisfy {
            meaningful($0.reference) && validHash($0.contentHash) && $0.explanation.trimmingCharacters(in: .whitespacesAndNewlines).count >= 16
        }
    }
    public func validate() throws {
        guard Self.meaningful(caseID), Self.validHash(contractHash), !requiredSectionIDs.isEmpty,
              requiredSectionIDs.allSatisfy(Self.meaningful), Set(requiredSectionIDs).count == requiredSectionIDs.count,
              Self.validSources(sources), Set(attempts.map(\.id)).count == attempts.count,
              Set(reviews.map(\.id)).count == reviews.count else { throw SectionWorkflowError.invalid("Invalid workflow identity or duplicate records") }
        for attempt in attempts {
            guard Self.meaningful(attempt.id), attempt.caseID == caseID, requiredSectionIDs.contains(attempt.sectionID),
                  Self.validHash(attempt.contractHash), attempt.bodyHash == Self.hash(Data(attempt.body.utf8)),
                  Self.validSources(attempt.sources), Self.meaningful(attempt.provenance.model), Self.meaningful(attempt.provenance.requestID),
                  attempt.outputTokens.map({ $0 >= 0 }) ?? true, attempt.inputTokens.map({ $0 >= 0 }) ?? true else {
                throw SectionWorkflowError.invalid("Invalid attempt")
            }
        }
        for review in reviews {
            guard let attempt = attempts.first(where: { $0.id == review.attemptID }),
                  try review.bindingHash == attempt.bindingHash, Self.meaningful(review.id), Self.meaningful(review.reviewer),
                  Self.validEvidence(review.evidence), review.decision != .approve || attempt.structurallyComplete else {
                throw SectionWorkflowError.invalid("Invalid review binding or incomplete approval")
            }
        }
    }
    /// Source/contract revisions preserve all historical attempts and reviews. Requirements cannot be removed.
    public mutating func revise(contractHash: String, sources: [SectionSource]) throws {
        var next = self; next.contractHash = contractHash; next.sources = sources; try next.validate(); self = next
    }
    public mutating func record(_ attempt: SectionGenerationAttempt) throws {
        var next = self; next.attempts.append(attempt); try next.validate(); self = next
    }
    public mutating func review(_ review: SectionHumanReview) throws {
        try validate()
        guard let attempt = attempts.first(where: { $0.id == review.attemptID }),
              attempts.last(where: { $0.sectionID == attempt.sectionID })?.id == attempt.id, isCurrent(attempt) else { throw SectionWorkflowError.invalid("Review requires current attempt") }
        var next = self; next.reviews.append(review); try next.validate(); self = next
    }
    private func isCurrent(_ attempt: SectionGenerationAttempt) -> Bool {
        attempt.caseID == caseID && attempt.contractHash == contractHash && Set(attempt.sources) == Set(sources)
    }
    public func state(for sectionID: String) throws -> SectionReviewState {
        try validate()
        guard requiredSectionIDs.contains(sectionID) else { throw SectionWorkflowError.invalid("Unknown required section") }
        guard let attempt = attempts.last(where: { $0.sectionID == sectionID }) else { return .missing }
        guard isCurrent(attempt) else { return .stale }
        guard attempt.structurallyComplete else { return .incomplete }
        guard let review = reviews.last(where: { $0.attemptID == attempt.id }) else { return .awaitingReview }
        return review.decision == .approve ? .accepted : .rejected
    }
    /// The expected requirement list comes from the caller's frozen contract, preventing a shortened decoded list from passing.
    public func assemble(expectedRequiredSectionIDs: [String], qualityGate: SectionHostQualityGate? = nil,
                         validateHostGate: ((SectionHostQualityGate, Data) throws -> Bool)? = nil) throws -> SectionAssembly {
        try validate()
        guard expectedRequiredSectionIDs == requiredSectionIDs else { throw SectionWorkflowError.invalid("Required sections changed") }
        var bodies: [String] = []
        for id in requiredSectionIDs {
            guard try state(for: id) == .accepted, let attempt = attempts.last(where: { $0.sectionID == id }) else {
                throw SectionWorkflowError.invalid("Missing current accepted section: \(id)")
            }
            bodies.append(attempt.body)
        }
        let bytes = Data(bodies.joined(separator: "\n\n").utf8)
        if let gate = qualityGate, let validateHostGate,
           gate.caseID == caseID, gate.contractHash == contractHash, gate.documentHash == Self.hash(bytes),
           Self.meaningful(gate.reviewer), Self.validEvidence(gate.evidence), try validateHostGate(gate, bytes) {
            return SectionAssembly(bytes: bytes, status: .hostReviewed, qualityGate: gate)
        }
        return SectionAssembly(bytes: bytes)
    }
    private enum CodingKeys: String, CodingKey { case caseID, requiredSectionIDs, contractHash, sources, attempts, reviews }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        caseID = try c.decode(String.self, forKey: .caseID)
        requiredSectionIDs = try c.decode([String].self, forKey: .requiredSectionIDs)
        contractHash = try c.decode(String.self, forKey: .contractHash)
        sources = try c.decode([SectionSource].self, forKey: .sources)
        attempts = try c.decode([SectionGenerationAttempt].self, forKey: .attempts)
        reviews = try c.decode([SectionHumanReview].self, forKey: .reviews)
        try validate()
    }
}

extension SectionSource: Hashable {}
