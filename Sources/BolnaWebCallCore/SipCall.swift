import Foundation

/// Signalling for one Bolna web call: optional REGISTER, INVITE to the agent extension with
/// digest auth, ACK, CANCEL, BYE and answering in-dialog requests. Transport- and media-agnostic:
/// feed it received WebSocket frames with `receive(_:)`, it writes frames through `send`.
/// Not thread-safe; call it from one serial queue.
public final class SipCall {
    public struct Config: Equatable {
        public var host: String
        /// User part of our SIP URI: `sip_username` when registering, else the run id.
        public var uriUser: String
        public var authUsername: String
        public var password: String
        public var agentId: String
        public var runId: String
        public var register: Bool
        public var dialExtension: String
        public var userAgent: String

        public init(session: Session, userAgent: String = "BolnaWebCall") {
            host = URL(string: session.wssUrl)?.host ?? session.sipDomain
            uriUser = session.sipRegister ? session.sipUsername : session.runId
            authUsername = session.sipUsername
            password = session.sipPassword
            agentId = session.agentId
            runId = session.runId
            register = session.sipRegister
            dialExtension = "7000"
            self.userAgent = userAgent
        }
    }

    public enum Event: Equatable {
        /// 1xx with a To tag or 180/183: the agent leg is ringing.
        case ringing
        /// 2xx to INVITE; `sdp` is the answer to apply to the peer connection.
        case answered(sdp: String)
        /// The call could not be set up. `status` is the SIP final response code, if any.
        case failed(code: CallError.Code, status: Int?)
        /// Server hung up an established call.
        case remoteHangup
    }

    private enum Phase { case idle, registering, inviting, early, confirmed, terminated }

    public let config: Config
    public var send: (String) -> Void
    public var onEvent: (Event) -> Void

    private var phase: Phase = .idle
    private let viaHost = DigestAuth.randomToken(12) + ".invalid"
    private let localTag = DigestAuth.randomToken(10)
    private let callId = DigestAuth.randomToken(22)
    private let registerCallId = DigestAuth.randomToken(22)
    private var registerCSeq = 0
    private var registerAuthTried = false
    private var offerSdp = ""
    private var inviteCSeq = 0
    private var inviteBranch = ""
    private var inviteAuthHeader: (name: String, value: String)?
    private var inviteAuthTried = false
    private var remoteTag: String?
    private var remoteTarget: String?
    private var routeSet: [String] = []
    private var lastAck: String?
    private var cancelPending = false
    private var nonceCount = 0

    public init(config: Config, send: @escaping (String) -> Void = { _ in }, onEvent: @escaping (Event) -> Void = { _ in }) {
        self.config = config
        self.send = send
        self.onEvent = onEvent
    }

    public var isEstablished: Bool { phase == .confirmed }

    private var localURI: String { "sip:\(config.uriUser)@\(config.host)" }
    private var targetURI: String { "sip:\(config.dialExtension)@\(config.host)" }
    private var contact: String { "<sip:\(config.uriUser)@\(viaHost);transport=ws>" }

    private func via(_ branch: String) -> String { "SIP/2.0/WSS \(viaHost);branch=\(branch);rport" }
    private func newBranch() -> String { "z9hG4bK" + DigestAuth.randomToken(16) }

    // MARK: - outgoing

    /// Starts signalling with our SDP offer (ICE candidates already gathered: non-trickle).
    public func start(offerSdp: String) {
        guard phase == .idle else { return }
        self.offerSdp = offerSdp
        if config.register {
            phase = .registering
            sendRegister(auth: nil)
        } else {
            sendInvite()
        }
    }

    /// Ends the call from our side: BYE when established, CANCEL while ringing.
    public func hangup() {
        switch phase {
        case .confirmed:
            sendBye()
            phase = .terminated
        case .early:
            sendCancel()
            phase = .terminated
        case .inviting:
            // a CANCEL is only valid once a provisional response has arrived
            cancelPending = true
        case .idle, .registering:
            phase = .terminated
        case .terminated:
            break
        }
    }

    private func sendRegister(auth: (name: String, value: String)?) {
        registerCSeq += 1
        let uri = "sip:\(config.host)"
        var headers: [(String, String)] = [
            ("Via", via(newBranch())),
            ("Max-Forwards", "70"),
            ("To", "<\(localURI)>"),
            ("From", "<\(localURI)>;tag=\(localTag)"),
            ("Call-ID", registerCallId),
            ("CSeq", "\(registerCSeq) REGISTER"),
            ("Contact", contact),
            ("Expires", "600"),
            ("User-Agent", config.userAgent),
        ]
        if let auth { headers.append(auth) }
        send(SipMessage(startLine: "REGISTER \(uri) SIP/2.0", headers: headers).serialize())
    }

    private func sendInvite() {
        phase = .inviting
        inviteCSeq += 1
        inviteBranch = newBranch()
        var headers: [(String, String)] = [
            ("Via", via(inviteBranch)),
            ("Max-Forwards", "70"),
            ("To", "<\(targetURI)>"),
            ("From", "<\(localURI)>;tag=\(localTag)"),
            ("Call-ID", callId),
            ("CSeq", "\(inviteCSeq) INVITE"),
            ("Contact", contact),
            ("Allow", "INVITE,ACK,CANCEL,BYE,OPTIONS,INFO,NOTIFY"),
            ("User-Agent", config.userAgent),
            ("X-Agent-Id", config.agentId),
            ("X-Run-Id", config.runId),
            ("Content-Type", "application/sdp"),
        ]
        if let inviteAuthHeader { headers.append(inviteAuthHeader) }
        send(SipMessage(startLine: "INVITE \(targetURI) SIP/2.0", headers: headers, body: offerSdp).serialize())
    }

    private func sendCancel() {
        let headers: [(String, String)] = [
            ("Via", via(inviteBranch)),
            ("Max-Forwards", "70"),
            ("To", "<\(targetURI)>"),
            ("From", "<\(localURI)>;tag=\(localTag)"),
            ("Call-ID", callId),
            ("CSeq", "\(inviteCSeq) CANCEL"),
            ("User-Agent", config.userAgent),
        ]
        send(SipMessage(startLine: "CANCEL \(targetURI) SIP/2.0", headers: headers).serialize())
    }

    private func inDialogHeaders(method: String, cseq: Int, branch: String) -> [(String, String)] {
        var headers: [(String, String)] = [("Via", via(branch)), ("Max-Forwards", "70")]
        headers += routeSet.map { ("Route", $0) }
        headers += [
            ("To", "<\(targetURI)>;tag=\(remoteTag ?? "")"),
            ("From", "<\(localURI)>;tag=\(localTag)"),
            ("Call-ID", callId),
            ("CSeq", "\(cseq) \(method)"),
            ("User-Agent", config.userAgent),
        ]
        return headers
    }

    private func sendAck2xx() {
        let target = remoteTarget ?? targetURI
        let ack = SipMessage(
            startLine: "ACK \(target) SIP/2.0",
            headers: inDialogHeaders(method: "ACK", cseq: inviteCSeq, branch: newBranch())
        ).serialize()
        lastAck = ack
        send(ack)
    }

    private func sendBye() {
        inviteCSeq += 1
        let target = remoteTarget ?? targetURI
        send(SipMessage(
            startLine: "BYE \(target) SIP/2.0",
            headers: inDialogHeaders(method: "BYE", cseq: inviteCSeq, branch: newBranch())
        ).serialize())
    }

    /// ACK for a non-2xx final response: same branch as the INVITE, To copied from the response.
    private func sendAckNon2xx(_ response: SipMessage) {
        let headers: [(String, String)] = [
            ("Via", via(inviteBranch)),
            ("Max-Forwards", "70"),
            ("To", response.header("To") ?? "<\(targetURI)>"),
            ("From", "<\(localURI)>;tag=\(localTag)"),
            ("Call-ID", callId),
            ("CSeq", "\(response.cseq?.number ?? inviteCSeq) ACK"),
        ]
        send(SipMessage(startLine: "ACK \(targetURI) SIP/2.0", headers: headers).serialize())
    }

    private func authHeader(for response: SipMessage, method: String, uri: String) -> (name: String, value: String)? {
        let proxy = response.statusCode == 407
        guard let challenge = response.header(proxy ? "Proxy-Authenticate" : "WWW-Authenticate") else { return nil }
        nonceCount += 1
        guard let value = DigestAuth.authorization(
            challenge: challenge, method: method, uri: uri,
            username: config.authUsername, password: config.password, nonceCount: nonceCount
        ) else { return nil }
        return (proxy ? "Proxy-Authorization" : "Authorization", value)
    }

    // MARK: - incoming

    public func receive(_ raw: String) {
        guard let message = SipMessage.parse(raw) else { return }
        if message.isResponse {
            handleResponse(message)
        } else {
            handleRequest(message)
        }
    }

    private func handleResponse(_ r: SipMessage) {
        guard let status = r.statusCode, let cseq = r.cseq else { return }
        switch cseq.method {
        case "REGISTER":
            guard phase == .registering, r.header("Call-ID") == registerCallId else { return }
            if (status == 401 || status == 407) && !registerAuthTried,
               let auth = authHeader(for: r, method: "REGISTER", uri: "sip:\(config.host)") {
                registerAuthTried = true
                sendRegister(auth: auth)
            } else if (200..<300).contains(status) {
                sendInvite()
            } else if status >= 200 {
                phase = .terminated
                onEvent(.failed(code: .connectFailed, status: status))
            }
        case "INVITE":
            guard r.header("Call-ID") == callId else { return }
            handleInviteResponse(r, status: status)
        default:
            break
        }
    }

    private func handleInviteResponse(_ r: SipMessage, status: Int) {
        switch status {
        case 100:
            return
        case 101..<200:
            guard phase == .inviting || phase == .early else { return }
            let wasInviting = phase == .inviting
            phase = .early
            if cancelPending {
                sendCancel()
                phase = .terminated
                return
            }
            if wasInviting { onEvent(.ringing) }
        case 200..<300:
            if phase == .confirmed || (phase == .terminated && remoteTag != nil) {
                if let lastAck { send(lastAck) } // retransmitted 200 OK
                return
            }
            remoteTag = r.header("To").flatMap(SipMessage.tag(of:))
            remoteTarget = r.header("Contact").map(SipMessage.uri(of:))
            routeSet = r.allHeaders("Record-Route").reversed()
            sendAck2xx()
            if phase == .terminated || cancelPending {
                // hung up locally while the answer was in flight
                sendBye()
                phase = .terminated
                return
            }
            phase = .confirmed
            onEvent(.answered(sdp: r.body))
        default:
            guard phase == .inviting || phase == .early || phase == .terminated else { return }
            sendAckNon2xx(r)
            if phase == .terminated { return } // final response to our CANCEL
            if (status == 401 || status == 407) && !inviteAuthTried,
               let auth = authHeader(for: r, method: "INVITE", uri: targetURI) {
                inviteAuthTried = true
                inviteAuthHeader = auth
                sendInvite()
                return
            }
            phase = .terminated
            onEvent(.failed(code: .callRejected, status: status))
        }
    }

    private func handleRequest(_ q: SipMessage) {
        guard let method = q.method else { return }
        switch method {
        case "ACK":
            return
        case "BYE":
            respond(to: q, status: 200, reason: "OK")
            if phase == .confirmed {
                phase = .terminated
                onEvent(.remoteHangup)
            }
        case "INVITE":
            // session refresh re-INVITE: keep the current media, answer with our original SDP
            if phase == .confirmed {
                respond(to: q, status: 200, reason: "OK", body: offerSdp, contentType: "application/sdp")
            } else {
                respond(to: q, status: 486, reason: "Busy Here")
            }
        default:
            respond(to: q, status: 200, reason: "OK")
        }
    }

    private func respond(to q: SipMessage, status: Int, reason: String, body: String = "", contentType: String? = nil) {
        var headers: [(String, String)] = q.allHeaders("Via").map { ("Via", $0) }
        headers += q.allHeaders("Record-Route").map { ("Record-Route", $0) }
        var to = q.header("To") ?? ""
        if SipMessage.tag(of: to) == nil { to += ";tag=\(localTag)" }
        headers += [
            ("To", to),
            ("From", q.header("From") ?? ""),
            ("Call-ID", q.header("Call-ID") ?? ""),
            ("CSeq", q.header("CSeq") ?? ""),
            ("User-Agent", config.userAgent),
        ]
        if !body.isEmpty {
            headers.append(("Contact", contact))
            if let contentType { headers.append(("Content-Type", contentType)) }
        }
        send(SipMessage(startLine: "SIP/2.0 \(status) \(reason)", headers: headers, body: body).serialize())
    }
}
