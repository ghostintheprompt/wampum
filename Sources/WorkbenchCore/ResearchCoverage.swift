import Foundation

/// Exact, case-bound allocation of extracted text to required output units.
/// Allocation is not proof that a request was sent, understood or substantively reviewed.
public struct ResearchWindowReference: Codable, Sendable, Equatable, Hashable {
    public let unitID: String
    public let sourcePath: String
    public let originalSHA256: String
    public let extractedSHA256: String
    public let windowIndex: Int
    public let startUTF8: Int
    public let endUTF8: Int
    public let windowSHA256: String
    public init(unitID: String, capture: ResearchSourceCapture, window: ResearchSourceWindow) {
        self.unitID = unitID; sourcePath = capture.original.canonicalPath
        originalSHA256 = capture.original.sha256; extractedSHA256 = capture.extractedTextSHA256
        windowIndex = window.index; startUTF8 = window.startUTF8; endUTF8 = window.endUTF8; windowSHA256 = window.sha256
    }
}

public struct ResearchSourceCoverage: Codable, Sendable, Equatable {
    public let sourcePath: String
    public let originalSHA256: String
    public let extractedSHA256: String
    public let selectedWindowIndices: [Int]
    public let omittedWindowIndices: [Int]
    public let selectedUTF8Bytes: Int
    public let totalExtractedUTF8Bytes: Int
    public let extractionWarnings: [String]
    public let completeTextExtraction: Bool
}

public struct ResearchSourcePlan: Codable, Sendable {
    public static let windowBytes = 2048
    public let caseID: String
    public let contractHash: String
    public var windows: [ResearchWindowReference]
    public init(contract: ResearchCaseContract, windows: [ResearchWindowReference] = []) throws {
        caseID = contract.id; contractHash = try contract.digest(); self.windows = windows
    }
    public func validate(contract: ResearchCaseContract, captures: [ResearchSourceCapture]) throws {
        guard caseID == contract.id, contractHash == (try contract.digest()), windows.count <= 4096,
              Set(windows).count == windows.count,
              Set(captures.map { $0.original.canonicalPath }).count == captures.count else {
            throw WorkbenchError.invalid("Source selection has duplicate entries, exceeds its limit or belongs to another case contract.")
        }
        let sources = Dictionary(uniqueKeysWithValues: captures.map { ($0.original.canonicalPath, $0) })
        for (path, references) in Dictionary(grouping: windows, by: \.sourcePath) {
            guard let capture = sources[path] else { throw WorkbenchError.invalid("Selection refers to an uncaptured source.") }
            let available = try capture.windows(maxUTF8Bytes: Self.windowBytes)
            for reference in references {
                guard contract.requiredUnits.contains(reference.unitID),
                      available.indices.contains(reference.windowIndex),
                      reference == ResearchWindowReference(unitID: reference.unitID, capture: capture, window: available[reference.windowIndex]) else {
                    throw WorkbenchError.invalid("Source selection is stale or its window/hash/offset/unit binding changed.")
                }
            }
        }
    }
    public mutating func setSelected(_ selected: Bool, unitID: String, capture: ResearchSourceCapture, window: ResearchSourceWindow) {
        let reference = ResearchWindowReference(unitID: unitID, capture: capture, window: window)
        windows.removeAll { $0.unitID == unitID && $0.sourcePath == reference.sourcePath && $0.windowIndex == window.index }
        if selected { windows.append(reference) }
    }
    public func coverage(contract: ResearchCaseContract, captures: [ResearchSourceCapture], unitID: String? = nil) throws -> [ResearchSourceCoverage] {
        try validate(contract: contract, captures: captures)
        if let unitID, !contract.requiredUnits.contains(unitID) { throw WorkbenchError.invalid("Unknown required unit.") }
        return try captures.map { capture in
            let available = try capture.windows(maxUTF8Bytes: Self.windowBytes)
            let included = Set(windows.filter { $0.sourcePath == capture.original.canonicalPath && (unitID == nil || $0.unitID == unitID) }.map(\.windowIndex))
            return ResearchSourceCoverage(sourcePath: capture.original.canonicalPath,
                originalSHA256: capture.original.sha256, extractedSHA256: capture.extractedTextSHA256,
                selectedWindowIndices: available.filter { included.contains($0.index) }.map(\.index),
                omittedWindowIndices: available.filter { !included.contains($0.index) }.map(\.index),
                selectedUTF8Bytes: available.filter { included.contains($0.index) }.reduce(0) { $0 + $1.text.utf8.count },
                totalExtractedUTF8Bytes: capture.extractedText.utf8.count,
                extractionWarnings: capture.warnings, completeTextExtraction: capture.fullDocumentTextCoverage)
        }
    }
    public func requestSources(contract: ResearchCaseContract, captures: [ResearchSourceCapture], unitID: String) throws -> Data {
        let reports = try coverage(contract: contract, captures: captures, unitID: unitID)
        struct Included: Encodable { let sourcePath: String; let window: ResearchSourceWindow }
        struct Packet: Encodable {
            let assurance = "Exact selected extracted-text windows only. Allocation and request inclusion are not proof of comprehension, semantic completeness or verification. Omitted windows and extraction gaps remain unresolved."
            let caseID: String; let contractHash: String; let unitID: String
            let coverage: [ResearchSourceCoverage]; let included: [Included]
        }
        var included: [Included] = []
        for capture in captures {
            let indices = Set(windows.filter { $0.unitID == unitID && $0.sourcePath == capture.original.canonicalPath }.map(\.windowIndex))
            for window in try capture.windows(maxUTF8Bytes: Self.windowBytes) where indices.contains(window.index) {
                included.append(Included(sourcePath: capture.original.canonicalPath, window: window))
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Packet(caseID: caseID, contractHash: contractHash, unitID: unitID, coverage: reports, included: included))
    }
}
