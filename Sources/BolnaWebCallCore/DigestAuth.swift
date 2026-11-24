import CryptoKit
import Foundation

/// HTTP digest (RFC 2617 / RFC 8760 MD5) for SIP 401/407 challenges.
public enum DigestAuth {
    public static func parseChallenge(_ header: String) -> [String: String] {
        var params: [String: String] = [:]
        var rest = header
        if let space = rest.firstIndex(of: " "), rest[..<space].lowercased() == "digest" {
            rest = String(rest[rest.index(after: space)...])
        }
        var key = ""
        var value = ""
        var inKey = true
        var quoted = false
        func flush() {
            let k = key.trimmingCharacters(in: .whitespaces).lowercased()
            if !k.isEmpty { params[k] = value }
            key = ""
            value = ""
            inKey = true
        }
        for ch in rest {
            if inKey {
                if ch == "=" { inKey = false } else if ch != "," { key.append(ch) }
            } else if ch == "\"" {
                quoted.toggle()
            } else if ch == "," && !quoted {
                flush()
            } else {
                value.append(ch)
            }
        }
        flush()
        return params.mapValues { $0.trimmingCharacters(in: .whitespaces) }
    }

    public static func md5(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Builds the `Authorization` / `Proxy-Authorization` header value.
    public static func authorization(
        challenge: String, method: String, uri: String, username: String, password: String,
        nonceCount: Int = 1, cnonce: String = randomToken(16)
    ) -> String? {
        let p = parseChallenge(challenge)
        guard let realm = p["realm"], let nonce = p["nonce"] else { return nil }
        let ha1 = md5("\(username):\(realm):\(password)")
        let ha2 = md5("\(method):\(uri)")
        let qopAuth = p["qop"]?.split(separator: ",").contains {
            $0.trimmingCharacters(in: .whitespaces) == "auth"
        } ?? false
        let nc = String(format: "%08x", nonceCount)
        let response = qopAuth
            ? md5("\(ha1):\(nonce):\(nc):\(cnonce):auth:\(ha2)")
            : md5("\(ha1):\(nonce):\(ha2)")
        var header = "Digest username=\"\(username)\", realm=\"\(realm)\", nonce=\"\(nonce)\", "
            + "uri=\"\(uri)\", response=\"\(response)\", algorithm=MD5"
        if qopAuth { header += ", qop=auth, nc=\(nc), cnonce=\"\(cnonce)\"" }
        if let opaque = p["opaque"] { header += ", opaque=\"\(opaque)\"" }
        return header
    }

    public static func randomToken(_ length: Int) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<length).map { _ in chars.randomElement()! })
    }
}
