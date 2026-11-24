import XCTest
@testable import BolnaWebCallCore

final class DigestAndParseTests: XCTestCase {
    func testRFC2617DigestVector() {
        let challenge = #"Digest realm="testrealm@host.com", qop="auth,auth-int", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41""#
        let header = DigestAuth.authorization(
            challenge: challenge, method: "GET", uri: "/dir/index.html",
            username: "Mufasa", password: "Circle Of Life", nonceCount: 1, cnonce: "0a4f113b"
        )!
        XCTAssertTrue(header.contains(#"response="6629fae49393a05397450978507c4ef1""#), header)
        XCTAssertTrue(header.contains("qop=auth, nc=00000001"))
        XCTAssertTrue(header.contains(#"opaque="5ccc069c403ebaf9f0171e9517f40e41""#))
    }

    func testDigestWithoutQop() {
        let header = DigestAuth.authorization(
            challenge: #"Digest realm="r", nonce="n""#, method: "INVITE", uri: "sip:7000@h",
            username: "u", password: "p"
        )!
        let expected = DigestAuth.md5("\(DigestAuth.md5("u:r:p")):n:\(DigestAuth.md5("INVITE:sip:7000@h"))")
        XCTAssertTrue(header.contains("response=\"\(expected)\""))
        XCTAssertFalse(header.contains("qop"))
    }

    func testParseResponseWithCompactHeadersAndBody() {
        let raw = "SIP/2.0 200 OK\r\nv: SIP/2.0/WSS a.invalid;branch=z9hG4bK1, SIP/2.0/WSS b.invalid;branch=z9hG4bK2\r\n"
            + "t: <sip:7000@h>;tag=abc\r\ni: call1\r\nCSeq: 2 INVITE\r\nRecord-Route: <sip:p1;lr>, <sip:p2;lr>\r\n"
            + "m: <sip:fs@1.2.3.4:5066;transport=ws>\r\nl: 9\r\n\r\nv=0\r\no=x"
        let m = SipMessage.parse(raw)!
        XCTAssertEqual(m.statusCode, 200)
        XCTAssertEqual(m.method, "INVITE")
        XCTAssertEqual(m.cseq?.number, 2)
        XCTAssertEqual(m.allHeaders("Via").count, 2)
        XCTAssertEqual(m.allHeaders("Record-Route"), ["<sip:p1;lr>", "<sip:p2;lr>"])
        XCTAssertEqual(SipMessage.tag(of: m.header("To")!), "abc")
        XCTAssertEqual(SipMessage.uri(of: m.header("Contact")!), "sip:fs@1.2.3.4:5066;transport=ws")
        XCTAssertEqual(m.body, "v=0\r\no=x")
    }

    func testSerializeSetsContentLength() {
        let s = SipMessage(startLine: "INVITE sip:7000@h SIP/2.0", headers: [("Call-ID", "x")], body: "abc").serialize()
        XCTAssertTrue(s.contains("Content-Length: 3\r\n\r\nabc"))
    }

    func testSessionDecodeAndMintErrors() throws {
        let json = #"{"run_id":"r1","agent_id":"a1","sip_username":"u","sip_password":"p","sip_domain":"d","wss_url":"wss://sip.example.com/ws","sip_register":true,"expires_in":120,"ice_servers":[{"urls":"stun:s"},{"urls":["turn:t"],"username":"x","credential":"y"}]}"#
        let s = try SessionFetcher.decode(status: 200, data: Data(json.utf8))
        XCTAssertEqual(s.runId, "r1")
        XCTAssertEqual(s.iceServers.map(\.urls), [["stun:s"], ["turn:t"]])

        XCTAssertThrowsError(try SessionFetcher.decode(status: 429, data: Data(#"{"scope":"customer"}"#.utf8))) {
            XCTAssertEqual($0 as? CallError, CallError(.atCapacity, "All lines are busy, try again shortly", scope: "customer"))
        }
        XCTAssertThrowsError(try SessionFetcher.decode(status: 500, data: Data())) {
            XCTAssertEqual(($0 as? CallError)?.code, .mintFailed)
        }
        XCTAssertThrowsError(try SessionFetcher.decode(status: 200, data: Data(#"{"agent_id":"a"}"#.utf8))) {
            XCTAssertEqual(($0 as? CallError)?.code, .mintFailed)
        }
    }
}
