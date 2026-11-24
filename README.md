# BolnaWebCall for iOS

Live AI voice calls with your [Bolna](https://bolna.ai) agent from a native Swift app, over WebRTC.
Same flow, session route and events as the browser SDK [`@bolna/web-call`](https://github.com/bolna-ai/web-call).

- Media: Google WebRTC via [`stasel/WebRTC`](https://github.com/stasel/WebRTC).
- Signalling: a small built-in SIP-over-WebSocket client (`BolnaWebCallCore`). No GPL SIP stack.
- iOS 15+ (macOS 12+ also builds).

## Install

Swift Package Manager: in Xcode, **File → Add Package Dependencies…** and enter
`https://github.com/bolna-ai/web-call-ios`. Or in `Package.swift`:

```swift
.package(url: "https://github.com/bolna-ai/web-call-ios.git", from: "0.1.0")
```

Then add `NSMicrophoneUsageDescription` to `Info.plist`. To keep calls running in the
background, enable the *Audio, AirPlay and Picture in Picture* background mode.

## Quick start

```swift
import BolnaWebCall

let call = BolnaWebCall(
    source: .url(URL(string: "https://your-backend.example.com/api/bolna-session")!),
    userData: ["name": "Ada"]
)
call.onStateChange = { state in print(state) }   // connecting → ringing → active → ended
call.onError = { error in print(error.code, error.message) }
call.onCallEnd = { reason in print(reason) }
call.onVolumeLevel = { level in /* drive a meter */ }

try await call.start()
call.setMuted(true)
await call.stop()
```

## The security model

The app never holds your Bolna API key. Your backend exposes one route that forwards to
`POST https://api.bolna.ai/web-call/session` with your `bn-` key and returns the short-lived,
single-use session JSON. Copy-paste versions for Node, Python, Go, Java, PHP, Ruby and C# are in
[`bolna-ai/web-call/example/backends`](https://github.com/bolna-ai/web-call/tree/main/example/backends).
Add your own app-user authentication to that route.

## API

| | |
|---|---|
| `BolnaWebCall(source:userData:iceTransportPolicy:)` | `source`: `.url(URL)`, `.provider { try await ... }` or `.session(Session)` (single-use). `iceTransportPolicy: .relay` forces TURN |
| `start(userData:) async throws` | Mint → mic permission → connect. Returns when the agent answers |
| `stop() async` | Hang up and release everything. Idempotent |
| `setMuted(_:)`, `isMuted` | Mute the mic without ending the call |
| `state` | `.idle`, `.connecting`, `.ringing`, `.active`, `.ended` |
| `runId` | The call's execution id (matches call history and webhooks) |

Callbacks (main queue): `onStateChange`, `onMediaPermission`, `onCallStart`, `onCallEnd`
(`.localHangup`, `.remoteHangup`, `.failed`), `onError`, `onVolumeLevel` (0...1, ~10×/sec).

`CallError.Code`: `mint_failed`, `at_capacity` (with `scope`), `microphone_denied`,
`connect_failed`, `call_rejected`, `already_active`.

## How it connects

1. POST your session route → `{run_id, sip_username, sip_password, wss_url, sip_register, ice_servers, ...}`.
2. Open `wss_url` with the `sip` WebSocket subprotocol; `REGISTER` first when `sip_register` is true.
3. Gather ICE (up to 2s, non-trickle) and send `INVITE sip:7000@<host>` with `X-Agent-Id` and
   `X-Run-Id` headers, answering 401/407 digest challenges.
4. 180/183 → `ringing`; 200 OK → apply the answer, `ACK`, `active`.
5. `stop()` sends `BYE` (or `CANCEL` while ringing). A peer connection that stays disconnected
   for 6s ends the call as `remote-hangup`.

## Development

```bash
swift test                      # signalling core: SIP parsing, digest auth, call flows
xcodebuild -scheme BolnaWebCall -destination 'generic/platform=iOS Simulator' build
```

## Releasing

Swift Package Manager installs straight from git tags. Push a `vX.Y.Z` tag (or `X.Y.Z`); there is
no registry upload.

## License

MIT
