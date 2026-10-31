import Foundation

/// One API operation extracted from an OpenAPI/Swagger spec. An operation that takes an
/// object identifier in its path is a candidate for object-ownership (BOLA/IDOR) testing —
/// the exact thing a matched identity comparison (`ResponseComparison`) is for.
public struct APIOperation: Codable, Equatable, Sendable {
    public let method: String        // uppercased: GET, POST, PUT, PATCH, DELETE
    public let path: String          // /users/{id}/orders
    public let operationId: String?
    public let pathParams: [String]  // ["id"]
    public var objectOwnershipCandidate: Bool { !pathParams.isEmpty }
}

/// Reads routes and operations from an OpenAPI 3 (or Swagger 2) JSON spec so they can be
/// organized into an identity test matrix. It only parses structure — it fetches nothing and
/// decides nothing about access; the operator still declares identities and authorization,
/// and results go through the usual evidence → Finding path.
public enum OpenAPIImport {
    private static let methods = ["get", "put", "post", "delete", "patch", "options", "head"]

    public static func operations(from data: Data) throws -> [APIOperation] {
        guard data.count <= 8_388_608 else { throw WorkbenchError.invalid("Spec exceeds 8 MB; trim it first.") }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw WorkbenchError.invalid("Spec is not valid JSON (convert YAML to JSON first).")
        }
        guard root["openapi"] != nil || root["swagger"] != nil else {
            throw WorkbenchError.invalid("Not an OpenAPI/Swagger document (no openapi/swagger version field).")
        }
        guard let paths = root["paths"] as? [String: Any] else {
            throw WorkbenchError.invalid("Spec has no paths object.")
        }
        var operations: [APIOperation] = []
        for (path, value) in paths {
            guard let item = value as? [String: Any] else { continue }
            let params = pathParameters(in: path)
            for method in methods {
                guard let op = item[method] as? [String: Any] else { continue }
                operations.append(APIOperation(method: method.uppercased(), path: path,
                                               operationId: op["operationId"] as? String, pathParams: params))
            }
        }
        // Stable order: by path, then method.
        return operations.sorted { ($0.path, $0.method) < ($1.path, $1.method) }
    }

    /// Extract {name} path-template parameters.
    static func pathParameters(in path: String) -> [String] {
        var params: [String] = []
        var current = ""
        var inside = false
        for ch in path {
            if ch == "{" { inside = true; current = "" }
            else if ch == "}" { if inside, !current.isEmpty { params.append(current) }; inside = false }
            else if inside { current.append(ch) }
        }
        return params
    }
}
