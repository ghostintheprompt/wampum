import Foundation

/// Scope-gated invocation of recon tools (nmap, ffuf). The security-critical part is that a
/// recon run only ever points at an operator-declared, in-scope target — authorized against
/// the case `AuthorizedScope` before the command is built, fail-closed. Like Docker control it
/// is open within the rules of engagement (operator reviews the exact command) and runs as a
/// direct owned process; the gate, the review and the receipt are the controls.
public enum ReconControl {
    public enum Tool: String, Sendable { case nmap, ffuf }

    public struct Plan {
        public let executable: URL
        public let arguments: [String]
        public let receipt: ToolReceipt
    }

    public static func detect(_ tool: Tool) -> URL? {
        for base in ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"] {
            let p = base + tool.rawValue
            if FileManager.default.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }

    public static func plan(tool: Tool, executable: URL, target: String, extraArgs: [String], scope: AuthorizedScope) throws -> Plan {
        for a in extraArgs where a.contains("\0") || a.contains("\n") { throw WorkbenchError.invalid("Recon argument contains a control character.") }
        let host: String
        var argv: [String]
        switch tool {
        case .nmap:
            // Target is a bare host/IP; authorize it, then nmap <args> <host>.
            guard let authorized = try ToolScopeGate.authorize(targets: [target], scope: scope).first else {
                throw WorkbenchError.invalid("No target authorized.")
            }
            host = authorized
            argv = extraArgs + [host]
        case .ffuf:
            // Target is a URL containing the FUZZ keyword; authorize its host.
            guard let url = URL(string: target), let h = url.host, !h.isEmpty, url.scheme == "http" || url.scheme == "https" else {
                throw WorkbenchError.invalid("ffuf target must be an HTTP(S) URL (with a FUZZ keyword).")
            }
            guard target.contains("FUZZ") else { throw WorkbenchError.invalid("ffuf target must contain the FUZZ keyword.") }
            _ = try scope.authorize(url)
            host = h
            argv = ["-u", target] + extraArgs
        }
        let plan = try CommandPlan.ownedTool(executable: executable, arguments: argv)
        let receipt = ToolReceipt(tool: tool.rawValue, action: tool == .nmap ? "scan" : "fuzz", targets: [host],
                                  argument: ([executable.path] + argv).joined(separator: " "),
                                  detail: "Scope-gated recon against \(host). Open within RoE; operator-reviewed.")
        return Plan(executable: plan.executable, arguments: plan.arguments, receipt: receipt)
    }
}

/// One path ffuf discovered: a lead (a reachable path), verified for impact before promotion.
public struct FfufResult: Codable, Equatable, Sendable {
    public let url: String
    public let status: Int
    public let length: Int
    public let input: String
}

/// Parses `ffuf -o out.json` output into discovered-path leads.
public enum FfufImport {
    public static func results(from data: Data) throws -> [FfufResult] {
        guard data.count <= 33_554_432 else { throw WorkbenchError.invalid("ffuf output exceeds 32 MB.") }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw WorkbenchError.invalid("Not valid JSON. Use: ffuf -o out.json")
        }
        guard let results = root["results"] as? [[String: Any]] else {
            throw WorkbenchError.invalid("No results array (is this ffuf -o JSON output?).")
        }
        return results.compactMap { r in
            guard let url = r["url"] as? String else { return nil }
            let status = (r["status"] as? Int) ?? 0
            let length = (r["length"] as? Int) ?? 0
            var input = ""
            if let inputObj = r["input"] as? [String: Any] { input = (inputObj["FUZZ"] as? String) ?? (inputObj.values.first as? String) ?? "" }
            return FfufResult(url: url, status: status, length: length, input: input)
        }
    }
}

/// One service nmap observed on a host: a lead (a reachable service), whose impact is
/// verified and captured before it can back a Finding.
public struct NmapResult: Codable, Equatable, Sendable {
    public let host: String      // hostname when known, else the address
    public let address: String
    public let port: Int
    public let proto: String
    public let state: String
    public let service: String
    public let product: String
    public let osGuess: String   // host-level OS match (-O), "" if none / not XML
    public let scriptOutput: String  // NSE port-script output (--script), "" if none
    public init(host: String, address: String, port: Int, proto: String, state: String, service: String, product: String, osGuess: String = "", scriptOutput: String = "") {
        self.host = host; self.address = address; self.port = port; self.proto = proto
        self.state = state; self.service = service; self.product = product
        self.osGuess = osGuess; self.scriptOutput = scriptOutput
    }
}

/// Parses nmap XML (`-oX`) or greppable (`-oG`) output into service leads. The format is
/// sniffed from the first non-whitespace byte ('<' means XML), so either -o flag works.
public enum NmapImport {
    public static func results(from data: Data) throws -> [NmapResult] {
        guard data.count <= 33_554_432 else { throw WorkbenchError.invalid("nmap output exceeds 32 MB.") }
        let firstByte = data.first(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0a && $0 != 0x0d })
        if firstByte == UInt8(ascii: "<") { return try parseXML(data) }
        return try parseGreppable(data)
    }

    private static func parseXML(_ data: Data) throws -> [NmapResult] {
        let parser = XMLParser(data: data)
        // Client tools parse untrusted scanner output: never resolve external entities (XXE) or
        // fetch DTDs. These are the safe defaults, set explicitly so a refactor can't drop them.
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        let delegate = NmapXMLDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw WorkbenchError.invalid("Not valid nmap XML (-oX). " + (parser.parserError?.localizedDescription ?? ""))
        }
        guard delegate.sawHost else { throw WorkbenchError.invalid("No hosts found (is this nmap -oX XML output?).") }
        return delegate.results
    }

    private static func parseGreppable(_ data: Data) throws -> [NmapResult] {
        guard let text = String(data: data, encoding: .utf8) else { throw WorkbenchError.invalid("nmap greppable output is not UTF-8.") }
        var out: [NmapResult] = []
        var sawHost = false
        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine)
            guard line.hasPrefix("Host:") else { continue }
            sawHost = true
            let fields = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            var address = "", hostname = ""
            if let hostField = fields.first(where: { $0.hasPrefix("Host:") }) {
                let rest = hostField.dropFirst("Host:".count).trimmingCharacters(in: .whitespaces)
                if let paren = rest.firstIndex(of: "(") {
                    address = rest[..<paren].trimmingCharacters(in: .whitespaces)
                    hostname = String(rest[rest.index(after: paren)...].prefix(while: { $0 != ")" }))
                } else { address = rest }
            }
            guard let portsField = fields.first(where: { $0.hasPrefix("Ports:") }) else { continue }
            let portsStr = portsField.dropFirst("Ports:".count).trimmingCharacters(in: .whitespaces)
            for token in portsStr.split(separator: ",") {
                // portid/state/proto/owner/service/rpc/version/
                let parts = token.trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count >= 3, let port = Int(parts[0]) else { continue }
                let host = hostname.isEmpty ? address : hostname
                out.append(NmapResult(host: host, address: address, port: port, proto: parts[2],
                                      state: parts[1], service: parts.count > 4 ? parts[4] : "",
                                      product: parts.count > 6 ? parts[6] : ""))
            }
        }
        guard sawHost else { throw WorkbenchError.invalid("No 'Host:' lines (is this nmap -oG greppable output?).") }
        return out
    }
}

private final class NmapXMLDelegate: NSObject, XMLParserDelegate {
    var results: [NmapResult] = []
    var sawHost = false
    private var address = "", hostname = "", osGuess = ""
    private var port = 0, proto = "", state = "", service = "", product = "", scriptOutput = ""
    private var inPort = false
    // nmap emits <os> after <ports>, so ports are buffered per host and flushed with the OS at </host>.
    private struct PendingPort { let port: Int, proto: String, state: String, service: String, product: String, scriptOutput: String }
    private var pending: [PendingPort] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "host": sawHost = true; address = ""; hostname = ""; osGuess = ""; pending = []
        case "address":
            if (attributeDict["addrtype"] ?? "").hasPrefix("ipv"), let a = attributeDict["addr"] { address = a }
        case "hostname":
            if hostname.isEmpty, let n = attributeDict["name"] { hostname = n }
        case "port":
            inPort = true
            port = Int(attributeDict["portid"] ?? "") ?? 0; proto = attributeDict["protocol"] ?? ""
            state = ""; service = ""; product = ""; scriptOutput = ""
        case "state": state = attributeDict["state"] ?? ""
        case "service": service = attributeDict["name"] ?? ""; product = attributeDict["product"] ?? ""
        case "script":
            // Only attribute port-level scripts to the port; ignore <hostscript> entries here.
            if inPort, let id = attributeDict["id"] {
                let out = (attributeDict["output"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let line = out.isEmpty ? id : "\(id): \(out)"
                scriptOutput += (scriptOutput.isEmpty ? "" : " | ") + line
            }
        case "osmatch":
            if osGuess.isEmpty, let n = attributeDict["name"] {
                let acc = attributeDict["accuracy"].map { " (\($0)%)" } ?? ""
                osGuess = n + acc
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "port":
            inPort = false
            if port > 0 { pending.append(PendingPort(port: port, proto: proto, state: state, service: service, product: product, scriptOutput: scriptOutput)) }
        case "host":
            let h = hostname.isEmpty ? address : hostname
            for p in pending {
                results.append(NmapResult(host: h, address: address, port: p.port, proto: p.proto, state: p.state,
                                          service: p.service, product: p.product, osGuess: osGuess, scriptOutput: p.scriptOutput))
            }
            pending = []
        default: break
        }
    }
}
