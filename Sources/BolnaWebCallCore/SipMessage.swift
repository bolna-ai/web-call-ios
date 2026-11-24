import Foundation

/// One SIP request or response as carried in a WebSocket text frame (RFC 7118).
public struct SipMessage: Equatable {
    public var startLine: String
    public var headers: [(name: String, value: String)]
    public var body: String

    public init(startLine: String, headers: [(name: String, value: String)] = [], body: String = "") {
        self.startLine = startLine
        self.headers = headers
        self.body = body
    }

    public static func == (a: SipMessage, b: SipMessage) -> Bool {
        a.serialize() == b.serialize()
    }

    private static let compactForms: [String: String] = [
        "i": "call-id", "f": "from", "t": "to", "v": "via", "m": "contact",
        "l": "content-length", "c": "content-type", "k": "supported",
    ]

    private static func canonical(_ name: String) -> String {
        let lower = name.lowercased()
        return compactForms[lower] ?? lower
    }

    public var isResponse: Bool { startLine.hasPrefix("SIP/2.0 ") }

    public var statusCode: Int? {
        guard isResponse else { return nil }
        let parts = startLine.split(separator: " ")
        return parts.count > 1 ? Int(parts[1]) : nil
    }

    /// Request method, or for a response the method from its CSeq.
    public var method: String? {
        if isResponse { return cseq?.method }
        return startLine.split(separator: " ").first.map(String.init)
    }

    public var cseq: (number: Int, method: String)? {
        guard let value = header("CSeq") else { return nil }
        let parts = value.split(separator: " ")
        guard parts.count == 2, let n = Int(parts[0]) else { return nil }
        return (n, String(parts[1]))
    }

    public func header(_ name: String) -> String? {
        allHeaders(name).first
    }

    /// Every value for a header, splitting comma-joined lists for headers that allow it.
    public func allHeaders(_ name: String) -> [String] {
        let key = Self.canonical(name)
        let values = headers.filter { Self.canonical($0.name) == key }.map(\.value)
        guard ["via", "record-route", "route"].contains(key) else { return values }
        return values.flatMap(Self.splitList)
    }

    private static func splitList(_ value: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quoted = false
        for ch in value {
            switch ch {
            case "\"": quoted.toggle()
            case "<" where !quoted: depth += 1
            case ">" where !quoted: depth -= 1
            case "," where !quoted && depth == 0:
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            default: break
            }
            current.append(ch)
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { parts.append(last) }
        return parts
    }

    /// `tag` parameter of a From/To header value.
    public static func tag(of value: String) -> String? {
        parameter("tag", of: value)
    }

    public static func parameter(_ name: String, of value: String) -> String? {
        let afterURI = value.range(of: ">").map { String(value[$0.upperBound...]) } ?? value
        for part in afterURI.split(separator: ";", omittingEmptySubsequences: false).dropFirst() {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.first?.trimmingCharacters(in: .whitespaces).lowercased() == name.lowercased() {
                return kv.count > 1 ? String(kv[1]).trimmingCharacters(in: .whitespaces) : ""
            }
        }
        return nil
    }

    /// The URI inside `<...>`, or the bare value up to the first `;`.
    public static func uri(of value: String) -> String {
        if let open = value.firstIndex(of: "<"), let close = value.firstIndex(of: ">"), open < close {
            return String(value[value.index(after: open)..<close])
        }
        return String(value.split(separator: ";").first ?? Substring(value))
            .trimmingCharacters(in: .whitespaces)
    }

    public static func parse(_ raw: String) -> SipMessage? {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let sections = normalized.components(separatedBy: "\n\n")
        guard let head = sections.first else { return nil }
        var lines = head.components(separatedBy: "\n")
        guard !lines.isEmpty else { return nil }
        let startLine = lines.removeFirst()
        guard startLine.hasPrefix("SIP/2.0 ") || startLine.hasSuffix(" SIP/2.0") else { return nil }

        var headers: [(String, String)] = []
        for line in lines where !line.isEmpty {
            if line.first == " " || line.first == "\t", let last = headers.popLast() {
                headers.append((last.0, last.1 + " " + line.trimmingCharacters(in: .whitespaces)))
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }
        let body = sections.dropFirst().joined(separator: "\n\n")
        return SipMessage(
            startLine: startLine,
            headers: headers,
            body: body.replacingOccurrences(of: "\n", with: "\r\n")
        )
    }

    public func serialize() -> String {
        var out = startLine + "\r\n"
        for (name, value) in headers where Self.canonical(name) != "content-length" {
            out += "\(name): \(value)\r\n"
        }
        out += "Content-Length: \(body.utf8.count)\r\n\r\n"
        out += body
        return out
    }
}
