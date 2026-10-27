import Foundation

/// Each tab retains its own last-read baseline so Save can detect outside edits.
public struct EditorDocument: Codable, Equatable, Identifiable {
    public var path: String
    public var draft: String
    public var original: String?
    public var id: String { path }
    public var dirty: Bool { draft != original }
    public init(path: String, draft: String, original: String?) {
        self.path = path; self.draft = draft; self.original = original
    }
}

public extension Session {
    /// The legacy active-file fields remain authoritative for bindings and older sessions.
    var editorDocuments: [EditorDocument] {
        var documents = editorTabs ?? []
        guard !file.isEmpty else { return documents }
        let active = EditorDocument(path: file, draft: draft, original: original)
        if let index = documents.firstIndex(where: { $0.path == file }) { documents[index] = active }
        else { documents.append(active) }
        return documents
    }
    var persistableEditorSession: Session {
        var saved = self
        saved.editorTabs = editorDocuments
        return saved
    }
    func selectingEditor(_ document: EditorDocument) -> Session {
        var target = persistableEditorSession
        target.file = document.path; target.draft = document.draft; target.original = document.original
        return target
    }
}
