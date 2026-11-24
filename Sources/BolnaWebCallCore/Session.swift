import Foundation

/// Short-lived, single-use credentials for one call, minted by your backend from
/// `POST https://api.bolna.ai/web-call/session`. Never put your `bn-` API key in the app.
public struct Session: Codable, Equatable, Sendable {
    public struct IceServer: Codable, Equatable, Sendable {
        public var urls: [String]
        public var username: String?
        public var credential: String?

        public init(urls: [String], username: String? = nil, credential: String? = nil) {
            self.urls = urls
            self.username = username
            self.credential = credential
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let single = try? c.decode(String.self, forKey: .urls) {
                urls = [single]
            } else {
                urls = try c.decode([String].self, forKey: .urls)
            }
            username = try c.decodeIfPresent(String.self, forKey: .username)
            credential = try c.decodeIfPresent(String.self, forKey: .credential)
        }
    }

    public var runId: String
    public var agentId: String
    public var sipUsername: String
    public var sipPassword: String
    public var sipDomain: String
    public var wssUrl: String
    public var sipRegister: Bool
    public var expiresIn: Int
    public var iceServers: [IceServer]

    enum CodingKeys: String, CodingKey {
        case runId = "run_id", agentId = "agent_id", sipUsername = "sip_username"
        case sipPassword = "sip_password", sipDomain = "sip_domain", wssUrl = "wss_url"
        case sipRegister = "sip_register", expiresIn = "expires_in", iceServers = "ice_servers"
    }

    public init(
        runId: String, agentId: String, sipUsername: String, sipPassword: String, sipDomain: String,
        wssUrl: String, sipRegister: Bool, expiresIn: Int, iceServers: [IceServer]
    ) {
        self.runId = runId
        self.agentId = agentId
        self.sipUsername = sipUsername
        self.sipPassword = sipPassword
        self.sipDomain = sipDomain
        self.wssUrl = wssUrl
        self.sipRegister = sipRegister
        self.expiresIn = expiresIn
        self.iceServers = iceServers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runId = try c.decode(String.self, forKey: .runId)
        agentId = try c.decodeIfPresent(String.self, forKey: .agentId) ?? ""
        sipUsername = try c.decode(String.self, forKey: .sipUsername)
        sipPassword = try c.decodeIfPresent(String.self, forKey: .sipPassword) ?? ""
        sipDomain = try c.decodeIfPresent(String.self, forKey: .sipDomain) ?? ""
        wssUrl = try c.decode(String.self, forKey: .wssUrl)
        sipRegister = try c.decodeIfPresent(Bool.self, forKey: .sipRegister) ?? false
        expiresIn = try c.decodeIfPresent(Int.self, forKey: .expiresIn) ?? 120
        iceServers = try c.decodeIfPresent([IceServer].self, forKey: .iceServers) ?? []
    }
}

public enum CallState: String, Sendable {
    case idle, connecting, ringing, active, ended
}

public enum CallEndReason: String, Sendable {
    case localHangup = "local-hangup"
    case remoteHangup = "remote-hangup"
    case failed
}

public struct CallError: Error, Equatable, Sendable {
    public enum Code: String, Sendable {
        case mintFailed = "mint_failed"
        case atCapacity = "at_capacity"
        case microphoneDenied = "microphone_denied"
        case connectFailed = "connect_failed"
        case callRejected = "call_rejected"
        case alreadyActive = "already_active"
    }

    public var code: Code
    public var message: String
    /// For `at_capacity`: `"global"` or `"customer"`.
    public var scope: String?

    public init(_ code: Code, _ message: String, scope: String? = nil) {
        self.code = code
        self.message = message
        self.scope = scope
    }
}

/// POSTs `{}` or `{"user_data": ...}` to your backend's session route and maps failures to
/// `mint_failed` / `at_capacity`, matching the browser SDK.
public enum SessionFetcher {
    public static func fetch(
        url: URL, userData: [String: Any]?, urlSession: URLSession = .shared
    ) async throws -> Session {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = userData.map { ["user_data": $0] } ?? [:]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw CallError(.mintFailed, "Could not reach the session endpoint")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try decode(status: status, data: data)
    }

    public static func decode(status: Int, data: Data) throws -> Session {
        if status == 429 {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw CallError(
                .atCapacity, "All lines are busy, try again shortly", scope: json?["scope"] as? String
            )
        }
        guard (200..<300).contains(status) else {
            throw CallError(.mintFailed, "Session endpoint returned HTTP \(status)")
        }
        guard let session = try? JSONDecoder().decode(Session.self, from: data),
              !session.runId.isEmpty, !session.wssUrl.isEmpty, !session.sipUsername.isEmpty
        else {
            throw CallError(.mintFailed, "Session endpoint returned an invalid session")
        }
        return session
    }
}
