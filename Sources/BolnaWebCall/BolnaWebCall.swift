import AVFoundation
import Foundation
@_exported @preconcurrency import BolnaWebCallCore
import WebRTC

/// A live voice call with a Bolna agent over WebRTC. Same flow and events as the browser SDK
/// `@bolna/web-call`: mint a single-use session from your backend → mic permission →
/// SIP-over-WebSocket INVITE → audio.
///
/// Callbacks are delivered on the main queue.
public final class BolnaWebCall: NSObject {
    public enum SessionSource {
        /// Your backend route; POSTed `{}` or `{"user_data": ...}`, returns the session JSON.
        case url(URL)
        /// Custom fetch (auth headers, your own HTTP client).
        case provider(() async throws -> Session)
        /// A session you fetched just now. Single-use.
        case session(Session)
    }

    public enum IceTransportPolicy { case all, relay }

    public var onStateChange: ((CallState) -> Void)?
    public var onMediaPermission: (() -> Void)?
    public var onCallStart: (() -> Void)?
    public var onCallEnd: ((CallEndReason) -> Void)?
    public var onError: ((CallError) -> Void)?
    /// Agent audio level 0...1, about 10 times a second.
    public var onVolumeLevel: ((Double) -> Void)?

    public private(set) var state: CallState = .idle
    public private(set) var runId: String?
    public private(set) var isMuted = false

    private let source: SessionSource
    private let userData: [String: Any]?
    private let iceTransportPolicy: IceTransportPolicy
    private var sessionConsumed = false

    private static let connectTimeout: TimeInterval = 30
    private static let iceGatheringTimeout: TimeInterval = 2
    private static let disconnectGrace: TimeInterval = 6
    private static let volumeInterval: TimeInterval = 0.1

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }()

    private let queue = DispatchQueue(label: "ai.bolna.webcall")
    private var attempt = 0
    private var peerConnection: RTCPeerConnection?
    private var localTrack: RTCAudioTrack?
    private var socket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var sip: SipCall?
    private var gatheringDone: (() -> Void)?
    private var socketOpened: ((Error?) -> Void)?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var disconnectTimer: DispatchWorkItem?
    private var volumeTimer: DispatchSourceTimer?

    public init(source: SessionSource, userData: [String: Any]? = nil, iceTransportPolicy: IceTransportPolicy = .all) {
        self.source = source
        self.userData = userData
        self.iceTransportPolicy = iceTransportPolicy
    }

    // MARK: - public API

    /// Mint → mic permission → connect. Returns once the agent answers.
    @MainActor
    public func start(userData overrideUserData: [String: Any]? = nil) async throws {
        guard state == .idle || state == .ended else {
            let error = CallError(.alreadyActive, "A call is already in progress")
            onError?(error)
            throw error
        }
        attempt += 1
        let token = attempt
        isMuted = false
        setState(.connecting)
        do {
            let session = try await fetchSession(userData: overrideUserData ?? userData)
            try checkCancelled(token)
            runId = session.runId
            try await requestMicrophone()
            try checkCancelled(token)
            onMediaPermission?()
            try await connect(session: session, token: token)
            try checkCancelled(token)
            setState(.active)
            onCallStart?()
        } catch let error as CancellationError {
            throw error
        } catch {
            let callError = (error as? CallError) ?? CallError(.connectFailed, error.localizedDescription)
            guard token == attempt else { throw callError }
            onError?(callError)
            teardown(reason: .failed)
            throw callError
        }
    }

    /// Hang up and release the mic and network. Safe to call at any time.
    @MainActor
    public func stop() async {
        guard state != .idle && state != .ended else { return }
        attempt += 1
        queue.sync { sip?.hangup() }
        if let continuation = connectContinuation {
            connectContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
        // give the BYE/CANCEL frame a moment to leave before the socket closes
        try? await Task.sleep(nanoseconds: 200_000_000)
        teardown(reason: .localHangup)
    }

    @MainActor
    public func setMuted(_ muted: Bool) {
        isMuted = muted
        localTrack?.isEnabled = !muted
    }

    // MARK: - steps

    private func checkCancelled(_ token: Int) throws {
        if token != attempt { throw CancellationError() }
    }

    private func fetchSession(userData: [String: Any]?) async throws -> Session {
        switch source {
        case .url(let url):
            return try await SessionFetcher.fetch(url: url, userData: userData)
        case .provider(let provider):
            do {
                return try await provider()
            } catch let error as CallError {
                throw error
            } catch {
                throw CallError(.mintFailed, error.localizedDescription)
            }
        case .session(let session):
            guard !sessionConsumed else {
                throw CallError(.mintFailed, "This session was already used; sessions are single-use")
            }
            sessionConsumed = true
            return session
        }
    }

    private func requestMicrophone() async throws {
        #if os(iOS)
        let granted = await withCheckedContinuation { c in
            AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) }
        }
        #else
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        #endif
        guard granted else { throw CallError(.microphoneDenied, "Microphone access was denied") }
        #if os(iOS)
        let audio = RTCAudioSession.sharedInstance()
        audio.lockForConfiguration()
        try? audio.setCategory(.playAndRecord, with: [.allowBluetooth, .defaultToSpeaker])
        try? audio.setMode(.voiceChat)
        audio.unlockForConfiguration()
        #endif
    }

    @MainActor
    private func connect(session: Session, token: Int) async throws {
        let pc = try makePeerConnection(session: session)
        let offer = try await createOffer(pc)
        try checkCancelled(token)

        guard let url = URL(string: session.wssUrl) else {
            throw CallError(.connectFailed, "Invalid wss_url")
        }
        try await openSocket(url)
        try checkCancelled(token)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connectContinuation = continuation
            let call = SipCall(config: .init(session: session, userAgent: "BolnaWebCall-iOS"))
            call.send = { [weak self] frame in
                self?.socket?.send(.string(frame)) { _ in }
            }
            call.onEvent = { [weak self] event in
                DispatchQueue.main.async { self?.handle(event, pc: pc) }
            }
            sip = call
            queue.async { call.start(offerSdp: offer) }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectTimeout) { [weak self] in
                guard let self, self.attempt == token, let pending = self.connectContinuation else { return }
                self.connectContinuation = nil
                self.queue.sync { self.sip?.hangup() }
                pending.resume(throwing: CallError(.connectFailed, "Timed out connecting the call"))
            }
        }
    }

    @MainActor
    private func handle(_ event: SipCall.Event, pc: RTCPeerConnection) {
        switch event {
        case .ringing:
            if state == .connecting { setState(.ringing) }
        case .answered(let sdp):
            pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self, let continuation = self.connectContinuation else { return }
                    self.connectContinuation = nil
                    if let error {
                        continuation.resume(throwing: CallError(.connectFailed, error.localizedDescription))
                    } else {
                        self.startVolumeMeter()
                        continuation.resume()
                    }
                }
            }
        case .failed(let code, let status):
            let message = code == .callRejected
                ? "The call was declined (SIP \(status ?? 0))"
                : "Could not reach the call server (SIP \(status ?? 0))"
            if let continuation = connectContinuation {
                connectContinuation = nil
                continuation.resume(throwing: CallError(code, message))
            }
        case .remoteHangup:
            if let continuation = connectContinuation {
                connectContinuation = nil
                continuation.resume(throwing: CallError(.callRejected, "The call ended before it was answered"))
            } else {
                teardown(reason: .remoteHangup)
            }
        }
    }

    private func makePeerConnection(session: Session) throws -> RTCPeerConnection {
        let config = RTCConfiguration()
        config.iceServers = session.iceServers.map {
            RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }
        config.iceTransportPolicy = iceTransportPolicy == .relay ? .relay : .all
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherOnce
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            throw CallError(.connectFailed, "Could not create a WebRTC peer connection")
        }
        let audioConstraints = RTCMediaConstraints(mandatoryConstraints: [
            "googEchoCancellation": "true", "googNoiseSuppression": "true", "googAutoGainControl": "true",
        ], optionalConstraints: nil)
        let track = Self.factory.audioTrack(with: Self.factory.audioSource(with: audioConstraints), trackId: "bolna-mic")
        track.isEnabled = !isMuted
        pc.add(track, streamIds: ["bolna"])
        localTrack = track
        peerConnection = pc
        return pc
    }

    /// Non-trickle: wait for ICE gathering (or the timeout) so candidates are in the INVITE SDP.
    private func createOffer(_ pc: RTCPeerConnection) async throws -> String {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "false"],
            optionalConstraints: nil
        )
        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { c in
            pc.offer(for: constraints) { sdp, error in
                if let sdp { c.resume(returning: sdp) } else {
                    c.resume(throwing: CallError(.connectFailed, error?.localizedDescription ?? "createOffer failed"))
                }
            }
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(offer) { error in
                if let error { c.resume(throwing: CallError(.connectFailed, error.localizedDescription)) } else { c.resume() }
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            var resumed = false
            let finish: () -> Void = { [weak self] in
                self?.queue.async {
                    guard !resumed else { return }
                    resumed = true
                    self?.gatheringDone = nil
                    c.resume()
                }
            }
            queue.async { [weak self] in
                if pc.iceGatheringState == .complete { finish() } else { self?.gatheringDone = finish }
            }
            queue.asyncAfter(deadline: .now() + Self.iceGatheringTimeout) { finish() }
        }
        return pc.localDescription?.sdp ?? offer.sdp
    }

    private func openSocket(_ url: URL) async throws {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: url, protocols: ["sip"])
        urlSession = session
        socket = task
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            socketOpened = { error in
                if let error { c.resume(throwing: CallError(.connectFailed, error.localizedDescription)) } else { c.resume() }
            }
            task.resume()
        }
        receiveLoop(task)
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self, self.socket === task else { return }
            switch result {
            case .success(.string(let text)):
                self.queue.async { self.sip?.receive(text) }
            case .success(.data(let data)):
                if let text = String(data: data, encoding: .utf8) { self.queue.async { self.sip?.receive(text) } }
            case .success:
                break
            case .failure:
                DispatchQueue.main.async { self.transportLost() }
                return
            }
            self.receiveLoop(task)
        }
    }

    @MainActor
    private func transportLost() {
        if let continuation = connectContinuation {
            connectContinuation = nil
            continuation.resume(throwing: CallError(.connectFailed, "Lost connection to the call server"))
        } else if state == .active {
            teardown(reason: .remoteHangup)
        }
    }

    // MARK: - media monitoring

    private func startVolumeMeter() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.volumeInterval, repeating: Self.volumeInterval)
        timer.setEventHandler { [weak self] in
            self?.peerConnection?.statistics { report in
                for stat in report.statistics.values where stat.type == "inbound-rtp" {
                    guard (stat.values["kind"] as? String) == "audio",
                          let level = stat.values["audioLevel"] as? NSNumber else { continue }
                    DispatchQueue.main.async { self?.onVolumeLevel?(min(1, max(0, level.doubleValue))) }
                }
            }
        }
        timer.resume()
        volumeTimer = timer
    }

    @MainActor
    private func peerStateChanged(_ newState: RTCPeerConnectionState) {
        guard state == .active else { return }
        switch newState {
        case .failed, .closed:
            teardown(reason: .remoteHangup)
        case .disconnected:
            guard disconnectTimer == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.state == .active else { return }
                self.queue.sync { self.sip?.hangup() }
                self.teardown(reason: .remoteHangup)
            }
            disconnectTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.disconnectGrace, execute: work)
        case .connected:
            disconnectTimer?.cancel()
            disconnectTimer = nil
        default:
            break
        }
    }

    // MARK: - teardown

    @MainActor
    private func teardown(reason: CallEndReason) {
        let wasLive = state != .idle && state != .ended
        disconnectTimer?.cancel()
        disconnectTimer = nil
        volumeTimer?.cancel()
        volumeTimer = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        sip = nil
        peerConnection?.close()
        peerConnection = nil
        localTrack = nil
        guard wasLive else { return }
        setState(.ended)
        onCallEnd?(reason)
    }

    @MainActor
    private func setState(_ next: CallState) {
        guard state != next else { return }
        state = next
        onStateChange?(next)
    }
}

extension BolnaWebCall: URLSessionWebSocketDelegate {
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        let opened = socketOpened
        socketOpened = nil
        opened?(nil)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let opened = socketOpened
        socketOpened = nil
        opened?(error ?? CallError(.connectFailed, "WebSocket closed"))
    }
}

extension BolnaWebCall: RTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        guard newState == .complete else { return }
        queue.async { [weak self] in self?.gatheringDone?() }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        DispatchQueue.main.async { [weak self] in self?.peerStateChanged(newState) }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
