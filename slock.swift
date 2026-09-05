// slock 0.2.0 — MIT licensed.
// Native Opus conversion pattern adapted from gfreezy/DoubaoASR (MIT); see THIRD_PARTY_NOTICES.md.

import AppKit
import ApplicationServices
import AudioToolbox
import AVFoundation
import CryptoKit
import Darwin
import Foundation
import IOKit
import IOKit.hid
import ServiceManagement

// MARK: - Constants and byte helpers

enum SlockConfig {
    static let appName = "slock"
    // Keep identity keys and the single-instance lock in their existing location.
    static let storageName = "CapsLink"
    static let appVersion = "0.2.2"
    static let protocolVersion: UInt8 = 2
    static let brokerURL = URL(string: "wss://test.mosquitto.org:8081/mqtt")!
    static let topicPrefix = "capslink/v2/inbox/"
    static let capsHIDUsage: UInt64 = 0x700000039
    static let f18HIDUsage: UInt64 = 0x70000006D
    static let f18CGKeyCode: Int64 = 79
    static let helloInterval: TimeInterval = 10
    static let onlineTimeout: TimeInterval = 25
    static let remoteKeyTimeout: TimeInterval = 2.5
    static let remoteTalkTimeout: TimeInterval = 5
}

extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendUInt64(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8((value >> UInt64(shift)) & 0xff))
        }
    }

    func uint16(at offset: Int) -> UInt16? {
        guard offset >= 0, count >= 2, offset <= count - 2 else { return nil }
        let index = startIndex + offset
        return (UInt16(self[index]) << 8) | UInt16(self[index + 1])
    }

    func uint32(at offset: Int) -> UInt32? {
        guard offset >= 0, count >= 4, offset <= count - 4 else { return nil }
        let index = startIndex + offset
        return (UInt32(self[index]) << 24)
            | (UInt32(self[index + 1]) << 16)
            | (UInt32(self[index + 2]) << 8)
            | UInt32(self[index + 3])
    }

    func uint64(at offset: Int) -> UInt64? {
        guard offset >= 0, count >= 8, offset <= count - 8 else { return nil }
        var result: UInt64 = 0
        for index in (startIndex + offset)..<(startIndex + offset + 8) {
            result = (result << 8) | UInt64(self[index])
        }
        return result
    }

    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        var value = base64URL
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let decoded = Data(base64Encoded: value) else { return nil }
        self = decoded
    }
}

func randomUInt64() -> UInt64 {
    UInt64.random(in: 1...UInt64.max)
}

func shortIdentifier(for publicKey: Data) -> String {
    let digest = Data(SHA256.hash(data: publicKey))
    let text = digest.prefix(5).map { String(format: "%02X", $0) }.joined()
    return String(text.prefix(5)) + "-" + String(text.suffix(5))
}

func routeIdentifier(for publicKey: Data) -> String {
    Data(SHA256.hash(data: publicKey)).base64URL
}

func dataLexicographicallyPrecedes(_ lhs: Data, _ rhs: Data) -> Bool {
    lhs.lexicographicallyPrecedes(rhs)
}

func runProcess(_ executable: String, _ arguments: [String]) throws -> (Int32, String, String) {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    // Drain both pipes while the child runs; waiting first can deadlock on a full pipe.
    let group = DispatchGroup()
    final class Output: @unchecked Sendable { var data = Data() }
    let errorOutput = Output()
    group.enter()
    DispatchQueue.global().async {
        errorOutput.data = stderr.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    process.waitUntilExit()
    group.wait()
    let err = String(data: errorOutput.data, encoding: .utf8) ?? ""
    return (process.terminationStatus, out, err)
}

func appError(_ domain: String, _ message: String, code: Int = 1) -> NSError {
    NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: message])
}

// MARK: - Identity and peer storage

final class IdentityStore {
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    let publicKey: Data
    let shortID: String
    let routeID: String
    let pairingCode: String

    init(directory: URL? = nil) throws {
        let fm = FileManager.default
        let support = try directory ?? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent(SlockConfig.storageName, isDirectory: true)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        let keyURL = support.appendingPathComponent("identity.key")

        if fm.fileExists(atPath: keyURL.path) {
            let stored = try Data(contentsOf: keyURL)
            guard stored.count == 32 else {
                throw appError("slock.Identity", "The saved identity is invalid. Restore it from a backup or remove it and pair again.")
            }
            privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: stored)
        } else {
            privateKey = Curve25519.KeyAgreement.PrivateKey()
            guard fm.createFile(atPath: keyURL.path, contents: privateKey.rawRepresentation,
                                attributes: [.posixPermissions: 0o600]) else {
                throw appError("slock.Identity", "Could not save the private identity key.")
            }
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)

        publicKey = privateKey.publicKey.rawRepresentation
        shortID = shortIdentifier(for: publicKey)
        routeID = routeIdentifier(for: publicKey)
        pairingCode = "CL1." + publicKey.base64URL
    }

    static func publicKey(fromPairingCode input: String) throws -> Data {
        let compact = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "slock://pair/", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: "capslink://pair/", with: "", options: [.caseInsensitive])
        let payload = compact.uppercased().hasPrefix("CL1.") ? String(compact.dropFirst(4)) : compact
        guard let key = Data(base64URL: payload), key.count == 32 else {
            throw appError("slock.Identity", "That is not a valid slock pairing code.")
        }
        _ = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: key)
        return key
    }
}

struct PTTConsent {
    var active: UInt64?
    var outgoing: UInt64?
    var incoming: UInt64?
    var revoked: UInt64?

    mutating func invite() { outgoing = randomUInt64() }

    mutating func receiveInvitation(_ id: UInt64) -> UInt64? {
        guard id != 0, id != revoked else { return nil }
        if let active { return active }
        if let outgoing {
            // Concurrent invitations are consent from both users; choose one ID.
            active = min(outgoing, id)
            // Retry the chosen agreement until the peer acknowledges it. The
            // other invitation or our acceptance may have been lost in transit.
            self.outgoing = active
            incoming = nil
            return active
        }
        incoming = id
        return nil
    }

    @discardableResult
    mutating func accept(_ id: UInt64) -> Bool {
        guard incoming == id else { return false }
        active = id
        incoming = nil
        outgoing = nil
        return true
    }

    @discardableResult
    mutating func receiveAcceptance(_ id: UInt64) -> Bool {
        guard outgoing == id, id != revoked else { return false }
        active = id
        outgoing = nil
        incoming = nil
        return true
    }

    mutating func disable() {
        revoked = active ?? outgoing ?? incoming ?? revoked
        active = nil
        outgoing = nil
        incoming = nil
    }

    mutating func reject(_ id: UInt64) {
        guard incoming == id else { return }
        incoming = nil
        revoked = id
    }

    mutating func receiveRevocation(_ id: UInt64) {
        guard id != 0 else { return }
        if active == id || outgoing == id || incoming == id { disable() }
    }
}

protocol Preferences {
    func object(forKey defaultName: String) -> Any?
    func data(forKey key: String) -> Data?
    func string(forKey key: String) -> String?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension UserDefaults: Preferences {}

struct PeerProfile: Codable {
    let nickname: String

    static func clean(_ value: String) -> String {
        String(value.components(separatedBy: .controlCharacters).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
    }

    static func payload(_ nickname: String) -> Data {
        (try? JSONEncoder().encode(PeerProfile(nickname: clean(nickname)))) ?? Data()
    }

    static func read(_ data: Data) -> String? {
        guard data.count <= 1024, let value = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        return clean(value.nickname)
    }
}

struct RecentPeer: Codable {
    let publicKey: Data
    var ownNickname: String
    var localNickname: String
    var pairingCode: String { "CL1." + publicKey.base64URL }
    var displayName: String {
        if !ownNickname.isEmpty { return ownNickname }
        if !localNickname.isEmpty { return localNickname }
        return String(pairingCode.suffix(6))
    }
}

final class PeerStore {
    private let defaults: Preferences
    private let peerKey = "CapsLink.peerPublicKey"
    private(set) var recent: [RecentPeer] = []
    var ownNickname: String {
        get { PeerProfile.clean(defaults.string(forKey: "slock.nickname") ?? "") }
        set { defaults.set(PeerProfile.clean(newValue), forKey: "slock.nickname") }
    }

    func entry(for key: Data) -> RecentPeer? { recent.first { $0.publicKey == key } }

    func establish(_ key: Data, ownNickname: String?, localNickname: String? = nil) {
        var entry = self.entry(for: key) ?? RecentPeer(publicKey: key, ownNickname: "", localNickname: "")
        if let ownNickname { entry.ownNickname = PeerProfile.clean(ownNickname) }
        if let localNickname { entry.localNickname = PeerProfile.clean(localNickname) }
        recent.removeAll { $0.publicKey == key }
        recent.insert(entry, at: 0)
        persistRecent()
    }

    func rename(_ key: Data, ownNickname: String? = nil, localNickname: String? = nil) {
        guard let index = recent.firstIndex(where: { $0.publicKey == key }) else { return }
        if let ownNickname { recent[index].ownNickname = PeerProfile.clean(ownNickname) }
        if let localNickname { recent[index].localNickname = PeerProfile.clean(localNickname) }
        persistRecent()
    }

    private func persistRecent() {
        defaults.set(try? JSONEncoder().encode(recent), forKey: "slock.recentPeers")
    }

    var peerPublicKey: Data? {
        didSet {
            defaults.set(peerPublicKey, forKey: peerKey)
            if peerPublicKey != oldValue { ptt = PTTConsent() }
        }
    }

    var ptt: PTTConsent {
        didSet {
            defaults.set(ptt.active.map(String.init), forKey: "CapsLink.pttAgreement")
            defaults.set(ptt.outgoing.map(String.init), forKey: "CapsLink.pttOutgoing")
            defaults.set(ptt.revoked.map(String.init), forKey: "CapsLink.pttRevocation")
        }
    }

    var pttEnabled: Bool { ptt.active != nil }

    init(defaults: Preferences = UserDefaults.standard) {
        self.defaults = defaults
        peerPublicKey = defaults.data(forKey: peerKey)
        ptt = PTTConsent(
            active: defaults.string(forKey: "CapsLink.pttAgreement").flatMap(UInt64.init),
            outgoing: defaults.string(forKey: "CapsLink.pttOutgoing").flatMap(UInt64.init),
            revoked: defaults.string(forKey: "CapsLink.pttRevocation").flatMap(UInt64.init)
        )
        if peerPublicKey == nil { ptt = PTTConsent() }
        if let data = defaults.data(forKey: "slock.recentPeers"),
           let saved = try? JSONDecoder().decode([RecentPeer].self, from: data) {
            var seen = Set<Data>()
            recent = saved.filter { $0.publicKey.count == 32 && seen.insert($0.publicKey).inserted }.map {
                RecentPeer(publicKey: $0.publicKey, ownNickname: PeerProfile.clean($0.ownNickname),
                           localNickname: PeerProfile.clean($0.localNickname))
            }
        }
        if let key = peerPublicKey, entry(for: key) == nil { establish(key, ownNickname: nil) }
    }
}

// MARK: - End-to-end encrypted wire format

enum WireKind: UInt8 {
    case pairRequest = 1
    case pairAccept = 2
    case pairReject = 3
    case hello = 10
    case keyState = 11
    case profile = 12
    case pttInvite = 20
    case pttAccept = 21
    case pttReject = 22
    case pttDisable = 23
    case unpair = 24
    case talkStart = 30
    case audio = 31
    case talkStop = 32
}

struct OpenedMessage {
    let senderPublicKey: Data
    let kind: WireKind
    let payload: Data
    let sessionConfirmed: Bool
    let needsHelloReply: Bool
    let newSession: Bool
}

final class SecureWire {
    private let identity: IdentityStore
    private var sequence: UInt64 = 0
    private struct Session {
        let localBoot = randomUInt64()
        var hint: UInt64 = 0
        var boot: UInt64?
        var sequence: UInt64 = 0
        var retired: Set<UInt64> = []
        var lastSeen = ProcessInfo.processInfo.systemUptime
    }
    private var sessions: [Data: Session] = [:]

    func hasSession(with peer: Data) -> Bool { sessions[peer]?.boot != nil }

    private func reserveSession(for sender: Data, protecting protected: Set<Data>) -> Bool {
        if sessions[sender] != nil { return true }
        if sessions.count >= 32 {
            guard let oldest = sessions.filter({ !protected.contains($0.key) })
                .min(by: { $0.value.lastSeen < $1.value.lastSeen })?.key else { return false }
            sessions.removeValue(forKey: oldest)
        }
        // A forgotten replay window must also forget its receiver challenge.
        sessions[sender] = Session()
        return true
    }

    init(identity: IdentityStore) {
        self.identity = identity
    }

    private func key(for peerData: Data) throws -> SymmetricKey {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerData)
        let secret = try identity.privateKey.sharedSecretFromKeyAgreement(with: peer)
        var info = Data()
        if dataLexicographicallyPrecedes(identity.publicKey, peerData) {
            info.append(identity.publicKey)
            info.append(peerData)
        } else {
            info.append(peerData)
            info.append(identity.publicKey)
        }
        return secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("CapsLink/v1/E2E".utf8),
            sharedInfo: info,
            outputByteCount: 32
        )
    }

    func seal(kind: WireKind, payload: Data, to peerPublicKey: Data,
              protecting protected: Set<Data> = []) throws -> Data {
        guard kind == .hello || hasSession(with: peerPublicKey) else {
            throw appError("slock.Wire", "Waiting for a fresh peer session.")
        }
        let symmetricKey = try key(for: peerPublicKey)
        guard reserveSession(for: peerPublicKey, protecting: protected),
              let session = sessions[peerPublicKey] else {
            throw appError("slock.Wire", "No room for a fresh peer session.")
        }
        sequence &+= 1
        var plaintext = Data([kind.rawValue])
        plaintext.appendUInt64(session.localBoot)
        plaintext.appendUInt64(sequence)
        // Commands target the current receiver session, including after cache
        // eviction. HELLO exchanges fresh challenges before authorizing work.
        plaintext.appendUInt64((kind == .hello ? session.hint : session.boot) ?? 0)
        plaintext.append(payload)

        var header = Data([SlockConfig.protocolVersion])
        header.append(identity.publicKey)
        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: symmetricKey,
            authenticating: header
        )
        header.append(sealed.combined)
        return header
    }

    func open(_ input: Data, protecting protected: Set<Data> = []) -> OpenedMessage? {
        let packet = Data(input)
        guard packet.count >= 1 + 32 + 12 + 16 + 25,
              packet.count <= 64_000,
              packet[0] == SlockConfig.protocolVersion else { return nil }

        let sender = Data(packet[1..<33])
        var header = Data([packet[0]])
        header.append(sender)

        do {
            let box = try ChaChaPoly.SealedBox(combined: Data(packet[33...]))
            let plaintext = try ChaChaPoly.open(
                box,
                using: key(for: sender),
                authenticating: header
            )
            guard plaintext.count >= 25,
                  let kind = WireKind(rawValue: plaintext[0]),
                  let boot = plaintext.uint64(at: 1),
                  let messageSequence = plaintext.uint64(at: 9),
                  let recipientBoot = plaintext.uint64(at: 17),
                  boot != 0, messageSequence != 0 else { return nil }

            guard kind == .hello || sessions[sender] != nil,
                  reserveSession(for: sender, protecting: protected),
                  var session = sessions[sender] else { return nil }
            guard !session.retired.contains(boot) else { return nil }
            let newSession = session.boot != boot
            if kind == .hello {
                if recipientBoot != session.localBoot {
                    // An unconfirmed hello is only a reply address, never presence,
                    // consent, key state, or permission to change the active session.
                    session.hint = boot
                    session.lastSeen = ProcessInfo.processInfo.systemUptime
                    sessions[sender] = session
                    return OpenedMessage(senderPublicKey: sender, kind: kind, payload: Data(),
                                         sessionConfirmed: false, needsHelloReply: true, newSession: false)
                }
                if newSession {
                    guard session.retired.count < 128 else { return nil }
                    if let previous = session.boot { session.retired.insert(previous) }
                    session.boot = boot
                    session.sequence = 0
                }
            } else {
                guard session.boot == boot, recipientBoot == session.localBoot else { return nil }
            }
            guard messageSequence > session.sequence else { return nil }
            session.sequence = messageSequence
            session.hint = boot
            session.lastSeen = ProcessInfo.processInfo.systemUptime
            sessions[sender] = session
            return OpenedMessage(
                senderPublicKey: sender,
                kind: kind,
                payload: Data(plaintext.dropFirst(25)),
                sessionConfirmed: true,
                needsHelloReply: kind == .hello && newSession,
                newSession: newSession
            )
        } catch {
            return nil
        }
    }
}

// MARK: - Minimal MQTT 3.1.1 client over secure WebSocket

struct MQTTPacketDecoder {
    private var buffer = Data()
    static let maximumPacketSize = 65_536

    mutating func append(_ bytes: Data) throws {
        guard bytes.count <= Self.maximumPacketSize,
              buffer.count <= Self.maximumPacketSize - bytes.count else {
            throw appError("slock.MQTT", "MQTT receive buffer exceeded its limit.")
        }
        buffer.append(bytes)
    }

    mutating func next() throws -> (header: UInt8, body: Data)? {
        guard buffer.count >= 2 else { return nil }
        var remaining = 0
        var multiplier = 1
        for index in 1...4 {
            guard buffer.count > index else { return nil }
            let byte = Int(buffer[buffer.startIndex + index])
            remaining += (byte & 0x7f) * multiplier
            guard remaining <= Self.maximumPacketSize - 5 else {
                throw appError("slock.MQTT", "MQTT packet exceeded its limit.")
            }
            if byte & 0x80 == 0 {
                let total = 1 + index + remaining
                guard buffer.count >= total else { return nil }
                let start = buffer.startIndex
                let packet = (buffer[start], Data(buffer[(start + 1 + index)..<(start + total)]))
                buffer.removeFirst(total)
                if buffer.isEmpty { buffer = Data() }
                return packet
            }
            multiplier *= 128
        }
        throw appError("slock.MQTT", "Invalid MQTT remaining length.")
    }
}

protocol RelayTransport: AnyObject {
    var onStateChange: ((MQTTClient.State) -> Void)? { get set }
    var onMessage: ((String, Data) -> Void)? { get set }
    func start()
    func stop()
    func publish(topic: String, payload: Data)
}

final class MQTTClient: NSObject, URLSessionWebSocketDelegate, RelayTransport {
    enum State: Equatable {
        case stopped
        case connecting
        case connected
        case error(String)

        var text: String {
            switch self {
            case .stopped: return "Stopped"
            case .connecting: return "Connecting"
            case .connected: return "Connected"
            case .error(let message): return "Error: \(message)"
            }
        }
    }

    var onStateChange: ((State) -> Void)?
    var onMessage: ((String, Data) -> Void)?

    private let brokerURL: URL
    private let clientID: String
    private let subscriptionTopic: String
    private let queue = DispatchQueue(label: "slock.MQTT")
    private let delegateQueue: OperationQueue
    private var session: URLSession!
    private var webSocket: URLSessionWebSocketTask?
    private var packetDecoder = MQTTPacketDecoder()
    private var mqttReady = false
    private var stopping = false
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectDelay: TimeInterval = 1
    private var pingTimer: DispatchSourceTimer?
    private var connectedAt: TimeInterval = 0
    private var lastPingAt: TimeInterval = 0
    private var awaitingPingSince: TimeInterval?
    private var pendingWrites: [(data: Data, at: TimeInterval)] = []
    private var pendingWriteBytes = 0
    private var sending = false
    private let pendingMessages = DispatchSemaphore(value: 64)

    init(brokerURL: URL, clientID: String, subscriptionTopic: String) {
        self.brokerURL = brokerURL
        self.clientID = String(clientID.prefix(23))
        self.subscriptionTopic = subscriptionTopic
        delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func start() {
        queue.async {
            self.stopping = false
            self.connect()
        }
    }

    func stop() {
        queue.async {
            self.stopping = true
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.pingTimer?.cancel()
            self.pingTimer = nil
            if self.mqttReady { self.sendRaw(Data([0xE0, 0x00])) }
            self.webSocket?.cancel(with: .normalClosure, reason: nil)
            self.webSocket = nil
            self.mqttReady = false
            self.pendingWrites.removeAll()
            self.pendingWriteBytes = 0
            self.sending = false
            self.session.invalidateAndCancel()
            self.emit(.stopped)
        }
    }

    func publish(topic: String, payload: Data) {
        queue.async {
            guard self.mqttReady, payload.count <= 64_000 else { return }
            self.sendRaw(self.publishPacket(topic: topic, payload: payload))
        }
    }

    private func connect() {
        guard !stopping, webSocket == nil else { return }
        emit(.connecting)
        packetDecoder = MQTTPacketDecoder()
        pendingWrites.removeAll()
        pendingWriteBytes = 0
        sending = false
        awaitingPingSince = nil
        connectedAt = ProcessInfo.processInfo.systemUptime
        lastPingAt = connectedAt
        mqttReady = false
        let socket = session.webSocketTask(with: brokerURL, protocols: ["mqtt"])
        webSocket = socket
        socket.maximumMessageSize = MQTTPacketDecoder.maximumPacketSize
        socket.resume()
        startPingTimer()
    }

    private func scheduleReconnect(_ message: String) {
        guard !stopping else { return }
        if webSocket != nil {
            webSocket?.cancel(with: .goingAway, reason: nil)
            webSocket = nil
        }
        mqttReady = false
        pingTimer?.cancel()
        pingTimer = nil
        emit(.error(message))
        reconnectWorkItem?.cancel()
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 1.7, 15)
        let item = DispatchWorkItem { [weak self] in self?.connect() }
        reconnectWorkItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func emit(_ state: State) {
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(state) }
    }

    private func receiveNext() {
        guard let socket = webSocket, !stopping else { return }
        socket.receive { [weak self, weak socket] result in
            guard let self, let socket else { return }
            self.queue.async {
                guard self.webSocket === socket, !self.stopping else { return }
                switch result {
                case .failure(let error):
                    self.scheduleReconnect(error.localizedDescription)
                case .success(let message):
                    switch message {
                    case .data(let data):
                        self.parsePackets(data)
                    case .string(let string):
                        _ = string
                        self.scheduleReconnect("MQTT requires binary WebSocket messages")
                    @unknown default:
                        break
                    }
                    self.receiveNext()
                }
            }
        }
    }

    private func sendRaw(_ packet: Data) {
        guard pendingWriteBytes + packet.count <= 128_000 else {
            scheduleReconnect("Network send queue exceeded its limit")
            return
        }
        pendingWrites.append((packet, ProcessInfo.processInfo.systemUptime))
        pendingWriteBytes += packet.count
        sendNext()
    }

    private func sendNext() {
        guard !sending, let packet = pendingWrites.first?.data else { return }
        guard let socket = webSocket else { return }
        sending = true
        socket.send(.data(packet)) { [weak self, weak socket] error in
            guard let self, let socket else { return }
            self.queue.async {
                guard self.webSocket === socket else { return }
                if let error {
                    self.scheduleReconnect(error.localizedDescription)
                    return
                }
                self.pendingWriteBytes -= self.pendingWrites.removeFirst().data.count
                self.sending = false
                self.sendNext()
            }
        }
    }

    private func parsePackets(_ bytes: Data) {
        do {
            try packetDecoder.append(bytes)
            while webSocket != nil, let packet = try packetDecoder.next() {
                handlePacket(header: packet.header, body: packet.body)
            }
        } catch {
            scheduleReconnect(error.localizedDescription)
        }
    }

    private func handlePacket(header: UInt8, body: Data) {
        switch header >> 4 {
        case 2:
            guard header == 0x20, body.count == 2, body[0] == 0, body[1] == 0 else {
                scheduleReconnect("MQTT broker rejected the connection")
                return
            }
            sendRaw(subscribePacket(topic: subscriptionTopic, packetID: 1))
        case 3:
            handlePublish(header: header, body: body)
        case 9:
            guard header == 0x90, body.count == 3, body.uint16(at: 0) == 1, body[2] == 0 else {
                scheduleReconnect("MQTT broker rejected the inbox subscription")
                return
            }
            mqttReady = true
            reconnectDelay = 1
            emit(.connected)
            startPingTimer()
        case 13:
            awaitingPingSince = nil
        default:
            break
        }
    }

    private func handlePublish(header: UInt8, body: Data) {
        guard let topicLength = body.uint16(at: 0) else { return }
        let topicStart = 2
        let topicEnd = topicStart + Int(topicLength)
        guard body.count >= topicEnd,
              let topic = String(data: Data(body[topicStart..<topicEnd]), encoding: .utf8) else { return }
        let qos = (header >> 1) & 0x03
        guard qos == 0, topic == subscriptionTopic else { return }
        let payloadStart = topicEnd + (qos > 0 ? 2 : 0)
        guard body.count >= payloadStart else { return }
        let payload = Data(body.dropFirst(payloadStart))
        guard payload.count <= 64_000, pendingMessages.wait(timeout: .now()) == .success else {
            scheduleReconnect("Too many pending MQTT messages")
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.pendingMessages.signal() }
            self.onMessage?(topic, payload)
        }
    }

    private func startPingTimer() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if !self.mqttReady, now - self.connectedAt > 20 {
                self.scheduleReconnect("MQTT handshake timed out")
            } else if let since = self.awaitingPingSince, now - since > 10 {
                self.scheduleReconnect("MQTT ping response timed out")
            } else if let oldest = self.pendingWrites.first, now - oldest.at > 3 {
                self.scheduleReconnect("Network send queue stalled")
            } else if self.mqttReady, self.awaitingPingSince == nil, now - self.lastPingAt >= 12 {
                self.lastPingAt = now
                self.awaitingPingSince = now
                self.sendRaw(Data([0xC0, 0x00]))
            }
        }
        pingTimer = timer
        timer.resume()
    }

    private func connectPacket() -> Data {
        var body = Data()
        body.append(mqttString("MQTT"))
        body.append(0x04)
        body.append(0x02)
        body.appendUInt16(30)
        body.append(mqttString(clientID))
        return fixedPacket(header: 0x10, body: body)
    }

    private func subscribePacket(topic: String, packetID: UInt16) -> Data {
        var body = Data()
        body.appendUInt16(packetID)
        body.append(mqttString(topic))
        body.append(0x00)
        return fixedPacket(header: 0x82, body: body)
    }

    private func publishPacket(topic: String, payload: Data) -> Data {
        var body = Data()
        body.append(mqttString(topic))
        body.append(payload)
        return fixedPacket(header: 0x30, body: body)
    }

    private func fixedPacket(header: UInt8, body: Data) -> Data {
        var packet = Data([header])
        packet.append(encodeRemainingLength(body.count))
        packet.append(body)
        return packet
    }

    private func mqttString(_ value: String) -> Data {
        let bytes = Data(value.utf8)
        let count = min(bytes.count, Int(UInt16.max))
        var output = Data()
        output.appendUInt16(UInt16(count))
        output.append(Data(bytes.prefix(count)))
        return output
    }

    private func encodeRemainingLength(_ value: Int) -> Data {
        var x = value
        var output = Data()
        repeat {
            var byte = UInt8(x % 128)
            x /= 128
            if x > 0 { byte |= 0x80 }
            output.append(byte)
        } while x > 0
        return output
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        queue.async {
            guard self.webSocket === webSocketTask, !self.stopping else { return }
            self.sendRaw(self.connectPacket())
            self.receiveNext()
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        queue.async {
            guard self.webSocket === webSocketTask, !self.stopping else { return }
            self.scheduleReconnect("WebSocket closed (\(closeCode.rawValue))")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let socket = task as? URLSessionWebSocketTask else { return }
        queue.async {
            guard self.webSocket === socket, !self.stopping else { return }
            self.scheduleReconnect(error?.localizedDescription ?? "Network connection ended")
        }
    }
}

// MARK: - Caps Lock interception and mapping restoration

private var globalCapsEventTap: CFMachPort?
private var globalCapsIsDown = false
private let globalCapsDelivery = CapturedKeyDelivery()
private var globalCapsClearLock: (() -> Void)?
private var cleanupPath: UnsafeMutablePointer<CChar>?
private var cleanupArg0: UnsafeMutablePointer<CChar>?
private var cleanupArg1: UnsafeMutablePointer<CChar>?
private var cleanupArg2: UnsafeMutablePointer<CChar>?
private var cleanupArg3: UnsafeMutablePointer<CChar>?

// Tap callbacks must defer expensive controller work, but queued presses must
// never survive a disabled tap or be delivered to a later capture session.
final class CapturedKeyDelivery {
    var handler: ((Bool) -> Void)?
    private var generation = UUID()

    func enqueue(_ down: Bool) {
        let generation = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.handler?(down)
        }
    }

    func release() {
        generation = UUID()
        handler?(false)
    }

    func reset() {
        generation = UUID()
        handler = nil
    }
}

private func configureEmergencyRestore(_ json: String?) {
    [cleanupPath, cleanupArg0, cleanupArg1, cleanupArg2, cleanupArg3].forEach {
        if let pointer = $0 { free(pointer) }
    }
    cleanupPath = nil
    cleanupArg0 = nil
    cleanupArg1 = nil
    cleanupArg2 = nil
    cleanupArg3 = nil
    guard let json else { return }
    cleanupPath = strdup("/usr/bin/hidutil")
    cleanupArg0 = strdup("hidutil")
    cleanupArg1 = strdup("property")
    cleanupArg2 = strdup("--set")
    cleanupArg3 = strdup(json)
}

private func emergencyRestoreMapping() {
    guard let cleanupPath, let cleanupArg0, let cleanupArg1,
          let cleanupArg2, let cleanupArg3 else { return }
    var pid: pid_t = 0
    var argv: [UnsafeMutablePointer<CChar>?] = [
        cleanupArg0, cleanupArg1, cleanupArg2, cleanupArg3, nil
    ]
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
    let result = posix_spawn(&pid, cleanupPath, &actions, nil, &argv, environ)
    posix_spawn_file_actions_destroy(&actions)
    if result == 0 {
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }
}

// Return false for native Caps Lock events that must never reach applications.
func suppressCapsLock(in event: CGEvent, type: CGEventType? = nil, clearLock: () -> Void) -> Bool {
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    // Some keyboards toggle their Caps Lock state before the Caps→F18 remap is
    // visible to the event tap. Clear it on every captured press, even when the
    // event no longer carries maskAlphaShift, so the local LED cannot latch.
    let capturedPress = keyCode == SlockConfig.f18CGKeyCode && type == .keyDown
    if event.flags.contains(.maskAlphaShift) || keyCode == 57 || capturedPress {
        clearLock()
        event.flags = event.flags.subtracting(.maskAlphaShift)
    }
    return keyCode != 57
}

private func capsEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // A key-up may have been lost while the tap was disabled. Fail closed:
        // release the remote light and microphone before resuming interception.
        globalCapsIsDown = false
        globalCapsDelivery.release()
        if let tap = globalCapsEventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    guard suppressCapsLock(in: event, type: type, clearLock: { globalCapsClearLock?() }) else { return nil }
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    if keyCode == SlockConfig.f18CGKeyCode {
        if type == .keyDown {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isRepeat, !globalCapsIsDown {
                globalCapsIsDown = true
                globalCapsDelivery.enqueue(true)
            }
            return nil
        }
        if type == .keyUp {
            if globalCapsIsDown {
                globalCapsIsDown = false
                globalCapsDelivery.enqueue(false)
            }
            return nil
        }
        if type == .flagsChanged { return nil }
    }

    return Unmanaged.passUnretained(event)
}

enum KeyboardTapAccess {
    static let requiredMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        | (1 << CGEventType.keyUp.rawValue)
        | (1 << CGEventType.flagsChanged.rawValue)

    static func validate(mask: CGEventMask) throws {
        guard mask & requiredMask == requiredMask else {
            throw appError("slock.Keyboard", "Keyboard event access is incomplete. Enable slock in Input Monitoring and Accessibility, then quit and reopen slock.")
        }
    }

    static func verifyCurrentProcess() throws {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success else {
            throw appError("slock.Keyboard", "Could not verify keyboard event access. Capture is inactive.")
        }
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count) + 8)
        let result = taps.withUnsafeMutableBufferPointer {
            CGGetEventTapList(UInt32($0.count), $0.baseAddress, &count)
        }
        guard result == .success, Int(count) <= taps.count,
              let tap = taps.prefix(Int(count)).first(where: {
                  $0.tappingProcess == getpid() && $0.tapPoint == .cgSessionEventTap
                      && $0.options == .defaultTap
              }) else {
            throw appError("slock.Keyboard", "Could not verify the keyboard event tap. Capture is inactive.")
        }
        try validate(mask: tap.eventsOfInterest)
    }
}

final class CapsInterceptor {
    typealias HIDMap = (src: UInt64, dst: UInt64)

    var onKeyState: ((Bool) -> Void)?
    var onStatusChange: (() -> Void)?

    private(set) var isActive = false
    private(set) var permissionGranted = false
    private(set) var lastError: String?
    private(set) var originalMappings: [HIDMap] = []

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permissionTimer: Timer?
    private(set) var priorCapsLockOn = false
    private(set) var isRequested = false
    private let defaults: Preferences
    private let process: (String, [String]) throws -> (Int32, String, String)
    private var trustCheck: () -> Bool = { AXIsProcessTrusted() }
    private var permissionPrompt: () -> Void = {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    private let permissionPromptKey = "CapsLink.didRequestAccessibility"
    private var createsEventTap = true
    private var verifyTap: () throws -> Void = KeyboardTapAccess.verifyCurrentProcess
    private var readLock: () -> Bool = {
        CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
    }
    private var writeLock: (Bool) -> Bool = CapsLockState.set
    private let staleMappingKey = "CapsLink.staleOriginalMapping"
    private var recoveryFailed = false
    private var needsLockRestore = false

    init(defaults: Preferences = UserDefaults.standard,
         process: @escaping (String, [String]) throws -> (Int32, String, String) = runProcess) {
        self.defaults = defaults
        self.process = process
        // Older installs already requested permission before this marker existed.
        // Keep upgrades quiet, including when macOS no longer trusts a new build.
        if defaults.object(forKey: permissionPromptKey) == nil,
           defaults.object(forKey: "CapsLink.captureEnabled") != nil
            || defaults.object(forKey: "CapsLink.didConfigureLaunchAtLogin") != nil {
            defaults.set(true, forKey: permissionPromptKey)
            defaults.synchronize()
        }
        restoreStaleMappingIfNeeded()
    }

    #if CAPSLINK_TESTING
    convenience init(testDefaults: Preferences,
                     process: @escaping (String, [String]) throws -> (Int32, String, String),
                     readLock: @escaping () -> Bool = { false },
                     writeLock: @escaping (Bool) -> Bool = { _ in true },
                     trustCheck: @escaping () -> Bool = { true },
                     verifyTap: @escaping () throws -> Void = {},
                     permissionPrompt: @escaping () -> Void = {}) {
        self.init(defaults: testDefaults, process: process)
        self.trustCheck = trustCheck
        self.permissionPrompt = permissionPrompt
        self.verifyTap = verifyTap
        createsEventTap = false
        self.readLock = readLock
        self.writeLock = writeLock
    }
    #endif

    func requestPermissionAndStart() {
        isRequested = true
        guard !isActive else { return }
        permissionGranted = trustCheck()
        if defaults.object(forKey: permissionPromptKey) == nil {
            // Persist before asking so denial, relaunches, and repeated activation
            // cannot bring the system permission UI back automatically.
            defaults.set(true, forKey: permissionPromptKey)
            defaults.synchronize()
            if !permissionGranted { permissionPrompt() }
        }
        if !permissionGranted {
            permissionTimer?.invalidate()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
                guard let self else { return }
                if self.trustCheck() {
                    timer.invalidate()
                    self.permissionTimer = nil
                    self.permissionGranted = true
                    self.start()
                }
                self.onStatusChange?()
            }
            if let permissionTimer { RunLoop.main.add(permissionTimer, forMode: .common) }
            onStatusChange?()
            return
        }
        start()
    }

    func start() {
        guard !isActive else { return }
        if recoveryFailed || needsLockRestore {
            restoreStaleMappingIfNeeded()
            guard !recoveryFailed else { onStatusChange?(); return }
        }
        permissionGranted = trustCheck()
        guard permissionGranted else {
            requestPermissionAndStart()
            return
        }
        permissionTimer?.invalidate()
        permissionTimer = nil

        var attemptedMapping = false
        do {
            let mappings = try readMappings()
            if mappings.contains(where: {
                $0.src != SlockConfig.capsHIDUsage && $0.dst == SlockConfig.f18HIDUsage
            }) {
                throw appError(
                    "slock.Keyboard",
                    "F18 is already the destination of another hidutil mapping. Remove that mapping or change slock's relay key."
                )
            }

            priorCapsLockOn = readLock()
            try installEventTap()
            // CGEvent.tapCreate can succeed after silently removing key-down
            // and key-up from the mask. Verify before taking over the keyboard.
            try verifyTap()
            originalMappings = mappings
            let originalJSON = mappingJSON(mappings)
            defaults.set(originalJSON, forKey: staleMappingKey)
            guard defaults.synchronize() else {
                defaults.removeObject(forKey: staleMappingKey)
                throw appError("slock.Keyboard", "Could not save the keyboard recovery journal. Capture is inactive.")
            }
            configureEmergencyRestore(originalJSON)

            var activeMappings = mappings.filter { $0.src != SlockConfig.capsHIDUsage }
            activeMappings.append((SlockConfig.capsHIDUsage, SlockConfig.f18HIDUsage))
            attemptedMapping = true
            // Even if verification fails, the retained tap can clear the lock
            // while swallowing remapped events. Keep the original state owed.
            needsLockRestore = true
            try applyMappings(activeMappings)
            guard writeLock(false) else {
                throw appError("slock.Keyboard", "Could not turn off the system Caps Lock state. Capture is inactive.")
            }
            lastError = nil
            isActive = true
        } catch {
            if attemptedMapping, let json = defaults.string(forKey: staleMappingKey) {
                do {
                    try applyMappingJSON(json)
                    defaults.removeObject(forKey: staleMappingKey)
                    defaults.synchronize()
                    configureEmergencyRestore(nil)
                    originalMappings = []
                } catch {
                    recoveryFailed = true
                }
            }
            // Keep swallowing the remapped key if rollback failed. A later
            // retry or stop still has the journal needed to restore ownership.
            if !recoveryFailed {
                removeEventTap()
                _ = restorePendingLock()
            }
            lastError = error.localizedDescription
            isActive = false
        }
        onStatusChange?()
    }

    func stop() {
        isRequested = false
        permissionTimer?.invalidate()
        permissionTimer = nil
        globalCapsDelivery.release()
        if globalCapsIsDown {
            globalCapsIsDown = false
            onKeyState?(false)
        }
        if let json = defaults.string(forKey: staleMappingKey) {
            do {
                try applyMappingJSON(json)
                defaults.removeObject(forKey: staleMappingKey)
                defaults.synchronize()
                configureEmergencyRestore(nil)
                originalMappings = []
                recoveryFailed = false
            } catch {
                lastError = "Could not restore the prior keyboard mapping: \(error.localizedDescription)"
                isRequested = isActive
                onStatusChange?()
                return
            }
        }
        removeEventTap()
        isActive = false
        if !restorePendingLock() {
            lastError = "Capture stopped, but the previous Caps Lock state could not be restored."
        }
        onStatusChange?()
    }

    private func installEventTap() throws {
        guard createsEventTap else { return }
        guard eventTap == nil else { return }
        let mask = KeyboardTapAccess.requiredMask
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: capsEventTapCallback,
            userInfo: nil
        ) else {
            throw appError(
                "slock.Keyboard",
                "Could not create a keyboard event tap. Grant Accessibility permission, then relaunch slock."
            )
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw appError("slock.Keyboard", "Could not create the keyboard event-tap run-loop source.")
        }
        eventTap = tap
        runLoopSource = source
        globalCapsEventTap = tap
        globalCapsDelivery.handler = { [weak self] down in self?.onKeyState?(down) }
        globalCapsClearLock = { [weak self] in
            guard let self else { return }
            if !self.writeLock(false) {
                DispatchQueue.main.async { [weak self] in
                    self?.lastError = "Could not clear the system Caps Lock state."
                    self?.onStatusChange?()
                }
            }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        globalCapsEventTap = nil
        globalCapsIsDown = false
        globalCapsDelivery.reset()
        globalCapsClearLock = nil
    }

    private func restoreStaleMappingIfNeeded() {
        guard let json = defaults.string(forKey: staleMappingKey) else {
            if needsLockRestore {
                removeEventTap()
                recoveryFailed = !restorePendingLock()
            }
            return
        }
        configureEmergencyRestore(nil)
        do {
            let canonical = mappingJSON(try decodeMappingJSON(json))
            configureEmergencyRestore(canonical)
            try applyMappingJSON(canonical)
            defaults.removeObject(forKey: staleMappingKey)
            defaults.synchronize()
            configureEmergencyRestore(nil)
            recoveryFailed = false
            removeEventTap()
            guard restorePendingLock() else {
                throw appError("slock.Keyboard", "The previous Caps Lock state could not be restored.")
            }
        } catch {
            recoveryFailed = true
            lastError = "A prior slock keyboard mapping could not be restored: \(error.localizedDescription)"
        }
    }

    private func restorePendingLock() -> Bool {
        guard needsLockRestore else { return true }
        guard writeLock(priorCapsLockOn) else { return false }
        needsLockRestore = false
        return true
    }

    #if CAPSLINK_TESTING
    static var emergencyMappingJSON: String? { cleanupArg3.map { String(cString: $0) } }
    #endif

    private func readMappings() throws -> [HIDMap] {
        let result = try process("/usr/bin/hidutil", ["property", "--get", "UserKeyMapping"])
        guard result.0 == 0 else {
            throw appError(
                "slock.Keyboard",
                result.2.isEmpty ? "hidutil could not read key mappings." : result.2
            )
        }
        return try Self.parseMappings(result.1)
    }

    static func parseMappings(_ text: String) throws -> [HIDMap] {
        let output = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.isEmpty || output == "(null)" || output == "null" || output == "[]"
            || output.range(of: #"^\(\s*\)$"#, options: .regularExpression) != nil { return [] }

        let blockRegex = try NSRegularExpression(pattern: #"\{[^}]*\}"#, options: [.dotMatchesLineSeparators])
        let srcRegex = try NSRegularExpression(
            pattern: #"HIDKeyboardModifierMappingSrc\s*=\s*(0x[0-9A-Fa-f]+|[0-9]+)\s*;"#
        )
        let dstRegex = try NSRegularExpression(
            pattern: #"HIDKeyboardModifierMappingDst\s*=\s*(0x[0-9A-Fa-f]+|[0-9]+)\s*;"#
        )
        let fullRange = NSRange(output.startIndex..<output.endIndex, in: output)
        let blocks = blockRegex.matches(in: output, range: fullRange)
        var mappings: [HIDMap] = []
        let container = blockRegex.stringByReplacingMatches(in: output, range: fullRange, withTemplate: "#")
        guard container.range(of: #"^\(\s*#(?:\s*,\s*#)*\s*,?\s*\)$"#,
                              options: .regularExpression) != nil else {
            throw appError("slock.Keyboard", "slock refused to overwrite an incomplete hidutil mapping.")
        }

        for match in blocks {
            guard let range = Range(match.range, in: output) else { continue }
            let block = String(output[range])
            let blockRange = NSRange(block.startIndex..<block.endIndex, in: block)
            guard let srcMatch = srcRegex.firstMatch(in: block, range: blockRange),
                  let dstMatch = dstRegex.firstMatch(in: block, range: blockRange),
                  let srcRange = Range(srcMatch.range(at: 1), in: block),
                  let dstRange = Range(dstMatch.range(at: 1), in: block),
                  let src = parseInteger(String(block[srcRange])),
                  let dst = parseInteger(String(block[dstRange])) else { continue }
            let withoutSource = srcRegex.stringByReplacingMatches(in: block, range: blockRange, withTemplate: "")
            let remainder = dstRegex.stringByReplacingMatches(in: withoutSource,
                range: NSRange(withoutSource.startIndex..<withoutSource.endIndex, in: withoutSource), withTemplate: "")
            guard srcRegex.numberOfMatches(in: block, range: blockRange) == 1,
                  dstRegex.numberOfMatches(in: block, range: blockRange) == 1,
                  remainder.range(of: #"^\{\s*\}$"#, options: .regularExpression) != nil else { continue }
            mappings.append((src, dst))
        }

        guard !blocks.isEmpty, mappings.count == blocks.count else {
            throw appError(
                "slock.Keyboard",
                "slock refused to overwrite an existing hidutil mapping it could not parse."
            )
        }
        return mappings
    }

    private static func parseInteger(_ value: String) -> UInt64? {
        if value.lowercased().hasPrefix("0x") {
            return UInt64(value.dropFirst(2), radix: 16)
        }
        return UInt64(value)
    }

    private func mappingJSON(_ mappings: [HIDMap]) -> String {
        let entries = mappings.map {
            "{\"HIDKeyboardModifierMappingSrc\":\($0.src),\"HIDKeyboardModifierMappingDst\":\($0.dst)}"
        }.joined(separator: ",")
        return "{\"UserKeyMapping\":[\(entries)]}"
    }

    private func applyMappings(_ mappings: [HIDMap]) throws {
        try applyMappingJSON(mappingJSON(mappings))
    }

    private func decodeMappingJSON(_ json: String) throws -> [HIDMap] {
        struct Journal: Decodable {
            struct Entry: Decodable {
                let HIDKeyboardModifierMappingSrc: UInt64
                let HIDKeyboardModifierMappingDst: UInt64
            }
            let UserKeyMapping: [Entry]
        }
        let journal = try JSONDecoder().decode(Journal.self, from: Data(json.utf8))
        return journal.UserKeyMapping.map {
            (src: $0.HIDKeyboardModifierMappingSrc, dst: $0.HIDKeyboardModifierMappingDst)
        }
    }

    private func applyMappingJSON(_ json: String) throws {
        // Validate the entire journal before running a command, and only pass
        // the supported mapping property through to hidutil.
        let expected = try decodeMappingJSON(json)
        let result = try process("/usr/bin/hidutil", ["property", "--set", mappingJSON(expected)])
        guard result.0 == 0 else {
            throw appError(
                "slock.Keyboard",
                result.2.isEmpty ? "hidutil failed to apply the key mapping." : result.2
            )
        }
        // hidutil can exit successfully without installing a mapping. Never
        // claim ownership (or discard the recovery journal) on exit status alone.
        let actual = try readMappings()
        let ordered: (HIDMap, HIDMap) -> Bool = { $0.src == $1.src ? $0.dst < $1.dst : $0.src < $1.src }
        guard actual.count == expected.count,
              zip(actual.sorted(by: ordered), expected.sorted(by: ordered)).allSatisfy({
                  $0.src == $1.src && $0.dst == $1.dst
              }) else {
            throw appError("slock.Keyboard", "macOS did not apply the keyboard mapping. Check slock's Accessibility permission and try enabling capture again.")
        }
    }
}

// MARK: - Caps Lock LED output

final class CapsLED {
    enum Mode: String {
        case unknown = "Not tested"
        case directHID = "Direct HID LED"
        case unavailable = "Unavailable"
    }

    private let manager: IOHIDManager?
    private var directWriter: ((Bool) -> Bool)?
    private(set) var mode: Mode = .unknown
    private(set) var isOn = false

    init() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        IOHIDManagerSetDeviceMatching(manager, nil)
        _ = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    deinit {
        if let manager { _ = IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
    }

    #if CAPSLINK_TESTING
    init(directWriter: @escaping (Bool) -> Bool) {
        manager = nil
        self.directWriter = directWriter
    }
    #endif

    @discardableResult
    func set(_ on: Bool) -> Bool {
        let direct = directWriter?(on) ?? setDirect(on)
        if direct {
            mode = .directHID
            isOn = on
            return true
        }
        mode = .unavailable
        isOn = false
        return false
    }

    private func setDirect(_ on: Bool) -> Bool {
        guard let manager, let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return false }
        var changed = false
        for device in devices {
            guard IOHIDDeviceConformsTo(
                device,
                UInt32(kHIDPage_GenericDesktop),
                UInt32(kHIDUsage_GD_Keyboard)
            ) else { continue }
            guard let copied = IOHIDDeviceCopyMatchingElements(
                device,
                nil,
                IOOptionBits(kIOHIDOptionsTypeNone)
            ) else { continue }
            for case let element as IOHIDElement in (copied as NSArray) {
                guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_LEDs),
                      IOHIDElementGetUsage(element) == UInt32(kHIDUsage_LED_CapsLock) else { continue }
                let value = IOHIDValueCreateWithIntegerValue(
                        kCFAllocatorDefault,
                        element,
                        mach_absolute_time(),
                        on ? 1 : 0
                      )
                if IOHIDDeviceSetValue(device, element, value) == kIOReturnSuccess {
                    changed = true
                }
            }
        }
        return changed
    }

}

// Only capture ownership changes may restore Caps Lock. LED output must never
// enable this state: macOS also uses it for capitalization and the cursor badge.
enum CapsLockState {
    static func set(_ on: Bool) -> Bool {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching(kIOHIDSystemClass)
        )
        guard service != IO_OBJECT_NULL else { return false }
        var connection: io_connect_t = 0
        let opened = IOServiceOpen(
            service,
            mach_task_self_,
            UInt32(kIOHIDParamConnectType),
            &connection
        )
        IOObjectRelease(service)
        guard opened == KERN_SUCCESS else { return false }
        let result = IOHIDSetModifierLockState(
            connection,
            Int32(kIOHIDCapsLockState),
            on
        )
        var actual = !on
        let readResult = IOHIDGetModifierLockState(connection, Int32(kIOHIDCapsLockState), &actual)
        IOServiceClose(connection)
        return result == KERN_SUCCESS && readResult == KERN_SUCCESS && actual == on
    }
}

// MARK: - Native Opus audio

enum AudioConfig {
    static let sampleRate = 16_000
    static let channels = 1
    static let frameDurationMs = 20
    static let framesPerPacket = sampleRate * frameDurationMs / 1_000
    static let bytesPerPCMFrame = framesPerPacket * MemoryLayout<Int16>.size
    static let packetsPerBatch = 3
    static let bitRate = 12_000
}

func audioError(_ message: String) -> NSError {
    appError("slock.Audio", message)
}

final class OpusEncoder {
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let framesPerPacket = AVAudioFrameCount(AudioConfig.framesPerPacket)

    init() throws {
        guard let input = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(AudioConfig.sampleRate),
            channels: AVAudioChannelCount(AudioConfig.channels),
            interleaved: true
        ) else { throw audioError("Could not create the Opus input format.") }

        var description = AudioStreamBasicDescription(
            mSampleRate: Double(AudioConfig.sampleRate),
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(AudioConfig.framesPerPacket),
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(AudioConfig.channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let output = AVAudioFormat(streamDescription: &description),
              let converter = AVAudioConverter(from: input, to: output) else {
            throw audioError("This macOS build does not expose a native Opus encoder through AVAudioConverter.")
        }
        converter.bitRate = AudioConfig.bitRate
        inputFormat = input
        outputFormat = output
        self.converter = converter
    }

    func reset() {
        converter.reset()
    }

    func encode(_ pcm: Data) throws -> Data {
        guard pcm.count == AudioConfig.bytesPerPCMFrame,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: framesPerPacket) else {
            throw audioError("Invalid Opus PCM frame.")
        }
        input.frameLength = framesPerPacket
        guard let destination = input.int16ChannelData?[0] else {
            throw audioError("Could not access the Opus PCM input buffer.")
        }
        pcm.withUnsafeBytes { raw in
            if let source = raw.baseAddress { memcpy(destination, source, pcm.count) }
        }

        let output = AVAudioCompressedBuffer(
            format: outputFormat,
            packetCapacity: 1,
            maximumPacketSize: 1_500
        )
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }
        guard status != .error, output.byteLength > 0 else {
            throw audioError("The native Opus encoder produced no packet.")
        }
        return Data(bytes: output.data, count: Int(output.byteLength))
    }
}

final class OpusDecoder {
    private let compressedFormat: AVAudioFormat
    let pcmFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init() throws {
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(AudioConfig.sampleRate),
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 0,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(AudioConfig.channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let compressed = AVAudioFormat(streamDescription: &description),
              let pcm = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(AudioConfig.sampleRate),
                channels: AVAudioChannelCount(AudioConfig.channels),
                interleaved: false
              ),
              let converter = AVAudioConverter(from: compressed, to: pcm) else {
            throw audioError("This macOS build does not expose a native Opus decoder through AVAudioConverter.")
        }
        compressedFormat = compressed
        pcmFormat = pcm
        self.converter = converter
    }

    func reset() {
        converter.reset()
    }

    func decode(_ packet: Data) throws -> AVAudioPCMBuffer {
        guard !packet.isEmpty, packet.count <= 16_384 else {
            throw audioError("Invalid Opus packet size.")
        }
        let compressed = AVAudioCompressedBuffer(
            format: compressedFormat,
            packetCapacity: 1,
            maximumPacketSize: packet.count
        )
        compressed.byteLength = UInt32(packet.count)
        compressed.packetCount = 1
        packet.copyBytes(
            to: compressed.data.assumingMemoryBound(to: UInt8.self),
            count: packet.count
        )
        guard let descriptions = compressed.packetDescriptions else {
            throw audioError("The Opus compressed buffer has no packet description.")
        }
        descriptions[0] = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(packet.count)
        )
        guard let pcm = AVAudioPCMBuffer(
            pcmFormat: pcmFormat,
            frameCapacity: AVAudioFrameCount(AudioConfig.sampleRate * 120 / 1_000)
        ) else { throw audioError("Could not allocate an Opus output buffer.") }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: pcm, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return compressed
        }
        if let conversionError { throw conversionError }
        guard status != .error, pcm.frameLength > 0 else {
            throw audioError("The native Opus decoder produced no PCM frames.")
        }
        return pcm
    }
}

protocol VoiceCapture: AnyObject {
    var onError: ((String) -> Void)? { get set }
    func start(onBatch: @escaping (Data) -> Void) throws
    func stop()
}

protocol VoicePlayback: AnyObject {
    var onError: ((String) -> Void)? { get set }
    func beginTalk()
    func receiveBatch(_ batch: Data)
    func endTalk(completion: @escaping () -> Void)
    func stopImmediately()
}

final class AudioCapture: VoiceCapture {
    var onError: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "slock.AudioCapture")
    private let targetFormat: AVAudioFormat
    private let encoder: OpusEncoder
    private var converter: AVAudioConverter?
    private var pcmAccumulator = Data()
    private var packetBatch = Data()
    private var batchCount = 0
    private var callback: ((Data) -> Void)?
    private var isRunning = false
    private var generation = UUID()
    private let pendingInput = DispatchSemaphore(value: 8)
    private var configurationObserver: NSObjectProtocol?

    init() throws {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(AudioConfig.sampleRate),
            channels: AVAudioChannelCount(AudioConfig.channels),
            interleaved: true
        ) else { throw audioError("Could not create the microphone conversion format.") }
        targetFormat = target
        encoder = try OpusEncoder()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard self.isRunning else { return }
                self.report("The microphone configuration changed. Release Caps Lock and press again to resume.",
                            onlyIfEngineStopped: true)
            }
        }
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    func start(onBatch: @escaping (Data) -> Void) throws {
        guard !queue.sync(execute: { isRunning }) else { return }
        let input = engine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0,
              hardwareFormat.channelCount > 0,
              let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw audioError("Could not convert the active microphone format to 16 kHz mono.")
        }

        let generation = UUID()
        queue.sync {
            self.generation = generation
            self.converter = converter
            callback = onBatch
            pcmAccumulator.removeAll(keepingCapacity: true)
            packetBatch.removeAll(keepingCapacity: true)
            batchCount = 0
            encoder.reset()
            isRunning = true
        }

        input.installTap(onBus: 0, bufferSize: 1_024, format: hardwareFormat) { [weak self] buffer, _ in
            guard let self, self.pendingInput.wait(timeout: .now()) == .success else { return }
            guard let copy = Self.copyPCMBuffer(buffer) else { self.pendingInput.signal(); return }
            self.queue.async {
                defer { self.pendingInput.signal() }
                guard self.generation == generation else { return }
                self.process(copy)
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            queue.sync { isRunning = false; self.converter = nil; callback = nil }
            throw error
        }
    }

    func stop() {
        guard queue.sync(execute: { isRunning }) else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        queue.sync {
            self.flushBatch()
            self.isRunning = false
            self.generation = UUID()
            self.pcmAccumulator.removeAll(keepingCapacity: true)
            self.converter = nil
            self.callback = nil
        }
    }

    private func process(_ input: AVAudioPCMBuffer) {
        guard isRunning, let converter else { return }
        let ratio = Double(AudioConfig.sampleRate) / input.format.sampleRate
        let capacity = max(64, Int(ceil(Double(input.frameLength) * ratio)) + 64)
        guard let output = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: AVAudioFrameCount(capacity)
        ) else { return }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        if let conversionError {
            report(conversionError.localizedDescription)
            return
        }
        guard status != .error, output.frameLength > 0,
              let samples = output.int16ChannelData?[0] else { return }

        pcmAccumulator.append(
            Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Int16>.size)
        )

        while pcmAccumulator.count >= AudioConfig.bytesPerPCMFrame {
            let frame = Data(pcmAccumulator.prefix(AudioConfig.bytesPerPCMFrame))
            pcmAccumulator.removeFirst(AudioConfig.bytesPerPCMFrame)
            do {
                let opus = try encoder.encode(frame)
                guard opus.count <= Int(UInt16.max) else { continue }
                packetBatch.appendUInt16(UInt16(opus.count))
                packetBatch.append(opus)
                batchCount += 1
                if batchCount >= AudioConfig.packetsPerBatch { flushBatch() }
            } catch {
                report(error.localizedDescription)
            }
        }
    }

    private func flushBatch() {
        guard batchCount > 0, let callback else { return }
        let batch = packetBatch
        packetBatch.removeAll(keepingCapacity: true)
        batchCount = 0
        DispatchQueue.main.async { callback(batch) }
    }

    private func report(_ message: String, onlyIfEngineStopped: Bool = false) {
        let generation = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.queue.sync(execute: { self.generation == generation }) else { return }
            guard !onlyIfEngineStopped || !self.engine.isRunning else { return }
            self.onError?(message)
        }
    }

    private static func copyPCMBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else { return nil }
        copy.frameLength = source.frameLength
        let sourceList = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationList = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(sourceList.count, destinationList.count) {
            guard let sourceData = sourceList[index].mData,
                  let destinationData = destinationList[index].mData else { continue }
            let bytes = min(sourceList[index].mDataByteSize, destinationList[index].mDataByteSize)
            memcpy(destinationData, sourceData, Int(bytes))
            destinationList[index].mDataByteSize = bytes
        }
        return copy
    }
}

final class AudioPlayback: VoicePlayback {
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "slock.AudioPlayback")
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let decoder: OpusDecoder
    private var queuedBuffers = 0
    private var started = false
    private var generation = UUID()
    private var onDrain: (() -> Void)?
    private let pendingBatches = DispatchSemaphore(value: 8)

    init() throws {
        decoder = try OpusDecoder()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: decoder.pcmFormat)
        engine.prepare()
    }

    func beginTalk() {
        queue.async {
            self.generation = UUID()
            self.onDrain = nil
            self.player.stop()
            self.decoder.reset()
            self.queuedBuffers = 0
            self.started = false
            _ = self.ensureEngine()
        }
    }

    func receiveBatch(_ batch: Data) {
        guard batch.count <= AudioConfig.packetsPerBatch * 1_502,
              pendingBatches.wait(timeout: .now()) == .success else { return }
        queue.async {
            defer { self.pendingBatches.signal() }
            guard self.ensureEngine() else { return }
            var offset = 0
            var packetCount = 0
            while offset + 2 <= batch.count {
                guard let length = batch.uint16(at: offset) else { break }
                offset += 2
                let end = offset + Int(length)
                guard length > 0, length <= 1_500, end <= batch.count,
                      packetCount < AudioConfig.packetsPerBatch else { break }
                packetCount += 1
                let packet = Data(batch[offset..<end])
                offset = end
                do {
                    guard self.queuedBuffers < 24 else { break }
                    let pcm = try self.decoder.decode(packet)
                    let generation = self.generation
                    self.player.scheduleBuffer(pcm, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                        guard let self else { return }
                        self.queue.async {
                            guard self.generation == generation else { return }
                            self.queuedBuffers -= 1
                            self.finishDrainIfNeeded()
                        }
                    }
                    self.queuedBuffers += 1
                    if !self.started, self.queuedBuffers >= 6 {
                        self.player.play()
                        self.started = true
                    }
                } catch {
                    self.report(error.localizedDescription)
                }
            }
        }
    }

    func endTalk(completion: @escaping () -> Void) {
        queue.async {
            self.onDrain = completion
            if !self.started, self.queuedBuffers > 0 {
                self.player.play()
                self.started = true
            }
            self.finishDrainIfNeeded()
        }
    }

    private func finishDrainIfNeeded() {
        guard queuedBuffers == 0, let completion = onDrain else { return }
        onDrain = nil
        player.stop()
        engine.stop()
        started = false
        DispatchQueue.main.async(execute: completion)
    }

    func stopImmediately() {
        queue.async {
            self.generation = UUID()
            self.onDrain = nil
            self.player.stop()
            self.engine.stop()
            self.decoder.reset()
            self.queuedBuffers = 0
            self.started = false
        }
    }

    private func ensureEngine() -> Bool {
        if engine.isRunning { return true }
        do {
            try engine.start()
            return true
        } catch {
            report(error.localizedDescription)
            return false
        }
    }

    private func report(_ message: String) {
        let generation = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.queue.sync(execute: { self.generation == generation }) else { return }
            self.onError?(message)
        }
    }
}

// MARK: - Application state machine

final class SlockController {
    enum PendingAttention {
        case none
        case pairing
        case ptt
    }

    let identity: IdentityStore
    let peerStore: PeerStore
    let capsInterceptor: CapsInterceptor
    let led: CapsLED

    var onStateChange: (() -> Void)?

    private let wire: SecureWire
    private let transport: RelayTransport
    private let makeCapture: () throws -> VoiceCapture
    private let makePlayback: () throws -> VoicePlayback
    private let checkAudio: () throws -> Void
    private let requestMicrophone: (@escaping (Bool) -> Void) -> Void
    private var timer: Timer?
    private var audioCapture: VoiceCapture?
    private var audioPlayback: VoicePlayback?

    private(set) var transportState: MQTTClient.State = .stopped
    private(set) var localKeyDown = false
    private(set) var remoteKeyDown = false
    private(set) var peerOnline = false
    private(set) var localTalking = false
    private(set) var remoteTalking = false
    private(set) var incomingPairPublicKey: Data?
    private(set) var outgoingPairPublicKey: Data?
    private(set) var incomingNickname: String?
    private(set) var outgoingRemoteNickname: String?
    private(set) var outgoingLocalNickname: String?
    private(set) var incomingLocalNickname: String?
    var incomingPTTInvite: Bool { peerStore.ptt.incoming != nil }
    var outgoingPTTInvite: Bool { peerStore.ptt.outgoing != nil }
    private var consentGeneration = UUID()
    private var captureWasActive = false
    private var lastLoggedCaptureStatus: String?
    private var lastHandshakeReply: [Data: TimeInterval] = [:]
    fileprivate(set) var lastError: String?

    private var lastPeerSeen: TimeInterval?
    private var lastRemoteKeySeen: TimeInterval?
    private var lastRemoteTalkSeen: TimeInterval?
    private var lastHelloSent : TimeInterval = -.infinity
    private var lastPairRequestSent : TimeInterval = -.infinity
    private var lastPTTInviteSent : TimeInterval = -.infinity
    private var localTalkID: UInt64?
    private var remoteTalkID: UInt64?
    private var remoteTalkEnding = false
    private var restartTalkAfterStop = false

    convenience init() throws {
        let identity = try IdentityStore()
        let transport = MQTTClient(
            brokerURL: SlockConfig.brokerURL,
            clientID: "cl-" + String(identity.routeID.prefix(20)),
            subscriptionTopic: SlockConfig.topicPrefix + identity.routeID
        )
        self.init(identity: identity, peerStore: PeerStore(), capsInterceptor: CapsInterceptor(),
                  led: CapsLED(), transport: transport, startServices: true)
    }

    init(identity: IdentityStore, peerStore: PeerStore, capsInterceptor: CapsInterceptor,
         led: CapsLED, transport: RelayTransport, startServices: Bool = false,
         makeCapture: @escaping () throws -> VoiceCapture = { try AudioCapture() },
         makePlayback: @escaping () throws -> VoicePlayback = { try AudioPlayback() },
         checkAudio: @escaping () throws -> Void = { _ = try OpusEncoder(); _ = try OpusDecoder() },
         requestMicrophone: @escaping (@escaping (Bool) -> Void) -> Void = SlockController.ensureMicrophonePermission) {
        self.identity = identity
        self.peerStore = peerStore
        self.capsInterceptor = capsInterceptor
        self.led = led
        self.transport = transport
        self.makeCapture = makeCapture
        self.makePlayback = makePlayback
        self.checkAudio = checkAudio
        self.requestMicrophone = requestMicrophone
        wire = SecureWire(identity: identity)

        transport.onStateChange = { [weak self] state in
            guard let self else { return }
            self.transportState = state
            if state == .connected {
                self.sendHello(force: true)
                self.retryOutgoingPairRequest(force: true)
                self.retryOutgoingPTTInvite(force: true)
            } else {
                self.peerOnline = false
                self.lastPeerSeen = nil
                self.updateRemoteKey(false)
                self.stopLocalTalk()
                self.stopRemoteTalk(immediate: true)
            }
            self.changed()
        }
        transport.onMessage = { [weak self] _, packet in
            self?.receive(packet)
        }
        capsInterceptor.onKeyState = { [weak self] down in
            self?.handleLocalKey(down)
        }
        capsInterceptor.onStatusChange = { [weak self] in
            guard let self else { return }
            let logStatus = "requested=\(self.capsInterceptor.isRequested) "
                + "active=\(self.capsInterceptor.isActive) "
                + "trusted=\(self.capsInterceptor.permissionGranted) "
                + "error=\(self.capsInterceptor.lastError ?? "none")"
            if logStatus != self.lastLoggedCaptureStatus {
                self.lastLoggedCaptureStatus = logStatus
                NSLog("Caps capture: %@", logStatus)
            }
            if self.capsInterceptor.isActive != self.captureWasActive {
                self.captureWasActive = self.capsInterceptor.isActive
                if self.captureWasActive { self.led.set(false) }
            }
            self.changed()
        }

        guard startServices else { return }
        transport.start()
        if UserDefaults.standard.object(forKey: "CapsLink.captureEnabled") == nil
            || UserDefaults.standard.bool(forKey: "CapsLink.captureEnabled") {
            capsInterceptor.requestPermissionAndStart()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    var peerPublicKey: Data? { peerStore.peerPublicKey }
    var peerShortID: String? { peerStore.peerPublicKey.map(shortIdentifier(for:)) }
    var pttEnabled: Bool { peerStore.pttEnabled }

    var attention: PendingAttention {
        if incomingPairPublicKey != nil { return .pairing }
        if incomingPTTInvite { return .ptt }
        return .none
    }

    var statusText: String {
        if let lastError { return "Error: \(lastError)" }
        if !capsInterceptor.isRequested, !capsInterceptor.isActive { return "Caps Lock capture inactive" }
        if !capsInterceptor.permissionGranted { return "Accessibility permission required" }
        if !capsInterceptor.isActive { return capsInterceptor.lastError ?? "Caps Lock capture inactive" }
        if incomingPairPublicKey != nil { return "Pair request waiting" }
        if incomingPTTInvite { return "PTT invitation waiting" }
        if let outgoingPairPublicKey { return "Pairing request sent to \(peerName(outgoingPairPublicKey))" }
        if peerStore.peerPublicKey == nil { return "Not paired" }
        if transportState != .connected { return transportState.text }
        if localTalking { return "Transmitting" }
        if remoteTalking { return "Receiving" }
        if !peerOnline { return "Paired · peer offline" }
        return peerStore.pttEnabled ? "Connected · PTT enabled" : "Connected"
    }

    func suppliedNickname(for key: Data) -> String {
        if key == incomingPairPublicKey, let incomingNickname { return incomingNickname }
        if key == outgoingPairPublicKey, let outgoingRemoteNickname { return outgoingRemoteNickname }
        return peerStore.entry(for: key)?.ownNickname ?? ""
    }

    func peerName(_ key: Data) -> String {
        let alias = key == incomingPairPublicKey ? incomingLocalNickname
            : (key == outgoingPairPublicKey ? outgoingLocalNickname : nil)
        return RecentPeer(publicKey: key, ownNickname: suppliedNickname(for: key),
                          localNickname: alias ?? peerStore.entry(for: key)?.localNickname ?? "").displayName
    }

    func saveNicknames(own: String, peer: Data?, local: String) {
        peerStore.ownNickname = own
        if let peer {
            peerStore.rename(peer, localNickname: local)
            if peer == incomingPairPublicKey { incomingLocalNickname = PeerProfile.clean(local) }
            if peer == outgoingPairPublicKey { outgoingLocalNickname = PeerProfile.clean(local) }
        }
        sendHello(force: true)
        for key in [incomingPairPublicKey, outgoingPairPublicKey].compactMap({ $0 }) {
            send(kind: .profile, payload: PeerProfile.payload(peerStore.ownNickname), to: key)
        }
        changed()
    }

    func pair(using code: String, localNickname: String? = nil) throws {
        let publicKey = try IdentityStore.publicKey(fromPairingCode: code)
        guard publicKey != identity.publicKey else {
            throw appError("slock.Pairing", "You cannot pair this Mac with itself.")
        }
        if let peer = peerStore.peerPublicKey, peer != publicKey {
            throw appError("slock.Pairing", "Unpair the current peer before pairing another Mac.")
        }
        outgoingPairPublicKey = publicKey
        outgoingLocalNickname = localNickname
        outgoingRemoteNickname = nil
        incomingPairPublicKey = nil
        incomingNickname = nil
        lastError = nil
        retryOutgoingPairRequest(force: true)
        changed()
    }

    func acceptIncomingPair(expected: Data, localNickname: String? = nil) {
        guard let incoming = incomingPairPublicKey, incoming == expected else {
            lastError = "The pair request changed. Reopen the menu to review the current request."
            changed()
            return
        }
        if let peer = peerStore.peerPublicKey, peer != incoming {
            send(kind: .pairReject, payload: Data(), to: incoming)
        } else {
            peerStore.peerPublicKey = incoming
            peerStore.establish(incoming, ownNickname: incomingNickname,
                                localNickname: localNickname ?? incomingLocalNickname)
            peerStore.ptt.disable()
            send(kind: .pairAccept, payload: PeerProfile.payload(peerStore.ownNickname), to: incoming)
            markPeerSeen()
            sendHello(force: true)
        }
        incomingPairPublicKey = nil
        outgoingPairPublicKey = nil
        changed()
    }

    func rejectIncomingPair(expected: Data) {
        guard let incoming = incomingPairPublicKey, incoming == expected else { return }
        send(kind: .pairReject, payload: Data(), to: incoming)
        incomingPairPublicKey = nil
        changed()
    }

    func unpair() {
        if let peer = peerStore.peerPublicKey {
            send(kind: .unpair, payload: Data(), to: peer)
        }
        clearPeer()
    }

    func invitePTT(completion: @escaping (Bool) -> Void) {
        guard let peer = peerStore.peerPublicKey else { completion(false); return }
        guard preparePTT() else { completion(false); return }
        consentGeneration = UUID()
        let generation = consentGeneration
        requestMicrophone { [weak self] granted in
            guard let self else { return }
            guard self.peerStore.peerPublicKey == peer, self.consentGeneration == generation else { return }
            if granted {
                self.peerStore.ptt.invite()
                self.lastPTTInviteSent = -.infinity
                self.retryOutgoingPTTInvite(force: true)
                self.lastError = nil
            } else {
                self.lastError = "Microphone permission is required for PTT."
            }
            self.changed()
            completion(granted)
        }
    }

    func acceptPTTInvite(expected: UInt64, completion: @escaping (Bool) -> Void) {
        guard let invitation = peerStore.ptt.incoming, invitation == expected,
              let peer = peerStore.peerPublicKey else {
            lastError = "The PTT invitation changed. Reopen the menu to review the current invitation."
            changed()
            completion(false)
            return
        }
        guard preparePTT() else { completion(false); return }
        consentGeneration = UUID()
        let generation = consentGeneration
        requestMicrophone { [weak self] granted in
            guard let self else { return }
            guard self.peerStore.peerPublicKey == peer, self.consentGeneration == generation,
                  self.peerStore.ptt.incoming == invitation else { return }
            if granted {
                self.peerStore.ptt.accept(invitation)
                self.sendPTT(.pttAccept, id: invitation, to: peer)
                self.lastError = nil
            } else {
                self.peerStore.ptt.reject(invitation)
                self.sendPTT(.pttReject, id: invitation, to: peer)
                self.lastError = "Microphone permission is required for PTT."
            }
            self.changed()
            completion(granted)
        }
    }

    func rejectPTTInvite(expected: UInt64) {
        guard let peer = peerStore.peerPublicKey, let invitation = peerStore.ptt.incoming,
              invitation == expected else { return }
        consentGeneration = UUID()
        peerStore.ptt.reject(invitation)
        sendPTT(.pttReject, id: invitation, to: peer)
        changed()
    }

    func disablePTT() {
        consentGeneration = UUID()
        peerStore.ptt.disable()
        if let peer = peerStore.peerPublicKey, let revoked = peerStore.ptt.revoked {
            sendPTT(.pttDisable, id: revoked, to: peer)
        }
        lastPTTInviteSent = -.infinity
        stopLocalTalk()
        stopRemoteTalk(immediate: true)
        changed()
    }

    private func sendPTT(_ kind: WireKind, id: UInt64, to peer: Data) {
        var payload = Data()
        payload.appendUInt64(id)
        send(kind: kind, payload: payload, to: peer)
    }

    private func preparePTT() -> Bool {
        do {
            try checkAudio()
            return true
        } catch {
            lastError = "PTT is unavailable: \(error.localizedDescription)"
            changed()
            return false
        }
    }

    func setCaptureEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "CapsLink.captureEnabled")
        if enabled {
            capsInterceptor.requestPermissionAndStart()
        } else {
            handleLocalKey(false)
            remoteKeyDown = false
            lastRemoteKeySeen = nil
            if capsInterceptor.isActive { led.set(false) }
            capsInterceptor.stop()
        }
        changed()
    }

    func retryCapture() {
        guard capsInterceptor.isRequested, !capsInterceptor.isActive else { return }
        capsInterceptor.requestPermissionAndStart()
        changed()
    }

    func selfTestLED() {
        guard capsInterceptor.isActive else {
            lastError = "Enable Caps Lock capture before testing the light."
            changed()
            return
        }
        if !led.set(true) {
            lastError = "This keyboard does not support independent Caps Lock light control. System Caps Lock remains off."
        }
        changed()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.capsInterceptor.isActive else { return }
            self.led.set(self.remoteKeyDown)
            self.changed()
        }
    }

    func clearError() {
        lastError = nil
        changed()
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        if let peer = peerStore.peerPublicKey {
            if localKeyDown {
                localKeyDown = false
                send(kind: .keyState, payload: Data([UInt8(0)]), to: peer)
            }
            if localTalking, let talkID = localTalkID {
                audioCapture?.stop()
                localTalking = false
                localTalkID = nil
                var payload = Data()
                payload.appendUInt64(talkID)
                send(kind: .talkStop, payload: payload, to: peer)
            }
        }
        stopRemoteTalk(immediate: true)
        if capsInterceptor.isActive { led.set(false) }
        capsInterceptor.stop()
        transport.stop()
    }

    func diagnostics() -> String {
        let architecture: String
        #if arch(arm64)
        architecture = "arm64"
        #elseif arch(x86_64)
        architecture = "x86_64"
        #else
        architecture = "unknown"
        #endif
        return [
            "slock \(SlockConfig.appVersion)",
            "This Mac: \(identity.shortID)",
            "Peer: \(peerShortID ?? "none")",
            "Transport: \(transportState.text)",
            "Peer online: \(peerOnline)",
            "PTT enabled: \(pttEnabled)",
            "Accessibility trusted: \(capsInterceptor.permissionGranted)",
            "Input Monitoring allowed: \(CGPreflightListenEventAccess())",
            "Caps capture requested: \(capsInterceptor.isRequested)",
            "Caps capture active: \(capsInterceptor.isActive)",
            "System Caps Lock on: \(CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift))",
            "Caps error: \(capsInterceptor.lastError ?? "none")",
            "LED mode: \(led.mode.rawValue)",
            "App error: \(lastError ?? "none")",
            "OS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Architecture: \(architecture)",
            "Broker: \(SlockConfig.brokerURL.absoluteString)"
        ].joined(separator: "\n")
    }

    private func receive(_ packet: Data) {
        let protected = Set([peerStore.peerPublicKey, outgoingPairPublicKey, incomingPairPublicKey].compactMap { $0 })
        guard let message = wire.open(packet, protecting: protected) else { return }
        let sender = message.senderPublicKey

        if message.kind == .hello {
            if message.needsHelloReply {
                let now = ProcessInfo.processInfo.systemUptime
                if now - (lastHandshakeReply[sender] ?? -10) >= 1 {
                    if lastHandshakeReply.count >= 32 { lastHandshakeReply.removeAll() }
                    lastHandshakeReply[sender] = now
                    send(kind: .hello, payload: helloPayload(for: sender), to: sender)
                }
            }
            guard message.sessionConfirmed else { return }
            if message.newSession, peerStore.peerPublicKey == sender {
                consentGeneration = UUID()
                peerStore.ptt.incoming = nil
                // An outgoing invitation is retried only after this fresh handshake.
                stopLocalTalk()
                stopRemoteTalk(immediate: true)
                updateRemoteKey(false)
            }
            retryOutgoingPairRequest(force: true)
            retryOutgoingPTTInvite(force: true)
        }

        if message.kind == .pairRequest {
            handlePairRequest(from: sender, nickname: PeerProfile.read(message.payload))
            return
        }

        if message.kind == .profile {
            guard let nickname = PeerProfile.read(message.payload) else { return }
            if sender == peerStore.peerPublicKey {
                peerStore.rename(sender, ownNickname: nickname)
            } else if sender == outgoingPairPublicKey {
                outgoingRemoteNickname = nickname
            } else if sender == incomingPairPublicKey {
                incomingNickname = nickname
            } else { return }
            changed()
            return
        }

        if message.kind == .pairAccept || message.kind == .pairReject {
            guard outgoingPairPublicKey == sender else { return }
        } else {
            guard peerStore.peerPublicKey == sender else { return }
        }

        switch message.kind {
        case .pairRequest:
            break
        case .pairAccept:
            peerStore.peerPublicKey = sender
            peerStore.establish(sender, ownNickname: PeerProfile.read(message.payload) ?? outgoingRemoteNickname,
                                localNickname: outgoingLocalNickname)
            peerStore.ptt.disable()
            incomingPairPublicKey = nil
            outgoingPairPublicKey = nil
            markPeerSeen()
            sendHello(force: true)
        case .pairReject:
            outgoingPairPublicKey = nil
            lastError = "Pairing was declined by \(shortIdentifier(for: sender))."
        case .hello:
            markPeerSeen()
            if message.payload.count == 9, let revoked = message.payload.uint64(at: 1) {
                applyPTTRevocation(revoked)
                updateRemoteKey(message.payload[0] != 0)
            }
        case .keyState:
            markPeerSeen()
            if let value = message.payload.first { updateRemoteKey(value != 0) }
        case .profile:
            break
        case .pttInvite:
            guard let invitation = message.payload.uint64(at: 0), message.payload.count == 8 else { return }
            markPeerSeen()
            if invitation == peerStore.ptt.revoked {
                sendPTT(.pttReject, id: invitation, to: sender)
            } else if let accepted = peerStore.ptt.receiveInvitation(invitation) {
                sendPTT(.pttAccept, id: accepted, to: sender)
            }
        case .pttAccept:
            guard let invitation = message.payload.uint64(at: 0), message.payload.count == 8,
                  peerStore.ptt.receiveAcceptance(invitation) else { return }
            markPeerSeen()
            lastPTTInviteSent = -.infinity
        case .pttReject:
            guard let invitation = message.payload.uint64(at: 0), peerStore.ptt.outgoing == invitation else { return }
            peerStore.ptt.outgoing = nil
            lastPTTInviteSent = -.infinity
            lastError = "The PTT invitation was declined."
        case .pttDisable:
            guard let revoked = message.payload.uint64(at: 0), message.payload.count == 8 else { return }
            applyPTTRevocation(revoked)
        case .unpair:
            clearPeer()
        case .talkStart:
            handleRemoteTalkStart(message.payload)
        case .audio:
            handleRemoteAudio(message.payload)
        case .talkStop:
            handleRemoteTalkStop(message.payload)
        }
        changed()
    }

    private func handlePairRequest(from sender: Data, nickname: String?) {
        if let peer = peerStore.peerPublicKey {
            if peer == sender {
                peerStore.rename(sender, ownNickname: nickname)
                send(kind: .pairAccept, payload: PeerProfile.payload(peerStore.ownNickname), to: sender)
                markPeerSeen()
            } else {
                send(kind: .pairReject, payload: Data(), to: sender)
            }
            return
        }
        if incomingPairPublicKey != sender { incomingLocalNickname = nil }
        incomingPairPublicKey = sender
        incomingNickname = nickname
        send(kind: .profile, payload: PeerProfile.payload(peerStore.ownNickname), to: sender)
        changed()
    }

    private func handleLocalKey(_ down: Bool) {
        guard !down || capsInterceptor.isActive else { return }
        guard localKeyDown != down else { return }
        localKeyDown = down
        // A local press is an output for the peer, never for this keyboard.
        // Reassert the remote state in case the keyboard firmware briefly
        // changed its own Caps Lock LED before the remapped event arrived.
        if capsInterceptor.isActive { led.set(remoteKeyDown) }
        if let peer = peerStore.peerPublicKey {
            send(kind: .keyState, payload: Data([down ? UInt8(1) : UInt8(0)]), to: peer)
        }
        if down {
            if peerStore.pttEnabled, peerOnline, transportState == .connected, !remoteTalking {
                if localTalkID != nil, !localTalking { restartTalkAfterStop = true }
                else { startLocalTalk() }
            }
        } else {
            stopLocalTalk()
        }
        changed()
    }

    private func updateRemoteKey(_ down: Bool) {
        guard capsInterceptor.isActive else {
            remoteKeyDown = false
            lastRemoteKeySeen = nil
            return
        }
        remoteKeyDown = down
        lastRemoteKeySeen = down ? ProcessInfo.processInfo.systemUptime : nil
        led.set(down)
    }

    private func startLocalTalk() {
        guard !localTalking,
              localTalkID == nil,
              !remoteTalking,
              localKeyDown,
              capsInterceptor.isActive,
              peerOnline,
              transportState == .connected,
              peerStore.pttEnabled,
              let peer = peerStore.peerPublicKey else { return }
        do {
            let capture = try audioCapture ?? makeCapture()
            let talkID = randomUInt64()
            capture.onError = { [weak self] message in
                guard let self, self.localTalkID == talkID else { return }
                self.lastError = "Audio capture: \(message)"
                self.stopLocalTalk()
                self.changed()
            }
            audioCapture = capture
            audioPlayback?.stopImmediately()
            let agreement = peerStore.ptt.active
            localTalkID = talkID
            localTalking = true
            var startPayload = Data()
            startPayload.appendUInt64(talkID)
            send(kind: .talkStart, payload: startPayload, to: peer)
            try capture.start { [weak self] batch in
                guard let self, self.localTalkID == talkID,
                      self.peerStore.peerPublicKey == peer,
                      self.peerStore.ptt.active == agreement else { return }
                var payload = Data()
                payload.appendUInt64(talkID)
                payload.append(batch)
                self.send(kind: .audio, payload: payload, to: peer)
            }
        } catch {
            localTalking = false
            if let currentTalkID = localTalkID {
                var payload = Data()
                payload.appendUInt64(currentTalkID)
                send(kind: .talkStop, payload: payload, to: peer)
            }
            localTalkID = nil
            lastError = "Could not start PTT: \(error.localizedDescription)"
        }
    }

    private func stopLocalTalk() {
        guard localTalking, let talkID = localTalkID else { return }
        let peer = peerStore.peerPublicKey
        restartTalkAfterStop = false
        audioCapture?.stop()
        localTalking = false
        DispatchQueue.main.async { [weak self] in
            guard let self, self.localTalkID == talkID else { return }
            if let peer, self.peerStore.peerPublicKey == peer {
                var payload = Data()
                payload.appendUInt64(talkID)
                self.send(kind: .talkStop, payload: payload, to: peer)
            }
            self.localTalkID = nil
            if self.restartTalkAfterStop {
                self.restartTalkAfterStop = false
                self.startLocalTalk()
            }
            self.changed()
        }
    }

    private func handleRemoteTalkStart(_ payload: Data) {
        guard peerStore.pttEnabled,
              let talkID = payload.uint64(at: 0),
              let peer = peerStore.peerPublicKey else { return }
        guard remoteTalkID != talkID else { return }
        markPeerSeen()

        if localTalking {
            if dataLexicographicallyPrecedes(identity.publicKey, peer) { return }
            stopLocalTalk()
        }

        do {
            let playback = try audioPlayback ?? makePlayback()
            playback.onError = { [weak self] message in
                guard let self, self.remoteTalkID == talkID else { return }
                self.lastError = "Audio playback: \(message)"
                self.stopRemoteTalk(immediate: true)
                self.changed()
            }
            audioPlayback = playback
            remoteTalkID = talkID
            remoteTalking = true
            remoteTalkEnding = false
            lastRemoteTalkSeen = ProcessInfo.processInfo.systemUptime
            playback.beginTalk()
        } catch {
            lastError = "Could not start PTT playback: \(error.localizedDescription)"
        }
    }

    private func handleRemoteAudio(_ payload: Data) {
        guard remoteTalking, !remoteTalkEnding,
              let talkID = payload.uint64(at: 0),
              talkID == remoteTalkID,
              payload.count > 8 else { return }
        markPeerSeen()
        lastRemoteTalkSeen = ProcessInfo.processInfo.systemUptime
        audioPlayback?.receiveBatch(Data(payload.dropFirst(8)))
    }

    private func handleRemoteTalkStop(_ payload: Data) {
        guard let talkID = payload.uint64(at: 0), talkID == remoteTalkID else { return }
        stopRemoteTalk(immediate: false)
    }

    private func stopRemoteTalk(immediate: Bool) {
        guard remoteTalking || remoteTalkID != nil else { return }
        if immediate {
            audioPlayback?.stopImmediately()
        } else {
            guard !remoteTalkEnding else { return }
            remoteTalkEnding = true
            let talkID = remoteTalkID
            audioPlayback?.endTalk { [weak self] in
                guard let self, self.remoteTalkID == talkID, self.remoteTalkEnding else { return }
                self.remoteTalking = false
                self.remoteTalkID = nil
                self.remoteTalkEnding = false
                self.lastRemoteTalkSeen = nil
                if self.localKeyDown { self.startLocalTalk() }
                self.changed()
            }
            return
        }
        remoteTalking = false
        remoteTalkID = nil
        remoteTalkEnding = false
        lastRemoteTalkSeen = nil
    }

    private func retryOutgoingPairRequest(force: Bool = false) {
        guard transportState == .connected, let target = outgoingPairPublicKey else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || (now - lastPairRequestSent) >= 10 else { return }
        lastPairRequestSent = now
        send(kind: .pairRequest, payload: PeerProfile.payload(peerStore.ownNickname), to: target)
    }

    private func retryOutgoingPTTInvite(force: Bool = false) {
        guard transportState == .connected,
              outgoingPTTInvite,
              let peer = peerStore.peerPublicKey else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || (now - lastPTTInviteSent) >= 10 else { return }
        lastPTTInviteSent = now
        if let invitation = peerStore.ptt.outgoing { sendPTT(.pttInvite, id: invitation, to: peer) }
    }

    private func sendHello(force: Bool = false) {
        guard transportState == .connected, let peer = peerStore.peerPublicKey else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || (now - lastHelloSent) >= SlockConfig.helloInterval else { return }
        lastHelloSent = now
        send(kind: .hello, payload: helloPayload(for: peer), to: peer)
        send(kind: .profile, payload: PeerProfile.payload(peerStore.ownNickname), to: peer)
    }

    private func helloPayload(for peer: Data) -> Data {
        guard peerStore.peerPublicKey == peer else { return Data() }
        var payload = Data([localKeyDown ? UInt8(1) : UInt8(0)])
        payload.appendUInt64(peerStore.ptt.revoked ?? 0)
        return payload
    }

    private func applyPTTRevocation(_ id: UInt64) {
        let before = peerStore.ptt.active
        peerStore.ptt.receiveRevocation(id)
        if before != peerStore.ptt.active {
            consentGeneration = UUID()
            stopLocalTalk()
            stopRemoteTalk(immediate: true)
        }
    }

    private func send(kind: WireKind, payload: Data, to peer: Data) {
        guard transportState == .connected else { return }
        let protected = Set([peerStore.peerPublicKey, outgoingPairPublicKey, incomingPairPublicKey].compactMap { $0 })
        do {
            if kind != .hello, !wire.hasSession(with: peer) {
                let hello = try wire.seal(kind: .hello, payload: helloPayload(for: peer), to: peer, protecting: protected)
                transport.publish(topic: SlockConfig.topicPrefix + routeIdentifier(for: peer), payload: hello)
                return
            }
            let packet = try wire.seal(kind: kind, payload: payload, to: peer, protecting: protected)
            transport.publish(
                topic: SlockConfig.topicPrefix + routeIdentifier(for: peer),
                payload: packet
            )
        } catch {
            lastError = error.localizedDescription
            changed()
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        sendHello()
        retryOutgoingPairRequest()
        retryOutgoingPTTInvite()

        if localKeyDown, let peer = peerStore.peerPublicKey {
            send(kind: .keyState, payload: Data([UInt8(1)]), to: peer)
        }

        if remoteKeyDown, let last = lastRemoteKeySeen,
           (now - last) > SlockConfig.remoteKeyTimeout {
            updateRemoteKey(false)
        }

        if remoteTalking, let last = lastRemoteTalkSeen,
           (now - last) > SlockConfig.remoteTalkTimeout {
            stopRemoteTalk(immediate: true)
        }

        let wasOnline = peerOnline
        if let lastPeerSeen {
            peerOnline = (now - lastPeerSeen) <= SlockConfig.onlineTimeout
        } else {
            peerOnline = false
        }
        if wasOnline && !peerOnline {
            updateRemoteKey(false)
            stopRemoteTalk(immediate: true)
            stopLocalTalk()
        }
        changed()
    }

    private func markPeerSeen() {
        lastPeerSeen = ProcessInfo.processInfo.systemUptime
        peerOnline = true
    }

    private func clearPeer() {
        stopLocalTalk()
        stopRemoteTalk(immediate: true)
        updateRemoteKey(false)
        peerStore.peerPublicKey = nil
        incomingPairPublicKey = nil
        outgoingPairPublicKey = nil
        consentGeneration = UUID()
        incomingNickname = nil
        outgoingRemoteNickname = nil
        outgoingLocalNickname = nil
        incomingLocalNickname = nil
        peerStore.ptt.incoming = nil
        peerStore.ptt.outgoing = nil
        lastPTTInviteSent = -.infinity
        lastPeerSeen = nil
        peerOnline = false
        changed()
    }

    private static func ensureMicrophonePermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    private func changed() {
        DispatchQueue.main.async { [weak self] in self?.onStateChange?() }
    }
}

// MARK: - Menu-bar interface

enum FireflyIcon {
    enum TailState {
        case idle
        case outgoing
        case notification
    }

    static let idle = makeImage(tail: .idle)
    static let outgoing = makeImage(tail: .outgoing)
    static let notification = makeImage(tail: .notification)

    static func tailState(localActive: Bool, attention: Bool) -> TailState {
        if localActive { return .outgoing }
        if attention { return .notification }
        return .idle
    }

    static func image(tail: TailState) -> NSImage {
        switch tail {
        case .idle: return idle
        case .outgoing: return outgoing
        case .notification: return notification
        }
    }

    private static func makeImage(tail: TailState) -> NSImage {
        // Vector artwork stays crisp at both Retina and standard scale. Idle
        // artwork is a template; outgoing and notification states keep an
        // adaptive body with a colored tail.
        let isColored = tail == .outgoing || tail == .notification
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: 9, yBy: 9)
            transform.rotate(byDegrees: 45)
            transform.scale(by: 0.17)
            transform.translateX(by: -60, yBy: -75)
            transform.concat()
            let bodyColor = isColored ? NSColor.labelColor : NSColor.black
            bodyColor.setFill()
            bodyColor.setStroke()
            NSBezierPath(ovalIn: NSRect(x: 45, y: 5, width: 30, height: 30)).fill()

            let left = NSBezierPath()
            left.move(to: NSPoint(x: 54, y: 42))
            left.curve(to: NSPoint(x: 9, y: 79), controlPoint1: NSPoint(x: 48, y: 34), controlPoint2: NSPoint(x: 17, y: 60))
            left.curve(to: NSPoint(x: 32, y: 97), controlPoint1: NSPoint(x: 2, y: 96), controlPoint2: NSPoint(x: 18, y: 108))
            left.curve(to: NSPoint(x: 54, y: 42), controlPoint1: NSPoint(x: 47, y: 85), controlPoint2: NSPoint(x: 58, y: 53))
            left.close()
            left.fill()
            let right = left.copy() as! NSBezierPath
            let mirror = NSAffineTransform()
            mirror.translateX(by: 120, yBy: 0)
            mirror.scaleX(by: -1, yBy: 1)
            right.transform(using: mirror as AffineTransform)
            right.fill()

            switch tail {
            case .outgoing:
                NSColor(srgbRed: 0.72, green: 1.0, blue: 0.18, alpha: 1).setFill()
                NSBezierPath(ovalIn: NSRect(x: 37, y: 98, width: 46, height: 46)).fill()
            case .notification:
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: NSRect(x: 37, y: 98, width: 46, height: 46)).fill()
            case .idle:
                let tail = NSBezierPath(ovalIn: NSRect(x: 41, y: 102, width: 38, height: 38))
                tail.lineWidth = 8
                tail.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = !isColored
        image.accessibilityDescription = "Dit, the slock firefly"
        return image
    }
}

final class PairingForm: NSView {
    let ownNickname = NSTextField()
    let peerCode = NSTextField()
    let localNickname = NSTextField()

    init(ownCode: String, ownNickname: String, peerCode: String, suppliedName: String,
         localNickname: String, codeEditable: Bool, copyTarget: AnyObject?, copyAction: Selector?) {
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 310))
        func field(_ field: NSTextField, label: String, value: String, y: CGFloat) {
            let title = NSTextField(labelWithString: label)
            title.frame = NSRect(x: 0, y: y + 32, width: 460, height: 20)
            addSubview(title)
            field.frame = NSRect(x: 0, y: y, width: 460, height: 26)
            field.stringValue = value
            field.setAccessibilityLabel(label)
            addSubview(field)
        }
        field(self.ownNickname, label: "Your nickname (shared)", value: ownNickname, y: 250)
        self.ownNickname.placeholderString = "e.g. Studio Mac — optional"
        let code = NSTextField()
        field(code, label: "Your pairing code", value: ownCode, y: 176)
        code.frame.size.width = 365
        code.isEditable = false
        code.isSelectable = true
        code.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let copy = NSButton(title: "Copy", target: copyTarget, action: copyAction)
        copy.bezelStyle = .rounded
        copy.frame = NSRect(x: 375, y: 175, width: 85, height: 28)
        addSubview(copy)
        field(self.peerCode, label: "Other Mac's pairing code", value: peerCode, y: 102)
        self.peerCode.placeholderString = "Paste their code here (CL1.…)"
        self.peerCode.isEditable = codeEditable
        self.peerCode.isSelectable = true
        field(self.localNickname, label: "Your nickname for them (only on this Mac)",
              value: localNickname, y: 8)
        self.localNickname.isEditable = suppliedName.isEmpty
        self.localNickname.placeholderString = "Optional — used if they haven't provided a name"
        if !suppliedName.isEmpty {
            let provided = NSTextField(labelWithString: "Their nickname: \(suppliedName)")
            provided.frame = NSRect(x: 0, y: 72, width: 460, height: 20)
            provided.textColor = .secondaryLabelColor
            addSubview(provided)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var controller: SlockController!
    private var instanceLock: SingleInstanceLock?
    private var optionOnlyItems: [NSMenuItem] = []
    private var menuModifierTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do {
            instanceLock = try SingleInstanceLock()
            controller = try SlockController()
        } catch {
            showAlert(title: "slock could not start", message: error.localizedDescription)
            NSApp.terminate(nil)
            return
        }

        controller.onStateChange = { [weak self] in self?.updateStatusItem() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusItem()
        enableLaunchAtLoginByDefault()
        updateStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuModifierTimer?.invalidate()
        controller?.shutdown()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateOptionOnlyItems()
        menuModifierTimer?.invalidate()
        // Menus track events in their own run-loop mode. Poll only while open
        // so Option can reveal these items without reopening the menu.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updateOptionOnlyItems()
        }
        menuModifierTimer = timer
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    func menuDidClose(_ menu: NSMenu) {
        menuModifierTimer?.invalidate()
        menuModifierTimer = nil
    }

    private func updateOptionOnlyItems() {
        let hidden = !NSEvent.modifierFlags.contains(.option)
        for item in optionOnlyItems where item.isHidden != hidden {
            item.isHidden = hidden
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button, let controller else { return }
        let needsAttention: Bool
        switch controller.attention {
        case .pairing, .ptt:
            needsAttention = true
        case .none:
            needsAttention = false
        }
        let tail = FireflyIcon.tailState(
            localActive: controller.localKeyDown || controller.localTalking,
            attention: needsAttention
        )
        button.image = FireflyIcon.image(tail: tail)
        button.title = ""
        button.toolTip = "slock — \(controller.statusText)"
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        optionOnlyItems.removeAll()
        addDisabled("slock — \(controller.statusText)")
        optionOnlyItems.append(addDisabled("This Mac: \(controller.identity.shortID)"))
        menu.addItem(.separator())

        add("Pairing…", #selector(showPairing))
        let recent = NSMenu(title: "Recent")
        let recentItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = recent
        menu.addItem(recentItem)
        if controller.peerStore.recent.isEmpty {
            let empty = NSMenuItem(title: "No recent pairings", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recent.addItem(empty)
        }
        for peer in controller.peerStore.recent {
            let duplicate = controller.peerStore.recent.filter { $0.displayName == peer.displayName }.count > 1
            let title = duplicate ? "\(peer.displayName) · \(peer.pairingCode.suffix(6))" : peer.displayName
            let item = NSMenuItem(title: title, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = peer.publicKey
            item.state = peer.publicKey == controller.peerPublicKey ? .on : .off
            recent.addItem(item)
        }
        if controller.peerPublicKey != nil {
            addDisabled("Paired with \(controller.peerName(controller.peerPublicKey!))")
            add("Unpair…", #selector(unpair))
        }

        if let incoming = controller.incomingPairPublicKey {
            menu.addItem(.separator())
            add("Review Pair Request from \(controller.peerName(incoming))…", #selector(acceptPair(_:))).representedObject = incoming
            add("Reject Pair Request", #selector(rejectPair(_:))).representedObject = incoming
        }

        if controller.peerPublicKey != nil {
            menu.addItem(.separator())
            if controller.pttEnabled {
                let item = add("PTT Enabled", #selector(disablePTT))
                item.state = .on
                item.toolTip = "Select to disable push-to-talk for both peers."
            } else if let invitation = controller.peerStore.ptt.incoming {
                add("Accept PTT Invitation", #selector(acceptPTT(_:))).representedObject = NSNumber(value: invitation)
                add("Reject PTT Invitation", #selector(rejectPTT(_:))).representedObject = NSNumber(value: invitation)
            } else if controller.outgoingPTTInvite {
                addDisabled("PTT invitation sent")
            } else {
                add("Invite Peer to Enable PTT", #selector(invitePTT))
            }
        }

        menu.addItem(.separator())
        let capturePending = controller.capsInterceptor.isRequested && !controller.capsInterceptor.isActive
        let capture = add("Capture Caps Lock", #selector(toggleCapture))
        capture.state = controller.capsInterceptor.isActive ? .on : (capturePending ? .mixed : .off)
        if capturePending {
            add("Retry Capture", #selector(retryCapture))
            add("Open Accessibility Settings…", #selector(openAccessibilitySettings))
            add("Open Input Monitoring Settings…", #selector(openInputMonitoringSettings))
        }
        let login = add("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = launchAtLoginEnabled ? .on : .off
        if SMAppService.mainApp.status == .requiresApproval {
            addDisabled("Login launch requires approval in System Settings")
        }
        optionOnlyItems.append(add("Test Caps Lock Light", #selector(testLED)))
        optionOnlyItems.append(add("Diagnostics…", #selector(showDiagnostics)))
        if controller.lastError != nil {
            add("Clear Error", #selector(clearError))
        }
        menu.addItem(.separator())
        add("Quit slock", #selector(quit))
        updateOptionOnlyItems()
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @discardableResult
    private func addDisabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
        return item
    }

    @objc private func copyPairingCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(controller.identity.pairingCode, forType: .string)
    }

    @objc private func showPairing() {
        presentPairing(key: controller.incomingPairPublicKey ?? controller.peerPublicKey ?? controller.outgoingPairPublicKey,
                       incoming: controller.incomingPairPublicKey != nil)
    }

    @objc private func openRecent(_ item: NSMenuItem) {
        guard let key = item.representedObject as? Data else { return }
        presentPairing(key: key)
    }

    private func presentPairing(key: Data?, incoming: Bool = false) {
        let alert = NSAlert()
        alert.messageText = "Pairing"
        let current = key != nil && key == controller.peerPublicKey
        let suppliedName = key.map { controller.suppliedNickname(for: $0) }
        alert.informativeText = incoming
            ? "Review this request and compare pairing codes with the other person before accepting."
            : "Share your code, or add another Mac. Your nickname is shared; a nickname you give them stays on this Mac."
        alert.addButton(withTitle: current ? "Save Nicknames" : (incoming ? "Accept Pairing" : "Send Pairing Request"))
        if !current { alert.addButton(withTitle: "Save Nicknames") }
        alert.addButton(withTitle: "Close")

        let form = PairingForm(ownCode: controller.identity.pairingCode,
                               ownNickname: controller.peerStore.ownNickname,
                               peerCode: key.map { "CL1." + $0.base64URL } ?? "",
                               suppliedName: suppliedName ?? "",
                               localNickname: (incoming ? controller.incomingLocalNickname : nil)
                                    ?? (key == controller.outgoingPairPublicKey ? controller.outgoingLocalNickname : nil)
                                    ?? key.flatMap { controller.peerStore.entry(for: $0)?.localNickname } ?? "",
                               codeEditable: key == nil,
                               copyTarget: self, copyAction: #selector(copyPairingCode))
        alert.accessoryView = form
        alert.window.initialFirstResponder = key == nil ? form.peerCode : form.ownNickname
        NSApp.activate(ignoringOtherApps: true)

        while true {
            let response = alert.runModal()
            let saveOnly = current ? response == .alertFirstButtonReturn : response == .alertSecondButtonReturn
            guard saveOnly || response == .alertFirstButtonReturn else { return }
            do {
                let code = form.peerCode.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let target = code.isEmpty ? nil : try IdentityStore.publicKey(fromPairingCode: code)
                guard target != controller.identity.publicKey else {
                    throw appError("slock.Pairing", "You cannot pair this Mac with itself.")
                }
                if !saveOnly {
                    guard let target else { throw appError("slock.Pairing", "Paste the other Mac's pairing code first.") }
                    if let active = controller.peerPublicKey, active != target {
                        let confirm = NSAlert()
                        confirm.messageText = "Switch to \(controller.peerName(target))?"
                        confirm.informativeText = "This disconnects \(controller.peerName(active)) and sends a new pairing request."
                        confirm.addButton(withTitle: "Switch")
                        confirm.addButton(withTitle: "Cancel")
                        guard confirm.runModal() == .alertFirstButtonReturn else { continue }
                        controller.unpair()
                    }
                }
                controller.saveNicknames(own: form.ownNickname.stringValue,
                                         peer: target, local: form.localNickname.stringValue)
                if saveOnly { return }
                if incoming, let target {
                    controller.acceptIncomingPair(expected: target, localNickname: form.localNickname.stringValue)
                } else {
                    try controller.pair(using: code, localNickname: form.localNickname.stringValue)
                }
                return
            } catch {
                alert.informativeText = error.localizedDescription
            }
        }
    }

    @objc private func acceptPair(_ item: NSMenuItem) {
        guard let expected = item.representedObject as? Data,
              expected == controller.incomingPairPublicKey else { return }
        presentPairing(key: expected, incoming: true)
    }

    @objc private func rejectPair(_ item: NSMenuItem) {
        guard let expected = item.representedObject as? Data else { return }
        controller.rejectIncomingPair(expected: expected)
    }

    @objc private func unpair() {
        let alert = NSAlert()
        alert.messageText = "Unpair \(controller.peerShortID ?? "this peer")?"
        alert.informativeText = "Caps Lock mirroring and PTT will stop on both Macs."
        alert.addButton(withTitle: "Unpair")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            controller.unpair()
        }
    }

    @objc private func invitePTT() {
        controller.invitePTT { [weak self] granted in
            if !granted {
                self?.showAlert(
                    title: "Could not enable push-to-talk",
                    message: self?.controller.lastError ?? "Enable slock under System Settings → Privacy & Security → Microphone, then try again."
                )
            }
        }
    }

    @objc private func acceptPTT(_ item: NSMenuItem) {
        guard let expected = item.representedObject as? NSNumber else { return }
        controller.acceptPTTInvite(expected: expected.uint64Value) { [weak self] granted in
            if !granted {
                self?.showAlert(
                    title: "Could not enable push-to-talk",
                    message: self?.controller.lastError ?? "Enable slock under System Settings → Privacy & Security → Microphone, then accept again."
                )
            }
        }
    }

    @objc private func rejectPTT(_ item: NSMenuItem) {
        guard let expected = item.representedObject as? NSNumber else { return }
        controller.rejectPTTInvite(expected: expected.uint64Value)
    }

    @objc private func disablePTT() {
        controller.disablePTT()
    }

    @objc private func toggleCapture() {
        controller.setCaptureEnabled(!controller.capsInterceptor.isRequested)
    }

    @objc private func retryCapture() {
        controller.retryCapture()
    }

    @objc private func openAccessibilitySettings() {
        guard let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(settings)
    }

    @objc private func openInputMonitoringSettings() {
        guard let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else { return }
        NSWorkspace.shared.open(settings)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if launchAtLoginEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showAlert(title: "Could not change Launch at Login", message: error.localizedDescription)
        }
    }

    @objc private func testLED() {
        controller.selfTestLED()
    }

    @objc private func showDiagnostics() {
        showAlert(title: "slock Diagnostics", message: controller.diagnostics())
    }

    @objc private func clearError() {
        controller.clearError()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func enableLaunchAtLoginByDefault() {
        let key = "CapsLink.didConfigureLaunchAtLogin"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            if SMAppService.mainApp.status == .notRegistered {
                try SMAppService.mainApp.register()
            }
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            controller.lastError = "Launch at Login was not enabled automatically: \(error.localizedDescription)"
            updateStatusItem()
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

final class SingleInstanceLock {
    private let descriptor: Int32

    init(directory: URL? = nil) throws {
        let support = try directory ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(SlockConfig.storageName, isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        descriptor = open(support.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw appError("slock.Lock", "Could not open the application lock.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw appError("slock.Lock", "slock is already running. Use its existing menu-bar item.")
        }
    }

    deinit { close(descriptor) }
}

private var terminationSources: [DispatchSourceSignal] = []

private func installProcessCleanupHandlers() {
    atexit { emergencyRestoreMapping() }
    for number in [SIGTERM, SIGINT] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { NSApplication.shared.terminate(nil) }
        source.resume()
        terminationSources.append(source)
    }
}

#if !CAPSLINK_TESTING
@main
enum SlockApp {
    static func main() {
        installProcessCleanupHandlers()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif
