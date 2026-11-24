import XCTest
@testable import BolnaWebCallCore

/// Drives SipCall against a scripted server: every frame it sends is parsed and inspected.
final class SipCallTests: XCTestCase {
    var sent: [SipMessage] = []
    var events: [SipCall.Event] = []

    func makeCall(register: Bool = false) -> SipCall {
        let session = Session(
            runId: "run_1", agentId: "agent_1", sipUsername: "u1", sipPassword: "pw", sipDomain: "d",
            wssUrl: "wss://sip.example.com/ws", sipRegister: register, expiresIn: 120, iceServers: []
        )
        sent = []
        events = []
        return SipCall(
            config: .init(session: session),
            send: { [unowned self] in self.sent.append(SipMessage.parse($0)!) },
            onEvent: { [unowned self] in self.events.append($0) }
        )
    }

    /// A response to `request` the way FreeSWITCH would build it.
    func reply(_ request: SipMessage, _ status: Int, _ reason: String, toTag: String? = "srv",
               extra: [(String, String)] = [], body: String = "") -> String {
        var to = request.header("To")!
        if let toTag { to += ";tag=\(toTag)" }
        var headers: [(String, String)] = request.allHeaders("Via").map { ("Via", $0) }
        headers += [("From", request.header("From")!), ("To", to),
                    ("Call-ID", request.header("Call-ID")!), ("CSeq", request.header("CSeq")!)]
        headers += extra
        return SipMessage(startLine: "SIP/2.0 \(status) \(reason)", headers: headers, body: body).serialize()
    }

    func testInviteWithProxyAuthRingingAnswerAndAck() throws {
        let call = makeCall()
        call.start(offerSdp: "v=0 offer")
        let invite1 = try XCTUnwrap(sent.last)
        XCTAssertEqual(invite1.startLine, "INVITE sip:7000@sip.example.com SIP/2.0")
        XCTAssertTrue(invite1.header("From")!.hasPrefix("<sip:run_1@sip.example.com>"))
        XCTAssertEqual(invite1.header("X-Agent-Id"), "agent_1")
        XCTAssertEqual(invite1.header("X-Run-Id"), "run_1")
        XCTAssertEqual(invite1.body, "v=0 offer")

        call.receive(reply(invite1, 407, "Proxy Authentication Required", extra: [
            ("Proxy-Authenticate", #"Digest realm="sip.example.com", nonce="abc", qop="auth""#),
        ]))
        let ack1 = sent[sent.count - 2]
        XCTAssertEqual(ack1.method, "ACK")
        XCTAssertEqual(ack1.header("Via"), invite1.header("Via"))
        let invite2 = try XCTUnwrap(sent.last)
        XCTAssertEqual(invite2.cseq?.number, 2)
        XCTAssertTrue(invite2.header("Proxy-Authorization")!.contains(#"username="u1""#))
        XCTAssertNotEqual(invite2.header("Via"), invite1.header("Via"))

        call.receive(reply(invite2, 100, "Trying", toTag: nil))
        call.receive(reply(invite2, 180, "Ringing"))
        XCTAssertEqual(events, [.ringing])

        call.receive(reply(invite2, 200, "OK", extra: [
            ("Contact", "<sip:fs@10.0.0.1:5066;transport=ws>"),
            ("Record-Route", "<sip:edge1;lr>"), ("Record-Route", "<sip:edge2;lr>"),
        ], body: "v=0 answer"))
        XCTAssertEqual(events, [.ringing, .answered(sdp: "v=0 answer")])
        XCTAssertTrue(call.isEstablished)
        let ack = try XCTUnwrap(sent.last)
        XCTAssertEqual(ack.startLine, "ACK sip:fs@10.0.0.1:5066;transport=ws SIP/2.0")
        XCTAssertEqual(ack.allHeaders("Route"), ["<sip:edge2;lr>", "<sip:edge1;lr>"])
        XCTAssertEqual(SipMessage.tag(of: ack.header("To")!), "srv")
        XCTAssertEqual(ack.cseq?.number, 2)

        call.hangup()
        let bye = try XCTUnwrap(sent.last)
        XCTAssertEqual(bye.method, "BYE")
        XCTAssertEqual(bye.cseq?.number, 3)
        XCTAssertEqual(bye.startLine, "BYE sip:fs@10.0.0.1:5066;transport=ws SIP/2.0")
    }

    func testRegisterThenInvite() throws {
        let call = makeCall(register: true)
        call.start(offerSdp: "sdp")
        let reg1 = try XCTUnwrap(sent.last)
        XCTAssertEqual(reg1.startLine, "REGISTER sip:sip.example.com SIP/2.0")
        call.receive(reply(reg1, 401, "Unauthorized", extra: [("WWW-Authenticate", #"Digest realm="r", nonce="n""#)]))
        let reg2 = try XCTUnwrap(sent.last)
        XCTAssertEqual(reg2.cseq?.number, 2)
        XCTAssertNotNil(reg2.header("Authorization"))
        call.receive(reply(reg2, 200, "OK"))
        let invite = try XCTUnwrap(sent.last)
        XCTAssertEqual(invite.method, "INVITE")
        XCTAssertTrue(invite.header("From")!.hasPrefix("<sip:u1@sip.example.com>"))
    }

    func testRegisterFailureIsConnectFailed() throws {
        let call = makeCall(register: true)
        call.start(offerSdp: "sdp")
        call.receive(reply(sent.last!, 403, "Forbidden"))
        XCTAssertEqual(events, [.failed(code: .connectFailed, status: 403)])
    }

    func testRejectedInviteIsAckedAndReported() throws {
        let call = makeCall()
        call.start(offerSdp: "sdp")
        call.receive(reply(sent.last!, 486, "Busy Here"))
        XCTAssertEqual(sent.last?.method, "ACK")
        XCTAssertEqual(events, [.failed(code: .callRejected, status: 486)])
    }

    func testRemoteByeIsAnsweredAndReported() throws {
        let call = makeCall()
        call.start(offerSdp: "sdp")
        call.receive(reply(sent.last!, 200, "OK", extra: [("Contact", "<sip:fs@h>")], body: "ans"))
        let bye = SipMessage(startLine: "BYE sip:run_1@x.invalid;transport=ws SIP/2.0", headers: [
            ("Via", "SIP/2.0/WSS 10.0.0.1;branch=z9hG4bKsrv"), ("From", "<sip:7000@h>;tag=srv"),
            ("To", "<sip:run_1@h>;tag=mine"), ("Call-ID", sent.last!.header("Call-ID")!), ("CSeq", "10 BYE"),
        ]).serialize()
        call.receive(bye)
        XCTAssertEqual(sent.last?.startLine, "SIP/2.0 200 OK")
        XCTAssertEqual(sent.last?.header("CSeq"), "10 BYE")
        XCTAssertEqual(events.last, .remoteHangup)
        XCTAssertFalse(call.isEstablished)
    }

    func testHangupWhileRingingSendsCancel() throws {
        let call = makeCall()
        call.start(offerSdp: "sdp")
        let invite = sent.last!
        call.receive(reply(invite, 180, "Ringing"))
        call.hangup()
        let cancel = try XCTUnwrap(sent.last)
        XCTAssertEqual(cancel.method, "CANCEL")
        XCTAssertEqual(cancel.header("Via"), invite.header("Via"))
        XCTAssertEqual(cancel.cseq?.number, invite.cseq?.number)
        call.receive(reply(invite, 487, "Request Terminated"))
        XCTAssertEqual(sent.last?.method, "ACK")
        XCTAssertEqual(events, [.ringing])
    }

    func testHangupBeforeProvisionalDefersCancel() throws {
        let call = makeCall()
        call.start(offerSdp: "sdp")
        let invite = sent.last!
        call.hangup()
        XCTAssertEqual(sent.count, 1)
        call.receive(reply(invite, 183, "Session Progress"))
        XCTAssertEqual(sent.last?.method, "CANCEL")
        XCTAssertEqual(events, [])
    }

    func testHangupAfterTryingSendsCancel() throws {
        let call = makeCall()
        call.start(offerSdp: "sdp")
        call.receive(reply(sent.last!, 100, "Trying", toTag: nil))
        call.hangup()
        XCTAssertEqual(sent.last?.method, "CANCEL")
    }

    func testFreshNonceRestartsNonceCount() throws {
        let call = makeCall(register: true)
        call.start(offerSdp: "sdp")
        call.receive(reply(sent.last!, 401, "Unauthorized", extra: [
            ("WWW-Authenticate", #"Digest realm="r", nonce="n1", qop="auth""#),
        ]))
        call.receive(reply(sent.last!, 200, "OK"))
        call.receive(reply(sent.last!, 407, "Proxy Authentication Required", extra: [
            ("Proxy-Authenticate", #"Digest realm="r", nonce="n2", qop="auth""#),
        ]))
        let invite2 = try XCTUnwrap(sent.last)
        XCTAssertTrue(invite2.header("Proxy-Authorization")!.contains("nc=00000001"))
    }

    func testAnswerAfterLocalHangupIsAckedThenByed() throws {
        let call = makeCall()
        call.start(offerSdp: "sdp")
        let invite = sent.last!
        call.receive(reply(invite, 180, "Ringing"))
        call.hangup()
        call.receive(reply(invite, 200, "OK", extra: [("Contact", "<sip:fs@h>")], body: "ans"))
        XCTAssertEqual(sent.suffix(2).map(\.method), ["ACK", "BYE"])
        XCTAssertEqual(events, [.ringing])
    }

    func testOptionsKeepaliveIsAnswered() {
        let call = makeCall()
        call.start(offerSdp: "sdp")
        call.receive(SipMessage(startLine: "OPTIONS sip:run_1@x SIP/2.0", headers: [
            ("Via", "SIP/2.0/WSS 1.1.1.1;branch=z9hG4bKo"), ("From", "<sip:fs@h>;tag=f"),
            ("To", "<sip:run_1@h>"), ("Call-ID", "o1"), ("CSeq", "1 OPTIONS"),
        ]).serialize())
        XCTAssertEqual(sent.last?.startLine, "SIP/2.0 200 OK")
        XCTAssertNotNil(SipMessage.tag(of: sent.last!.header("To")!))
    }
}
