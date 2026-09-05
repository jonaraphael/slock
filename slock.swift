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
    static let appVersion = "0.2.7"
    static let protocolVersion: UInt8 = 2
    static let brokerURL = URL(string: "wss://test.mosquitto.org:8081/mqtt")!
    static let topicPrefix = "capslink/v2/inbox/"
    static let capsHIDUsage: UInt64 = 0x700000039
    static let f18HIDUsage: UInt64 = 0x70000006D
    static let f18CGKeyCode: Int64 = 79
    static let helloInterval: TimeInterval = 10
    static let onlineTimeout: TimeInterval = 25
    static let remoteKeyTimeout: TimeInterval = 2.5
    static let lightPlaybackDelay: TimeInterval = 1
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
    let bytes = Array(digest.prefix(16))
    return stride(from: 0, to: bytes.count, by: 4).map { offset in
        bytes[offset..<(offset + 4)].map { String(format: "%02X", $0) }.joined()
    }.joined(separator: "-")
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

// MARK: - Release updates

// Metadata only. Installing an ad-hoc signed download cannot authenticate its
// publisher. Downloads are left to the browser and macOS's normal launch checks.
final class ReleaseRequest: NSObject, URLSessionDataDelegate {
    static let maximumBytes = 128 * 1024
    private var bytes = Data()
    private var exceededLimit = false
    private var completion: UpdateChecker.Completion?
    private var session: URLSession?

    static func fetch(_ request: URLRequest, configuration: URLSessionConfiguration = .ephemeral,
                      completion: @escaping UpdateChecker.Completion) {
        let fetch = ReleaseRequest()
        fetch.completion = completion
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: fetch, delegateQueue: nil)
        fetch.session = session
        session.dataTask(with: request).resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        exceededLimit = response.expectedContentLength > Int64(Self.maximumBytes)
        completionHandler(exceededLimit ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !exceededLimit, data.count <= Self.maximumBytes - bytes.count else {
            exceededLimit = true
            dataTask.cancel()
            return
        }
        bytes.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let failure = exceededLimit ? URLError(.dataLengthExceedsMaximum) : error
        completion?(failure == nil ? bytes : nil, task.response, failure)
        completion = nil
        session.invalidateAndCancel()
        self.session = nil
    }
}

struct ReleaseVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ tag: String) {
        let text = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  part.count == 1 || part.first != "0" else { return nil }
            return Int(part)
        }
        guard numbers.count == 3 else { return nil }
        major = numbers[0]
        minor = numbers[1]
        patch = numbers[2]
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

struct SlockUpdate: Equatable {
    let tag: String

    var releaseURL: URL? {
        guard tag.hasPrefix("v"), ReleaseVersion(tag) != nil else { return nil }
        return URL(string: "https://github.com/jonaraphael/slock/releases/tag/\(tag)")
    }

    static func available(in data: Data, currentVersion: String) throws -> SlockUpdate? {
        struct Release: Decodable {
            let tag_name: String
            let draft: Bool
            let prerelease: Bool
        }
        guard data.count <= ReleaseRequest.maximumBytes else {
            throw appError("slock.Update", "The release response exceeded its limit.")
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease, release.tag_name.hasPrefix("v"),
              let remote = ReleaseVersion(release.tag_name),
              let local = ReleaseVersion(currentVersion), remote > local else { return nil }
        return SlockUpdate(tag: release.tag_name)
    }
}

// Owned and called by the main thread. Network work never blocks menu tracking.
final class UpdateChecker {
    typealias Completion = (Data?, URLResponse?, Error?) -> Void
    typealias Fetch = (URLRequest, @escaping Completion) -> Void
    static let checkInterval: TimeInterval = 60 * 60
    static let retryInterval: TimeInterval = 5 * 60
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/jonaraphael/slock/releases/latest")!

    private(set) var availableUpdate: SlockUpdate?
    var onChange: (() -> Void)?
    private let currentVersion: String
    private let fetch: Fetch
    private let now: () -> Date
    private var nextCheck = Date.distantPast
    private var checking = false

    init(currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
             ?? SlockConfig.appVersion,
         now: @escaping () -> Date = Date.init,
         fetch: @escaping Fetch = { request, completion in
             ReleaseRequest.fetch(request, completion: completion)
         }) {
        self.currentVersion = currentVersion
        self.now = now
        self.fetch = fetch
    }

    func checkIfNeeded() {
        guard !checking, now() >= nextCheck else { return }
        checking = true
        var request = URLRequest(url: Self.latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("slock/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        fetch(request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                self.nextCheck = self.now().addingTimeInterval(Self.retryInterval)
                // Keep a known update through temporary network/rate-limit failures.
                guard error == nil, let http = response as? HTTPURLResponse else { return }
                let update: SlockUpdate?
                if http.statusCode == 404 {
                    update = nil
                } else if http.statusCode == 200, let data {
                    do { update = try SlockUpdate.available(in: data, currentVersion: self.currentVersion) }
                    catch { return }
                } else {
                    return
                }
                self.nextCheck = self.now().addingTimeInterval(Self.checkInterval)
                guard update != self.availableUpdate else { return }
                self.availableUpdate = update
                self.onChange?()
            }
        }
    }
}

// MARK: - Local identity

// Open relative to a verified private directory and never follow a final symlink.
// Descriptor checks also reject FIFOs, devices and hard links before reading or
// changing permissions. Close-on-exec keeps helpers from inheriting the lock/key.
final class PrivateStorage {
    let descriptor: Int32

    init(directory: URL? = nil) throws {
        let support = try directory ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(SlockConfig.storageName, isDirectory: true)
        guard mkdir(support.path, 0o700) == 0 || errno == EEXIST else {
            throw appError("slock.Storage", "Could not create the private storage directory.")
        }
        let fd = open(support.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw appError("slock.Storage", "Private storage must be a real directory, not a link.") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFDIR, fchmod(fd, 0o700) == 0 else {
            close(fd)
            throw appError("slock.Storage", "Private storage must be owned by this user and accessible only to them.")
        }
        descriptor = fd
    }

    deinit { close(descriptor) }

    func openFile(_ name: String) throws -> (descriptor: Int32, created: Bool) {
        let flags = O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        var fd = openat(descriptor, name, flags | O_CREAT | O_EXCL, 0o600)
        let created = fd >= 0
        if fd < 0, errno == EEXIST { fd = openat(descriptor, name, flags) }
        guard fd >= 0 else { throw appError("slock.Storage", "Could not safely open \(name).") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG, fchmod(fd, 0o600) == 0 else {
            close(fd)
            throw appError("slock.Storage", "\(name) must be a private regular file owned by this user, without links.")
        }
        return (fd, created)
    }
}

final class IdentityStore {
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    let publicKey: Data
    let shortID: String
    let routeID: String
    let pairingCode: String

    init(directory: URL? = nil) throws {
        let storage = try PrivateStorage(directory: directory)
        let file = try storage.openFile("identity.key")
        defer { close(file.descriptor) }
        if !file.created {
            var info = stat()
            var stored = Data(count: 32)
            guard fstat(file.descriptor, &info) == 0, info.st_size == 32,
                  stored.withUnsafeMutableBytes({ read(file.descriptor, $0.baseAddress, 32) }) == 32 else {
                throw appError("slock.Identity", "The saved identity is invalid. Restore it from a backup or remove it and pair again.")
            }
            privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: stored)
        } else {
            privateKey = Curve25519.KeyAgreement.PrivateKey()
            guard privateKey.rawRepresentation.withUnsafeBytes({ write(file.descriptor, $0.baseAddress, 32) }) == 32,
                  fsync(file.descriptor) == 0 else {
                throw appError("slock.Identity", "Could not save the private identity key.")
            }
        }

        publicKey = privateKey.publicKey.rawRepresentation
        shortID = shortIdentifier(for: publicKey)
        routeID = routeIdentifier(for: publicKey)
        pairingCode = "CL1." + publicKey.base64URL
    }

    static func publicKey(fromPairingCode input: String) throws -> Data {
        guard input.utf8.count <= 256 else {
            throw appError("slock.Identity", "That is not a valid slock pairing code.")
        }
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

    static let maximumCharacters = 48
    static let maximumScalars = 192

    // Peer-supplied names are shown in menus and confirmation dialogs. Remove
    // everything that can reorder, hide or split displayed text: controls,
    // format characters (bidirectional overrides, zero-width characters), line
    // and paragraph separators, and private/surrogate code points. Collapse
    // every run of whitespace so a name cannot imitate a menu separator. Only
    // the joiners used by emoji and some scripts are kept, and a name with no
    // visible character is treated as empty. Names are still not verification.
    static func clean(_ value: String) -> String {
        var output = String.UnicodeScalarView()
        var pendingSpace = false
        var visible = false
        for scalar in value.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .spaceSeparator:
                let joiner = scalar == "\u{200C}" || scalar == "\u{200D}"
                if joiner, visible { output.append(scalar) } else { pendingSpace = visible }
            case .surrogate, .privateUse:
                pendingSpace = visible
            case .nonspacingMark, .enclosingMark, .spacingMark:
                guard visible else { continue }
                fallthrough
            default:
                if pendingSpace { output.append(" "); pendingSpace = false }
                output.append(scalar)
                visible = true
            }
        }
        guard visible else { return "" }
        var cleaned = String(String(output).prefix(maximumCharacters))
        if cleaned.unicodeScalars.count > maximumScalars {
            cleaned = String(String.UnicodeScalarView(cleaned.unicodeScalars.prefix(maximumScalars)))
        }
        // Trimming a joiner or mark left behind by truncation keeps the tail visible.
        while let last = cleaned.unicodeScalars.last,
              last == "\u{200C}" || last == "\u{200D}" || last.properties.generalCategory == .spaceSeparator {
            cleaned.unicodeScalars.removeLast()
        }
        return cleaned
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
        let old = recent[index]
        if let ownNickname { recent[index].ownNickname = PeerProfile.clean(ownNickname) }
        if let localNickname { recent[index].localNickname = PeerProfile.clean(localNickname) }
        guard old.ownNickname != recent[index].ownNickname || old.localNickname != recent[index].localNickname else { return }
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
        // Only a well-formed X25519 public key can be the paired peer; anything
        // else in preferences is treated as unpaired rather than sent to the relay.
        peerPublicKey = defaults.data(forKey: peerKey).flatMap {
            $0.count == 32 && (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: $0)) != nil ? $0 : nil
        }
        ptt = PTTConsent(
            active: defaults.string(forKey: "CapsLink.pttAgreement").flatMap(UInt64.init),
            outgoing: defaults.string(forKey: "CapsLink.pttOutgoing").flatMap(UInt64.init),
            revoked: defaults.string(forKey: "CapsLink.pttRevocation").flatMap(UInt64.init)
        )
        if peerPublicKey == nil { ptt = PTTConsent() }
        if let data = defaults.data(forKey: "slock.recentPeers"),
           let saved = try? JSONDecoder().decode([RecentPeer].self, from: data) {
            var seen = Set<Data>()
            recent = saved.filter {
                $0.publicKey.count == 32 && (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: $0.publicKey)) != nil
                    && seen.insert($0.publicKey).inserted
            }.map {
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
    case captureState = 13
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

// MARK: - Key rhythm playback

struct KeyLightEvent {
    let down: Bool
    // CGEvent's monotonic timestamp, in nanoseconds. Only differences are used;
    // the Macs' clocks never need to agree.
    let timestamp: UInt64

    var payload: Data {
        var data = Data([down ? UInt8(1) : UInt8(0)])
        data.appendUInt64(timestamp)
        return data
    }

    static func read(_ payload: Data) -> KeyLightEvent? {
        guard payload.count == 9, let state = payload.first, state <= 1,
              let timestamp = payload.uint64(at: 1) else { return nil }
        return KeyLightEvent(down: state == 1, timestamp: timestamp)
    }
}

struct KeyLightTimeline {
    private struct Pending {
        let event: KeyLightEvent
        var deadline: TimeInterval
    }

    private var pending: [Pending] = []
    private var previousDeadline: TimeInterval?
    private(set) var latest: KeyLightEvent?
    var nextDeadline: TimeInterval? { pending.first?.deadline }
    var pendingCount: Int { pending.count }

    mutating func reset() { self = KeyLightTimeline() }

    // Preserve every subsecond interval, including OFF gaps. Refill the buffer
    // during longer intervals, where the duration is deliberately flexible.
    // False means corrupt/discontinuous input or an excessive replay backlog.
    mutating func append(_ event: KeyLightEvent, receivedAt now: TimeInterval) -> Bool {
        var deadline = now + SlockConfig.lightPlaybackDelay
        if let latest, let previousDeadline {
            guard event.timestamp > latest.timestamp, event.down != latest.down else { return false }
            let interval = Double(event.timestamp - latest.timestamp) / 1_000_000_000
            if interval < 1 {
                deadline = previousDeadline + interval
            } else {
                deadline = max(previousDeadline + 1, deadline)
            }
        }
        guard pending.count < 256, deadline - now <= SlockConfig.remoteKeyTimeout else { return false }
        pending.append(Pending(event: event, deadline: deadline))
        latest = event
        previousDeadline = deadline
        return true
    }

    mutating func takeDue(at now: TimeInterval) -> KeyLightEvent? {
        guard let first = pending.first, first.deadline <= now else { return nil }
        pending.removeFirst()
        // A late timer/packet must never cause a burst of catch-up flashes.
        // Shift remaining playback so already queued short intervals survive.
        let lateness = now - first.deadline
        if lateness > 0 {
            for index in pending.indices { pending[index].deadline += lateness }
            if let previousDeadline { self.previousDeadline = previousDeadline + lateness }
        }
        return first.event
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

// The public relay can send arbitrary traffic. Bound expensive decryption and
// reserve most of the budget for selected identities. This is a client resource
// bound, not a substitute for authentication and rate limits at the broker.
struct InboundBudget {
    private var tokens: Double = 120
    private var strangerTokens: Double = 8
    private var last: TimeInterval?

    mutating func allow(selected: Bool, at now: TimeInterval) -> Bool {
        let elapsed = max(0, now - (last ?? now))
        last = now
        tokens = min(120, tokens + elapsed * 120)
        strangerTokens = min(8, strangerTokens + elapsed * 4)
        if !selected {
            guard strangerTokens >= 1 else { return false }
            strangerTokens -= 1
        }
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
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

    static func freshClientID() -> String {
        "cl-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20)
    }

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
            guard `protocol` == "mqtt" else {
                self.scheduleReconnect("The relay did not negotiate MQTT")
                return
            }
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
    var handler: ((Bool, UInt64?) -> Void)?
    private var generation = UUID()

    func enqueue(_ down: Bool, timestamp: UInt64) {
        let generation = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.handler?(down, timestamp)
        }
    }

    func release() {
        generation = UUID()
        handler?(false, nil)
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
                globalCapsDelivery.enqueue(true, timestamp: event.timestamp)
            }
            return nil
        }
        if type == .keyUp {
            if globalCapsIsDown {
                globalCapsIsDown = false
                globalCapsDelivery.enqueue(false, timestamp: event.timestamp)
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
        try validate(mask: currentProcessMask())
    }

    static func currentProcessMask() throws -> CGEventMask {
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
        return tap.eventsOfInterest
    }
}

final class CapsInterceptor {
    typealias HIDMap = (src: UInt64, dst: UInt64)

    var onKeyState: ((Bool, UInt64?) -> Void)?
    var onStatusChange: (() -> Void)?

    private(set) var isActive = false
    private(set) var permissionGranted = false
    var inputMonitoringPermissionGranted: Bool { listenCheck() }
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
    private var listenCheck: () -> Bool = {
        CGPreflightListenEventAccess() && HIDEventAccess.current() == .granted
    }
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
        restoreStaleMappingIfNeeded()
    }

    #if CAPSLINK_TESTING
    convenience init(testDefaults: Preferences,
                     process: @escaping (String, [String]) throws -> (Int32, String, String),
                     readLock: @escaping () -> Bool = { false },
                     writeLock: @escaping (Bool) -> Bool = { _ in true },
                     trustCheck: @escaping () -> Bool = { true },
                     listenCheck: @escaping () -> Bool = { true },
                     verifyTap: @escaping () throws -> Void = {}) {
        self.init(defaults: testDefaults, process: process)
        self.trustCheck = trustCheck
        self.listenCheck = listenCheck
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
        // The setup window owns prompting, after the app has visible UI. Capture
        // only observes grants and must not remap the key until both are ready.
        if !permissionGranted || !listenCheck() {
            lastError = permissionGranted ? "Input Monitoring permission is required. Choose Permissions Required to finish setup." : nil
            permissionTimer?.invalidate()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
                guard let self else { return }
                self.permissionGranted = self.trustCheck()
                self.lastError = self.permissionGranted ? "Input Monitoring permission is required. Choose Permissions Required to finish setup." : nil
                if self.permissionGranted && self.listenCheck() {
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
        guard permissionGranted && listenCheck() else {
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
            onKeyState?(false, nil)
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
        globalCapsDelivery.handler = { [weak self] down, timestamp in self?.onKeyState?(down, timestamp) }
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

enum HIDEventAccess: String {
    case granted, denied, unknown

    static func current() -> HIDEventAccess {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .unknown
        }
    }
}

enum KeyboardPermission: CaseIterable {
    case accessibility, inputMonitoring, microphone

    var requestKey: String {
        switch self {
        case .accessibility: return "CapsLink.didRequestAccessibility"
        case .inputMonitoring: return "CapsLink.didRequestInputMonitoring"
        case .microphone: return "CapsLink.didRequestMicrophone"
        }
    }

    var settingsURL: URL {
        let pane: String
        switch self {
        case .accessibility: pane = "Privacy_Accessibility"
        case .inputMonitoring: pane = "Privacy_ListenEvent"
        case .microphone: pane = "Privacy_Microphone"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

struct KeyboardPermissionState: Equatable {
    var accessibility: Bool
    var inputMonitoring: Bool
    var microphone = false
    var microphoneRequired = false
    var isReady: Bool { accessibility && inputMonitoring && (!microphoneRequired || microphone) }
    var firstMissing: KeyboardPermission? {
        if !accessibility { return .accessibility }
        if !inputMonitoring { return .inputMonitoring }
        return microphoneRequired && !microphone ? .microphone : nil
    }

    func isGranted(_ permission: KeyboardPermission) -> Bool {
        switch permission {
        case .accessibility: return accessibility
        case .inputMonitoring: return inputMonitoring
        case .microphone: return microphone
        }
    }
}

final class KeyboardPermissionSetup {
    typealias Request = (KeyboardPermission, @escaping () -> Void) -> Void
    private static let inputRequestQueue = DispatchQueue(label: "slock.input-permission")
    private let defaults: Preferences
    private let check: () -> KeyboardPermissionState
    private let prompt: Request
    private var completions: [() -> Void] = []
    private(set) var requestingPermission: KeyboardPermission?
    var microphoneRequired = false

    init(defaults: Preferences = UserDefaults.standard,
         check: @escaping () -> KeyboardPermissionState = {
             KeyboardPermissionState(accessibility: AXIsProcessTrusted(),
                                     inputMonitoring: CGPreflightListenEventAccess() && HIDEventAccess.current() == .granted,
                                     microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
         },
         request: @escaping Request = { permission, completion in
             switch permission {
             case .accessibility:
                 let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                 _ = AXIsProcessTrustedWithOptions(options)
                 DispatchQueue.main.async(execute: completion)
             case .inputMonitoring:
                 // IOHIDRequestAccess waits for TCC. Keep the guide responsive
                 // and let the native request finish before opening Settings.
                 KeyboardPermissionSetup.inputRequestQueue.async {
                     _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
                     DispatchQueue.main.async(execute: completion)
                 }
             case .microphone:
                 guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else {
                     completion()
                     return
                 }
                 AVCaptureDevice.requestAccess(for: .audio) { _ in
                     DispatchQueue.main.async(execute: completion)
                 }
             }
         }) {
        self.defaults = defaults
        self.check = check
        self.prompt = request
    }

    convenience init(defaults: Preferences, check: @escaping () -> KeyboardPermissionState,
                     prompt: @escaping (KeyboardPermission) -> Void) {
        self.init(defaults: defaults, check: check, request: { permission, completion in
            prompt(permission)
            completion()
        })
    }

    var state: KeyboardPermissionState {
        var state = check()
        state.microphoneRequired = microphoneRequired
        return state
    }

    func hasRequested(_ permission: KeyboardPermission) -> Bool {
        defaults.object(forKey: permission.requestKey) as? Bool == true
    }

    func shouldShowOnLaunch(captureRequested: Bool) -> Bool {
        // A saved request is not a grant: reinstalls and ad-hoc signed updates
        // can leave permission records behind without trusting this executable.
        captureRequested && !state.isReady
    }

    func requestNextAutomatically() {
        guard requestingPermission == nil, let permission = state.firstMissing,
              !hasRequested(permission) else { return }
        _ = request(permission)
    }

    @discardableResult
    func request(_ permission: KeyboardPermission, completion: @escaping () -> Void = {}) -> Bool {
        let wasRequested = hasRequested(permission)
        if let requestingPermission {
            if requestingPermission == permission { completions.append(completion) }
            return wasRequested
        }
        requestingPermission = permission
        completions = [completion]
        defaults.set(true, forKey: permission.requestKey)
        defaults.synchronize()
        // A completed request is not evidence of approval. Observe the actual
        // grants before updating the menu or starting keyboard/voice capture.
        prompt(permission) { [weak self] in
            guard let self else { return }
            self.requestingPermission = nil
            let callbacks = self.completions
            self.completions.removeAll()
            for callback in callbacks { callback() }
        }
        return wasRequested
    }
}

enum PermissionMenu {
    static let title = "Permissions Required"

    static func update(_ item: NSMenuItem, state: KeyboardPermissionState) {
        item.title = title
        item.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.systemRed])
        item.isHidden = state.isReady
    }
}

protocol CapsLEDOutput: AnyObject {
    var lastError: String? { get }
    var diagnostics: String { get }
    func set(_ on: Bool) -> Bool
}

final class CapsLED {
    enum Mode: String {
        case unknown = "Not tested"
        case directHID = "Direct HID LED"
        case permissionRequired = "Keyboard light permission required"
        case unavailable = "Unavailable"
    }

    private let accessCheck: () -> HIDEventAccess
    private let makeOutput: () -> CapsLEDOutput
    private var output: CapsLEDOutput?
    private var directWriter: ((Bool) -> Bool)?
    private(set) var mode: Mode = .unknown
    private(set) var isOn = false
    private(set) var lastError: String?
    private(set) var deviceDiagnostics = "Not opened"

    init(accessCheck: @escaping () -> HIDEventAccess = HIDEventAccess.current,
         makeOutput: @escaping () -> CapsLEDOutput = { HIDCapsLEDOutput() }) {
        self.accessCheck = accessCheck
        self.makeOutput = makeOutput
        // HID device objects cache a denied access result. Do not create them
        // at launch, before the user has granted keyboard access.
    }

    #if CAPSLINK_TESTING
    convenience init(directWriter: @escaping (Bool) -> Bool) {
        self.init(accessCheck: { .granted })
        self.directWriter = directWriter
    }
    #endif

    @discardableResult
    func set(_ on: Bool) -> Bool {
        guard accessCheck() == .granted else {
            output = nil
            mode = .permissionRequired
            isOn = false
            lastError = "Allow slock in Input Monitoring, then retry the keyboard light."
            deviceDiagnostics = "Not opened: HID listening access is not granted"
            return false
        }
        let direct: Bool
        if let directWriter {
            direct = directWriter(on)
        } else {
            let output = output ?? makeOutput()
            self.output = output
            direct = output.set(on)
            deviceDiagnostics = output.diagnostics
            lastError = output.lastError
            // A permission change can race the preflight. Release failed HID
            // objects so a subsequent attempt gets a fresh authorization check.
            if !direct { self.output = nil }
        }
        if direct {
            mode = .directHID
            isOn = on
            lastError = nil
            return true
        }
        mode = .unavailable
        isOn = false
        if lastError == nil { lastError = "This keyboard does not expose a writable Caps Lock light." }
        return false
    }

    var diagnostics: String {
        "HID listening access: \(accessCheck().rawValue)\nLED devices: \(deviceDiagnostics)\nLED error: \(lastError ?? "none")"
    }
}

private final class HIDCapsLEDOutput: CapsLEDOutput {
    private let manager: IOHIDManager
    private let openResult: IOReturn
    private(set) var lastError: String?
    private(set) var diagnostics = "Not written"

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard
        ] as CFDictionary)
        openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    deinit { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

    func set(_ on: Bool) -> Bool {
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        var elementCount = 0
        var writeCount = 0
        var writeError: IOReturn?
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
                elementCount += 1
                let value = IOHIDValueCreateWithIntegerValue(
                        kCFAllocatorDefault,
                        element,
                        mach_absolute_time(),
                        on ? 1 : 0
                      )
                let result = IOHIDDeviceSetValue(device, element, value)
                if result == kIOReturnSuccess { writeCount += 1 }
                else { writeError = result }
            }
        }
        diagnostics = "\(devices.count) keyboards, \(elementCount) Caps LED elements, \(writeCount) successful writes; open=\(Self.code(openResult))"
        if writeCount > 0 {
            lastError = nil
        } else if let writeError {
            lastError = "Caps Lock light write failed (\(Self.code(writeError))). Check Input Monitoring access."
        } else if openResult != kIOReturnSuccess {
            lastError = "Keyboard devices could not be opened (\(Self.code(openResult))). Check Input Monitoring access."
        } else {
            lastError = "No writable Caps Lock light was found on the connected keyboards."
        }
        return writeCount > 0
    }

    private static func code(_ result: IOReturn) -> String { String(format: "0x%08x", UInt32(bitPattern: result)) }
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

// Only aggregate levels are retained, never microphone samples or recordings.
struct AudioSignalLevel {
    private(set) var sampleCount = 0
    private(set) var peak: Float = 0

    mutating func observe(_ samples: UnsafeBufferPointer<Int16>) {
        sampleCount += samples.count
        for sample in samples { peak = max(peak, abs(Float(sample)) / 32_768) }
    }

    mutating func observe(_ samples: UnsafeBufferPointer<Float>) {
        sampleCount += samples.count
        for sample in samples where sample.isFinite { peak = max(peak, abs(sample)) }
    }

    var summary: String {
        guard sampleCount > 0 else { return "no PCM samples" }
        guard peak > 0 else { return "\(sampleCount) samples, digital silence" }
        return "\(sampleCount) samples, peak \(String(format: "%.1f", 20 * log10(peak))) dBFS"
    }
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
    var diagnostics: String { get }
    func start(onBatch: @escaping (Data) -> Void) throws
    func stop()
}

protocol VoicePlayback: AnyObject {
    var onError: ((String) -> Void)? { get set }
    var diagnostics: String { get }
    func beginTalk()
    func receiveBatch(_ batch: Data)
    func endTalk(completion: @escaping () -> Void)
    func stopImmediately()
}

extension VoiceCapture {
    var diagnostics: String { "Capture diagnostics unavailable" }
}

extension VoicePlayback {
    var diagnostics: String { "Playback diagnostics unavailable" }
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
    private var signalLevel = AudioSignalLevel()
    private var generatedBatches = 0
    private var inputFormatDescription = "not started"

    var diagnostics: String {
        queue.sync {
            "Capture (latest talk): input \(inputFormatDescription); \(signalLevel.summary); "
                + "batches generated \(generatedBatches); engine running \(engine.isRunning)"
        }
    }

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
            signalLevel = AudioSignalLevel()
            generatedBatches = 0
            inputFormatDescription = "\(hardwareFormat.channelCount) ch @ \(hardwareFormat.sampleRate) Hz"
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

        signalLevel.observe(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
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
        generatedBatches += 1
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
    private var signalLevel = AudioSignalLevel()
    private var decodedPackets = 0
    private var playedBuffers = 0

    var diagnostics: String {
        queue.sync {
            "Playback (latest talk): \(signalLevel.summary); packets decoded \(decodedPackets); "
                + "buffers played \(playedBuffers); queued \(queuedBuffers); "
                + "engine running \(engine.isRunning); player playing \(player.isPlaying)"
        }
    }

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
            self.signalLevel = AudioSignalLevel()
            self.decodedPackets = 0
            self.playedBuffers = 0
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
                    self.decodedPackets += 1
                    if let samples = pcm.floatChannelData?[0] {
                        self.signalLevel.observe(UnsafeBufferPointer(start: samples, count: Int(pcm.frameLength)))
                    }
                    let generation = self.generation
                    self.player.scheduleBuffer(pcm, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                        guard let self else { return }
                        self.queue.async {
                            guard self.generation == generation else { return }
                            self.queuedBuffers -= 1
                            self.playedBuffers += 1
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
    private var inboundBudget = InboundBudget()
    private let transport: RelayTransport
    private let makeCapture: () throws -> VoiceCapture
    private let makePlayback: () throws -> VoicePlayback
    private let checkAudio: () throws -> Void
    private let requestMicrophone: (@escaping (Bool) -> Void) -> Void
    private let logsStatus: Bool
    private let now: () -> TimeInterval
    private var timer: Timer?
    private var lightTimer: DispatchSourceTimer?
    private var lightTimeline = KeyLightTimeline()
    private var lightGeneration = UUID()
    private var audioCapture: VoiceCapture?
    private var audioPlayback: VoicePlayback?

    private(set) var transportState: MQTTClient.State = .stopped
    private(set) var localKeyDown = false
    private(set) var remoteKeyDown = false
    private(set) var peerOnline = false
    private(set) var peerPaused = false
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
    private var microphonePermissionPending = false
    private var microphonePermissionInvitation: UInt64?
    private static let microphonePermissionError = "Microphone permission is required for PTT."
    var requiresMicrophonePermission: Bool { pttEnabled || outgoingPTTInvite || microphonePermissionPending }
    private var consentGeneration = UUID()
    private var captureWasActive = false
    private var lastLoggedCaptureStatus: String?
    private var lastLoggedLinkStatus: String?
    private var lastLoggedVoiceStatus: String?
    private var localPressCount = 0
    private var sentKeyMessages = 0
    private var receivedKeyMessages = 0
    private var receivedPeerHellos = 0
    private var lastPeerKeyState: Bool?
    private var sentAudioBatches = 0
    private var receivedAudioBatches = 0
    private var acceptedAudioBatches = 0
    private var receivedTalkStarts = 0
    private var lastAudioError: String?
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
            clientID: MQTTClient.freshClientID(),
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
         requestMicrophone: @escaping (@escaping (Bool) -> Void) -> Void = SlockController.ensureMicrophonePermission,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.identity = identity
        self.peerStore = peerStore
        self.capsInterceptor = capsInterceptor
        self.led = led
        self.transport = transport
        self.makeCapture = makeCapture
        self.makePlayback = makePlayback
        self.checkAudio = checkAudio
        self.requestMicrophone = requestMicrophone
        self.now = now
        logsStatus = startServices
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
                self.peerPaused = false
                self.lastPeerSeen = nil
                self.clearRemoteKey()
                self.stopLocalTalk()
                self.stopRemoteTalk(immediate: true)
            }
            self.changed()
        }
        transport.onMessage = { [weak self] _, packet in
            self?.receive(packet)
        }
        capsInterceptor.onKeyState = { [weak self] down, timestamp in
            self?.handleLocalKey(down, timestamp: timestamp)
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
                else { self.clearRemoteKey() }
                self.sendCaptureState()
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

    var peerUnavailable: Bool {
        guard let peer = peerPublicKey else { return false }
        return transportState != .connected || !peerOnline || peerPaused || !wire.hasSession(with: peer)
    }

    var attention: PendingAttention {
        if incomingPairPublicKey != nil { return .pairing }
        if incomingPTTInvite { return .ptt }
        return .none
    }

    var statusText: String {
        if lastError != nil { return "Error" }
        if !capsInterceptor.isRequested, !capsInterceptor.isActive { return "Paused" }
        if !capsInterceptor.permissionGranted { return "Permission Required • Accessibility" }
        if !capsInterceptor.isActive {
            if !capsInterceptor.inputMonitoringPermissionGranted { return "Permission Required • Input Monitoring" }
            return "Error"
        }
        if incomingPairPublicKey != nil { return "Pairing • Request Received" }
        if incomingPTTInvite { return "Paired • PTT Invitation Received" }
        if outgoingPairPublicKey != nil { return "Pairing • Request Sent" }
        guard let peerPublicKey = peerStore.peerPublicKey else { return "Unpaired" }
        switch transportState {
        case .stopped: return "Paired • Offline"
        case .connecting: return "Paired • Connecting"
        case .error: return "Error"
        case .connected: break
        }
        if peerPaused { return "Paired • Paused" }
        if localTalking { return "Paired • Transmitting" }
        if remoteTalking { return "Paired • Receiving" }
        if !peerOnline { return "Paired • Offline" }
        if led.mode == .permissionRequired { return "Paired • Light Permission Required" }
        if led.mode == .unavailable { return "Paired • Light Unavailable" }
        return "Paired • \(peerName(peerPublicKey))"
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
        for key in [outgoingPairPublicKey].compactMap({ $0 }) {
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
        if peerStore.peerPublicKey != nil { disablePTT() }
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
            disablePTT()
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
        microphonePermissionPending = true
        microphonePermissionInvitation = nil
        consentGeneration = UUID()
        let generation = consentGeneration
        requestMicrophone { [weak self] granted in
            guard let self else { return }
            guard self.peerStore.peerPublicKey == peer, self.consentGeneration == generation else { return }
            if granted {
                self.microphonePermissionPending = false
                self.peerStore.ptt.invite()
                self.lastPTTInviteSent = -.infinity
                self.retryOutgoingPTTInvite(force: true)
                self.lastError = nil
            } else {
                self.lastError = Self.microphonePermissionError
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
        microphonePermissionPending = true
        microphonePermissionInvitation = invitation
        consentGeneration = UUID()
        let generation = consentGeneration
        requestMicrophone { [weak self] granted in
            guard let self else { return }
            guard self.peerStore.peerPublicKey == peer, self.consentGeneration == generation else { return }
            guard self.peerStore.ptt.incoming == invitation else {
                self.cancelMicrophonePermissionRequest()
                self.changed()
                return
            }
            self.microphonePermissionInvitation = nil
            if granted {
                self.microphonePermissionPending = false
                self.peerStore.ptt.accept(invitation)
                self.sendPTT(.pttAccept, id: invitation, to: peer)
                self.lastError = nil
            } else {
                self.peerStore.ptt.reject(invitation)
                self.sendPTT(.pttReject, id: invitation, to: peer)
                self.lastError = Self.microphonePermissionError
            }
            self.changed()
            completion(granted)
        }
    }

    func rejectPTTInvite(expected: UInt64) {
        guard let peer = peerStore.peerPublicKey, let invitation = peerStore.ptt.incoming,
              invitation == expected else { return }
        cancelMicrophonePermissionRequest()
        peerStore.ptt.reject(invitation)
        sendPTT(.pttReject, id: invitation, to: peer)
        changed()
    }

    func disablePTT() {
        cancelMicrophonePermissionRequest()
        peerStore.ptt.disable()
        if let peer = peerStore.peerPublicKey, let revoked = peerStore.ptt.revoked {
            sendPTT(.pttDisable, id: revoked, to: peer)
        }
        lastPTTInviteSent = -.infinity
        stopLocalTalk()
        stopRemoteTalk(immediate: true)
        changed()
    }

    func permissionState(grants: KeyboardPermissionState) -> KeyboardPermissionState {
        // Reconcile grants on ordinary status refresh, even after the guide was
        // closed. Only a transition emits a change, so that refresh is finite.
        if grants.microphone && microphonePermissionPending {
            microphonePermissionPending = false
            if lastError == Self.microphonePermissionError { lastError = nil }
            changed()
        }
        var state = grants
        state.microphoneRequired = requiresMicrophonePermission
        return state
    }

    private func cancelMicrophonePermissionRequest() {
        consentGeneration = UUID()
        microphonePermissionPending = false
        microphonePermissionInvitation = nil
        if lastError == Self.microphonePermissionError { lastError = nil }
    }

    private func cancelStaleMicrophonePermissionInvitation() {
        guard let invitation = microphonePermissionInvitation,
              peerStore.ptt.incoming != invitation else { return }
        cancelMicrophonePermissionRequest()
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
            recordAudioError("PTT is unavailable: \(error.localizedDescription)")
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
            stopRemoteTalk(immediate: true)
            clearRemoteKey()
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
            lastError = led.lastError
        }
        changed()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.capsInterceptor.isActive else { return }
            self.led.set(self.remoteKeyDown)
            self.changed()
        }
    }

    func retryLED() {
        guard capsInterceptor.isActive else { return }
        _ = led.set(remoteKeyDown)
        changed()
    }

    func clearError() {
        lastError = nil
        lastAudioError = nil
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
        clearRemoteKey()
        capsInterceptor.stop()
        transport.stop()
    }

    func diagnostics() -> String {
        let microphonePermission: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphonePermission = "authorized"
        case .denied: microphonePermission = "denied"
        case .restricted: microphonePermission = "restricted"
        case .notDetermined: microphonePermission = "not requested"
        @unknown default: microphonePermission = "unknown"
        }
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
            "Peer paused: \(peerPaused)",
            "PTT enabled: \(pttEnabled)",
            "Microphone permission: \(microphonePermission)",
            "Voice state: local key \(localKeyDown ? "down" : "up"), transmitting \(localTalking), receiving \(remoteTalking), draining \(remoteTalkEnding)",
            "Voice totals (this launch): talk starts received \(receivedTalkStarts), audio batches queued \(sentAudioBatches), received \(receivedAudioBatches), accepted \(acceptedAudioBatches)",
            audioCapture?.diagnostics ?? "Capture: not created",
            audioPlayback?.diagnostics ?? "Playback: not created",
            "Last audio error: \(lastAudioError ?? "none")",
            "Accessibility trusted: \(capsInterceptor.permissionGranted)",
            "Input Monitoring allowed: \(CGPreflightListenEventAccess())",
            "Caps capture requested: \(capsInterceptor.isRequested)",
            "Caps capture active: \(capsInterceptor.isActive)",
            "Keyboard event mask: \((try? KeyboardTapAccess.currentProcessMask()).map(String.init) ?? "not installed") (required \(KeyboardTapAccess.requiredMask))",
            "Peer session confirmed: \(peerStore.peerPublicKey.map { wire.hasSession(with: $0) } ?? false)",
            "Local Caps presses: \(localPressCount)",
            "Key messages queued: \(sentKeyMessages)",
            "Key messages received: \(receivedKeyMessages)",
            "Peer HELLOs received: \(receivedPeerHellos)",
            "Last peer key state: \(lastPeerKeyState.map { $0 ? "down" : "up" } ?? "none")",
            "Light playback: \(lightTimeline.latest == nil ? "Immediate state sync" : "Timestamped rhythm (1 s buffer)")",
            "Pending light transitions: \(lightTimeline.pendingCount)",
            "System Caps Lock on: \(CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift))",
            "Caps error: \(capsInterceptor.lastError ?? "none")",
            "LED mode: \(led.mode.rawValue)",
            led.diagnostics,
            "App error: \(lastError ?? "none")",
            "OS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Architecture: \(architecture)",
            "Broker: \(SlockConfig.brokerURL.absoluteString)"
        ].joined(separator: "\n")
    }

    private func receive(_ packet: Data) {
        guard transportState == .connected, packet.count >= 86, packet.count <= 64_000,
              packet.first == SlockConfig.protocolVersion else { return }
        let protected = Set([peerStore.peerPublicKey, outgoingPairPublicKey, incomingPairPublicKey].compactMap { $0 })
        let senderKey = Data(packet.dropFirst().prefix(32))
        // Once a peer has been selected, strangers cannot replace its request,
        // query our profile, or consume public-key operations on the main queue.
        guard protected.isEmpty || protected.contains(senderKey),
              inboundBudget.allow(selected: protected.contains(senderKey), at: now()) else { return }
        guard let message = wire.open(packet, protecting: protected) else { return }
        let sender = message.senderPublicKey

        if message.kind == .hello {
            if message.needsHelloReply {
                let now = now()
                if now - (lastHandshakeReply[sender] ?? -10) >= 1 {
                    if lastHandshakeReply.count >= 32 { lastHandshakeReply.removeAll() }
                    lastHandshakeReply[sender] = now
                    send(kind: .hello, payload: helloPayload(for: sender), to: sender)
                }
            }
            guard message.sessionConfirmed else { return }
            if message.newSession, peerStore.peerPublicKey == sender {
                peerPaused = false
                consentGeneration = UUID()
                peerStore.ptt.incoming = nil
                // An outgoing invitation is retried only after this fresh handshake.
                stopLocalTalk()
                stopRemoteTalk(immediate: true)
                clearRemoteKey()
            }
            if message.newSession {
                retryOutgoingPairRequest(force: true)
                retryOutgoingPTTInvite(force: true)
            }
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
            disablePTT()
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
            receivedPeerHellos += 1
            if message.payload.count == 9, let revoked = message.payload.uint64(at: 1) {
                applyPTTRevocation(revoked)
                receiveRemoteKeySnapshot(message.payload[0] != 0)
            }
            // Refresh after every confirmed HELLO so lost pause/resume updates
            // recover without changing the legacy HELLO payload.
            sendCaptureState()
        case .captureState:
            guard message.payload.count == 1, let active = message.payload.first, active <= 1 else { return }
            markPeerSeen()
            peerPaused = active == 0
            if peerPaused { clearRemoteKey() }
        case .keyState:
            if let event = KeyLightEvent.read(message.payload) {
                markPeerSeen()
                receivedKeyMessages += 1
                lastPeerKeyState = event.down
                receiveRemoteKeyEvent(event)
            } else if message.payload.count == 1, let value = message.payload.first, value <= 1 {
                markPeerSeen()
                receivedKeyMessages += 1
                lastPeerKeyState = value == 1
                receiveRemoteKeySnapshot(value == 1)
            }
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
            cancelStaleMicrophonePermissionInvitation()
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
        // A publicly visible key is not consent to disclose this Mac's name.
        // Return our profile only after local acceptance or a local request.
        if outgoingPairPublicKey == sender {
            send(kind: .profile, payload: PeerProfile.payload(peerStore.ownNickname), to: sender)
        }
        changed()
    }

    private func handleLocalKey(_ down: Bool, timestamp: UInt64? = nil) {
        guard !down || capsInterceptor.isActive else { return }
        guard localKeyDown != down else { return }
        localKeyDown = down
        if down { localPressCount += 1 }
        // A local press is an output for the peer, never for this keyboard.
        // Reassert the remote state in case the keyboard firmware briefly
        // changed its own Caps Lock LED before the remapped event arrived.
        if capsInterceptor.isActive { led.set(remoteKeyDown) }
        if let peer = peerStore.peerPublicKey {
            let payload = timestamp.map { KeyLightEvent(down: down, timestamp: $0).payload }
                ?? Data([down ? UInt8(1) : UInt8(0)])
            send(kind: .keyState, payload: payload, to: peer)
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

    private func applyRemoteKey(_ down: Bool) {
        guard capsInterceptor.isActive else { return }
        remoteKeyDown = down
        led.set(down)
    }

    private func cancelLightPlayback() {
        lightGeneration = UUID()
        lightTimer?.cancel()
        lightTimer = nil
        lightTimeline.reset()
    }

    private func clearRemoteKey() {
        cancelLightPlayback()
        remoteKeyDown = false
        lastRemoteKeySeen = nil
        if capsInterceptor.isActive { led.set(false) }
    }

    private func receiveRemoteKeySnapshot(_ down: Bool) {
        guard capsInterceptor.isActive else { return }
        lastRemoteKeySeen = now()
        // HELLOs and one-byte held-key refreshes carry no transition timing.
        // A matching snapshot renews the lease without skipping buffered edges.
        if let latest = lightTimeline.latest, latest.down == down { return }
        cancelLightPlayback()
        applyRemoteKey(down)
    }

    private func receiveRemoteKeyEvent(_ event: KeyLightEvent) {
        guard capsInterceptor.isActive else { return }
        let receivedAt = now()
        lastRemoteKeySeen = receivedAt
        guard lightTimeline.append(event, receivedAt: receivedAt) else {
            clearRemoteKey()
            return
        }
        scheduleLightPlayback()
    }

    private func scheduleLightPlayback() {
        lightTimer?.cancel()
        lightTimer = nil
        lightGeneration = UUID()
        guard let deadline = lightTimeline.nextDeadline else { return }
        let generation = lightGeneration
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(deadline: .now() + max(0, deadline - now()), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, self.lightGeneration == generation else { return }
            self.playDueLightEvent()
        }
        lightTimer = timer
        timer.resume()
    }

    private func playDueLightEvent() {
        let time = now()
        guard capsInterceptor.isActive, let lastRemoteKeySeen,
              time - lastRemoteKeySeen <= SlockConfig.remoteKeyTimeout else {
            clearRemoteKey()
            changed()
            return
        }
        if let event = lightTimeline.takeDue(at: time) {
            applyRemoteKey(event.down)
            changed()
        }
        scheduleLightPlayback()
    }

    #if CAPSLINK_TESTING
    func advanceLightPlayback() { playDueLightEvent() }
    func advanceMaintenance() { tick() }
    #endif

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
                self.recordAudioError("Audio capture: \(message)")
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
            recordAudioError("Could not start PTT: \(error.localizedDescription)")
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
        receivedTalkStarts += 1
        guard peerStore.pttEnabled, capsInterceptor.isActive, transportState == .connected,
              payload.count == 8, let talkID = payload.uint64(at: 0), talkID != 0,
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
                self.recordAudioError("Audio playback: \(message)")
                self.stopRemoteTalk(immediate: true)
                self.changed()
            }
            audioPlayback = playback
            remoteTalkID = talkID
            remoteTalking = true
            remoteTalkEnding = false
            lastRemoteTalkSeen = now()
            playback.beginTalk()
        } catch {
            recordAudioError("Could not start PTT playback: \(error.localizedDescription)")
        }
    }

    private func handleRemoteAudio(_ payload: Data) {
        receivedAudioBatches += 1
        guard peerStore.pttEnabled, capsInterceptor.isActive, transportState == .connected,
              remoteTalking, !remoteTalkEnding,
              let talkID = payload.uint64(at: 0),
              talkID == remoteTalkID,
              payload.count > 8 else { return }
        acceptedAudioBatches += 1
        markPeerSeen()
        lastRemoteTalkSeen = now()
        audioPlayback?.receiveBatch(Data(payload.dropFirst(8)))
    }

    private func handleRemoteTalkStop(_ payload: Data) {
        guard payload.count == 8, let talkID = payload.uint64(at: 0), talkID == remoteTalkID else { return }
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
        let now = now()
        guard force || (now - lastPairRequestSent) >= 10 else { return }
        lastPairRequestSent = now
        send(kind: .pairRequest, payload: PeerProfile.payload(peerStore.ownNickname), to: target)
    }

    private func retryOutgoingPTTInvite(force: Bool = false) {
        guard transportState == .connected,
              outgoingPTTInvite,
              let peer = peerStore.peerPublicKey else { return }
        let now = now()
        guard force || (now - lastPTTInviteSent) >= 10 else { return }
        lastPTTInviteSent = now
        if let invitation = peerStore.ptt.outgoing { sendPTT(.pttInvite, id: invitation, to: peer) }
    }

    private func sendHello(force: Bool = false) {
        guard transportState == .connected, let peer = peerStore.peerPublicKey else { return }
        let now = now()
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

    private func sendCaptureState() {
        guard let peer = peerStore.peerPublicKey else { return }
        send(kind: .captureState, payload: Data([capsInterceptor.isActive ? UInt8(1) : UInt8(0)]), to: peer)
    }

    private func applyPTTRevocation(_ id: UInt64) {
        let before = peerStore.ptt.active
        peerStore.ptt.receiveRevocation(id)
        cancelStaleMicrophonePermissionInvitation()
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
            if kind == .keyState { sentKeyMessages += 1 }
            if kind == .audio { sentAudioBatches += 1 }
        } catch {
            lastError = error.localizedDescription
            changed()
        }
    }

    private func tick() {
        let now = now()
        sendHello()
        retryOutgoingPairRequest()
        retryOutgoingPTTInvite()

        if localKeyDown, let peer = peerStore.peerPublicKey {
            send(kind: .keyState, payload: Data([UInt8(1)]), to: peer)
        }

        if let last = lastRemoteKeySeen,
           (now - last) > SlockConfig.remoteKeyTimeout {
            clearRemoteKey()
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
            peerPaused = false
            clearRemoteKey()
            stopRemoteTalk(immediate: true)
            stopLocalTalk()
        }
        changed()
    }

    private func markPeerSeen() {
        lastPeerSeen = now()
        peerOnline = true
    }

    private func clearPeer() {
        cancelMicrophonePermissionRequest()
        stopLocalTalk()
        stopRemoteTalk(immediate: true)
        clearRemoteKey()
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
        peerPaused = false
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
        if logsStatus {
            let voiceStatus = "peer=\(peerShortID ?? "none") ptt=\(pttEnabled) "
                + "transmitting=\(localTalking) receiving=\(remoteTalking) draining=\(remoteTalkEnding) "
                + "audioError=\(lastAudioError ?? "none")"
            // Log only voice transitions, not every packet or microphone buffer.
            if voiceStatus != lastLoggedVoiceStatus {
                lastLoggedVoiceStatus = voiceStatus
                NSLog("Voice link: %@; batches queued=%d received=%d accepted=%d; %@; %@", voiceStatus,
                      sentAudioBatches, receivedAudioBatches, acceptedAudioBatches,
                      audioCapture?.diagnostics ?? "Capture: not created",
                      audioPlayback?.diagnostics ?? "Playback: not created")
            }
            let status = "transport=\(transportState.text) paired=\(peerPublicKey != nil) online=\(peerOnline) "
                + "peerPaused=\(peerPaused) "
                + "capture=\(capsInterceptor.isActive) led=\(led.mode.rawValue) "
                + "presses=\(localPressCount) sentKeys=\(sentKeyMessages) receivedKeys=\(receivedKeyMessages)"
            if status != lastLoggedLinkStatus {
                lastLoggedLinkStatus = status
                NSLog("Light link: %@", status)
            }
        }
        DispatchQueue.main.async { [weak self] in self?.onStateChange?() }
    }

    private func recordAudioError(_ message: String) {
        lastAudioError = message
        lastError = message
    }
}

// MARK: - Menu-bar interface

enum FireflyIcon {
    enum TailState {
        case idle
        case outgoing
        case notification
        case unavailable
    }

    static let idle = makeImage(tail: .idle)
    static let outgoing = makeImage(tail: .outgoing)
    static let notification = makeImage(tail: .notification)
    static let unavailable = makeImage(tail: .unavailable)

    static func tailState(localActive: Bool, attention: Bool, peerUnavailable: Bool = false,
                          permissionsRequired: Bool = false) -> TailState {
        if permissionsRequired { return .notification }
        if peerUnavailable { return .unavailable }
        if localActive { return .outgoing }
        if attention { return .notification }
        return .idle
    }

    static func image(tail: TailState) -> NSImage {
        switch tail {
        case .idle: return idle
        case .outgoing: return outgoing
        case .notification: return notification
        case .unavailable: return unavailable
        }
    }

    private static func makeImage(tail: TailState) -> NSImage {
        // Vector artwork stays crisp at both Retina and standard scale. Idle
        // artwork is a template; colored tails keep an adaptive body.
        let isColored = tail != .idle
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
            case .unavailable:
                NSColor.systemBlue.setFill()
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
        image.accessibilityDescription = tail == .unavailable
            ? "Dit, the slock firefly — peer unavailable" : "Dit, the slock firefly"
        return image
    }
}

// Accessory apps have no nib-provided Edit menu. AppKit needs these actions
// in the main menu to route text-editing shortcuts to the active field editor.
func makeMainMenu() -> NSMenu {
    let main = NSMenu()
    let appItem = main.addItem(withTitle: SlockConfig.appName, action: nil, keyEquivalent: "")
    appItem.submenu = NSMenu(title: SlockConfig.appName)
    appItem.submenu?.addItem(withTitle: "Quit slock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

    let editItem = main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "")
    let edit = NSMenu(title: "Edit")
    editItem.submenu = edit
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    // Accept Control+V as an alias while keeping the standard menu shortcut.
    let controlPaste = edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    controlPaste.keyEquivalentModifierMask = .control
    controlPaste.isHidden = true
    controlPaste.allowsKeyEquivalentWhenHidden = true
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    return main
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

final class PermissionSetupWindow: NSWindowController, NSWindowDelegate {
    private let setup: KeyboardPermissionSetup
    private let onReady: () -> Void
    private let readyMessage: () -> String
    private let refreshRequirements: () -> Void
    private let useLightsOnly: () -> Void
    private let accessibilityStatus = NSTextField(labelWithString: "Required — not enabled")
    private let monitoringStatus = NSTextField(labelWithString: "Required — not enabled")
    private let microphoneStatus = NSTextField(labelWithString: "Required — not enabled")
    private let titleLabel = NSTextField(labelWithString: "Give slock access to your keyboard")
    private let introduction = NSTextField(wrappingLabelWithString: "")
    private let progress = NSTextField(wrappingLabelWithString:
        "Enable the required permissions above. macOS may open a dialog; the Enable buttons also take you to Settings.")
    private let closeButton = NSButton(title: "Later", target: nil, action: nil)
    private let lightsOnlyButton = NSButton(title: "Use lights only", target: nil, action: nil)
    private var permissionButtons: [KeyboardPermission: NSButton] = [:]
    private var microphoneRow: NSView?
    private var contentStack: NSStackView?
    private var timer: Timer?
    private var wasReady = false
    private var pendingExplicitPermission: KeyboardPermission?

    init(setup: KeyboardPermissionSetup, onReady: @escaping () -> Void,
         readyMessage: @escaping () -> String, refreshRequirements: @escaping () -> Void = {},
         useLightsOnly: @escaping () -> Void = {}) {
        self.setup = setup
        self.onReady = onReady
        self.readyMessage = readyMessage
        self.refreshRequirements = refreshRequirements
        self.useLightsOnly = useLightsOnly
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Permissions Required"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        let stack = NSStackView()
        contentStack = stack
        stack.orientation = .vertical
        stack.detachesHiddenViews = true
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24)
        ])
        func add(_ view: NSView) {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        titleLabel.font = .systemFont(ofSize: 21, weight: .semibold)
        add(titleLabel)
        introduction.stringValue = "Enable keyboard access so slock can send your Caps Lock presses and control your keyboard light."
        add(introduction)

        func permissionRow(title: String, explanation: String, status: NSTextField,
                           buttonTitle: String, action: Selector, permission: KeyboardPermission) -> NSStackView {
            let heading = NSTextField(labelWithString: title)
            heading.font = .boldSystemFont(ofSize: 14)
            let detail = NSTextField(wrappingLabelWithString: explanation)
            detail.preferredMaxLayoutWidth = 340
            let labels = NSStackView(views: [heading, detail, status])
            labels.orientation = .vertical
            labels.alignment = .leading
            labels.spacing = 4
            let button = NSButton(title: buttonTitle, target: self, action: action)
            permissionButtons[permission] = button
            button.bezelStyle = .rounded
            button.setContentHuggingPriority(.required, for: .horizontal)
            let row = NSStackView(views: [labels, button])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 16
            return row
        }
        add(permissionRow(title: "1. Accessibility",
                          explanation: "Lets slock capture Caps Lock and prevent normal capitals while it is active.",
                          status: accessibilityStatus, buttonTitle: "Enable Accessibility…",
                          action: #selector(requestAccessibility), permission: .accessibility))
        add(permissionRow(title: "2. Input Monitoring",
                          explanation: "Lets slock receive keyboard events and control the Caps Lock light.",
                          status: monitoringStatus, buttonTitle: "Enable Input Monitoring…",
                          action: #selector(requestMonitoring), permission: .inputMonitoring))
        let microphoneRow = permissionRow(title: "3. Microphone",
            explanation: "Lets slock send your voice while you hold Caps Lock with push-to-talk enabled.",
            status: microphoneStatus, buttonTitle: "Enable Microphone…",
            action: #selector(requestMicrophone), permission: .microphone)
        self.microphoneRow = microphoneRow
        microphoneRow.isHidden = !setup.microphoneRequired
        add(microphoneRow)
        let instructions = NSTextField(wrappingLabelWithString:
            "Enable only the permissions marked Required. Keyboard approval is managed in System Settings → Privacy & Security. If slock is missing, click + and choose this copy of the app. If an old entry is already on, remove it and add this copy again. Reopen slock if macOS asks.")
        instructions.textColor = .secondaryLabelColor
        add(instructions)
        add(progress)
        let showApp = NSButton(title: "Show App in Finder", target: self, action: #selector(showAppInFinder))
        showApp.bezelStyle = .rounded
        closeButton.target = self
        closeButton.action = #selector(dismissSetup)
        closeButton.bezelStyle = .rounded
        lightsOnlyButton.target = self
        lightsOnlyButton.action = #selector(switchToLightsOnly)
        lightsOnlyButton.bezelStyle = .rounded
        lightsOnlyButton.isHidden = !setup.microphoneRequired
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [showApp, spacer, lightsOnlyButton, closeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        add(buttons)
        updateContents(state: setup.state)
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 600, height: max(460, stack.fittingSize.height + 48)))
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        wasReady = false
        pendingExplicitPermission = nil
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.displayIfNeeded()
        timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        // Put the explanation on screen before invoking macOS permission UI.
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    private func updateContents(state: KeyboardPermissionState) {
        microphoneRow?.isHidden = !state.microphoneRequired
        lightsOnlyButton.isHidden = !state.microphoneRequired
        titleLabel.stringValue = state.microphoneRequired ? "Permissions for push-to-talk" : "Give slock access to your keyboard"
        introduction.stringValue = state.microphoneRequired
            ? "Push-to-talk needs keyboard access and your microphone. Enable each required permission to share light and voice."
            : "Enable keyboard access so slock can send your Caps Lock presses and control your keyboard light."
        accessibilityStatus.stringValue = state.accessibility ? "Enabled" : "Required — not enabled"
        monitoringStatus.stringValue = state.inputMonitoring ? "Enabled" : "Required — not enabled"
        microphoneStatus.stringValue = state.microphone ? "Enabled" : "Required — not enabled"
        accessibilityStatus.textColor = state.accessibility ? .systemGreen : .secondaryLabelColor
        monitoringStatus.textColor = state.inputMonitoring ? .systemGreen : .secondaryLabelColor
        microphoneStatus.textColor = state.microphone ? .systemGreen : .secondaryLabelColor
        for (permission, button) in permissionButtons {
            let granted = state.isGranted(permission)
            button.isEnabled = !granted && setup.requestingPermission == nil
            if granted { button.title = "Enabled" }
            else if setup.requestingPermission == permission { button.title = "Requesting…" }
            else {
                switch permission {
                case .accessibility: button.title = "Enable Accessibility…"
                case .inputMonitoring: button.title = "Enable Input Monitoring…"
                case .microphone: button.title = "Enable Microphone…"
                }
            }
        }
        progress.stringValue = state.isReady ? readyMessage()
            : "Enable the required permissions above. macOS may open a dialog; the Enable buttons also take you to Settings."
        closeButton.title = state.isReady ? "Done" : "Later"
        if let stack = contentStack {
            window?.contentView?.layoutSubtreeIfNeeded()
            window?.setContentSize(NSSize(width: 600, height: max(460, stack.fittingSize.height + 48)))
        }
    }

    private func refresh() {
        guard window?.isVisible == true else { return }
        refreshRequirements()
        let state = setup.state
        if state.isReady && !wasReady { onReady() }
        wasReady = state.isReady
        updateContents(state: state)
        if let pending = pendingExplicitPermission {
            guard state.isGranted(pending) else { return }
            pendingExplicitPermission = nil
        }
        setup.requestNextAutomatically()
    }

    private func request(_ permission: KeyboardPermission) {
        // A prior denial can suppress the native dialog. An explicit retry
        // always has a Settings fallback, even if macOS keeps its old entry.
        guard setup.requestingPermission == nil, !setup.state.isGranted(permission) else { return }
        pendingExplicitPermission = permission
        let wasRequested = setup.hasRequested(permission)
        setup.request(permission) { [weak self] in
            guard let self, self.window?.isVisible == true else { return }
            if !self.setup.state.isGranted(permission), permission != .microphone || wasRequested {
                NSWorkspace.shared.open(permission.settingsURL)
            }
            self.refresh()
        }
        refresh()
    }

    @objc private func requestAccessibility() { request(.accessibility) }
    @objc private func requestMonitoring() { request(.inputMonitoring) }
    @objc private func requestMicrophone() { request(.microphone) }
    @objc private func switchToLightsOnly() {
        useLightsOnly()
        pendingExplicitPermission = nil
        refresh()
    }
    @objc private func showAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
    @objc private func dismissSetup() { close() }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var controller: SlockController!
    private var instanceLock: SingleInstanceLock?
    private var titleMenuItem: NSMenuItem?
    private var optionOnlyItems: [NSMenuItem] = []
    private var menuModifierTimer: Timer?
    private let updateChecker = UpdateChecker()
    private var updateTimer: Timer?
    private var updateMenuItem: NSMenuItem?
    private let permissionSetup = KeyboardPermissionSetup()
    private var permissionWindow: PermissionSetupWindow?
    private var permissionsRequiredItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = makeMainMenu()
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
        updateChecker.onChange = { [weak self] in self?.refreshUpdateMenuItem() }
        updateChecker.checkIfNeeded()
        let updateTimer = Timer(timeInterval: UpdateChecker.retryInterval, repeats: true) { [weak self] _ in
            self?.updateChecker.checkIfNeeded()
        }
        self.updateTimer = updateTimer
        RunLoop.main.add(updateTimer, forMode: .common)
        updateStatusItem()
        enableLaunchAtLoginByDefault()
        updateStatusItem()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.permissionSetup.shouldShowOnLaunch(
                captureRequested: self.controller.capsInterceptor.isRequested) else { return }
            self.showPermissions()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuModifierTimer?.invalidate()
        updateTimer?.invalidate()
        permissionWindow?.close()
        controller?.shutdown()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        updateStatusItem()
    }

    private func permissionState() -> KeyboardPermissionState {
        let state = controller.permissionState(grants: permissionSetup.state)
        permissionSetup.microphoneRequired = state.microphoneRequired
        return state
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
        updateChecker.checkIfNeeded()
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
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? SlockConfig.appVersion
        let title = "slock\(hidden ? "" : " \(version)") - \(controller.statusText)"
        if titleMenuItem?.title != title {
            titleMenuItem?.title = title
        }
        for item in optionOnlyItems where item.isHidden != hidden {
            item.isHidden = hidden
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button, let controller else { return }
        let permissions = permissionState()
        if let item = permissionsRequiredItem { PermissionMenu.update(item, state: permissions) }
        let needsAttention: Bool
        switch controller.attention {
        case .pairing, .ptt:
            needsAttention = true
        case .none:
            needsAttention = false
        }
        let tail = FireflyIcon.tailState(
            localActive: controller.localKeyDown || controller.localTalking,
            attention: needsAttention,
            peerUnavailable: controller.peerUnavailable,
            permissionsRequired: !permissions.isReady
        )
        button.image = FireflyIcon.image(tail: tail)
        button.title = ""
        button.toolTip = "slock - \(permissions.isReady ? controller.statusText : PermissionMenu.title)"
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        optionOnlyItems.removeAll()
        permissionsRequiredItem = nil
        titleMenuItem = addDisabled("slock - \(controller.statusText)")
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
            add("Unpair", #selector(unpair))
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
                addDisabled("PTT Invitation Sent")
            } else {
                add("Invite Peer to Enable PTT", #selector(invitePTT))
            }
        }

        menu.addItem(.separator())
        let captureActive = controller.capsInterceptor.isActive
        if captureActive {
            add("Pause Slock", #selector(pauseSlock))
        } else {
            add("Resume Slock", #selector(resumeSlock))
        }
        let permissions = add(PermissionMenu.title, #selector(showPermissions))
        PermissionMenu.update(permissions, state: permissionState())
        permissionsRequiredItem = permissions
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
        updateMenuItem = add("Update slock", #selector(updateSlock))
        refreshUpdateMenuItem()
        add("Quit slock", #selector(quit))
        updateOptionOnlyItems()
    }

    private func refreshUpdateMenuItem() {
        guard let item = updateMenuItem else { return }
        item.title = "Download Update…"
        item.isHidden = updateChecker.availableUpdate == nil
        item.isEnabled = updateChecker.availableUpdate?.releaseURL != nil
        item.toolTip = "Open the new release on GitHub to review and download it."
    }

    @objc private func updateSlock() {
        guard let url = updateChecker.availableUpdate?.releaseURL else { return }
        if !NSWorkspace.shared.open(url) {
            showAlert(title: "Could not open the release", message: "Open the slock releases page on GitHub to download the update.")
        }
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
        controller.unpair()
    }

    @objc private func invitePTT() {
        controller.invitePTT { [weak self] granted in
            if !granted {
                if let self, self.controller.requiresMicrophonePermission, !self.permissionState().isReady {
                    self.showPermissions()
                    return
                }
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
                if let self, self.controller.requiresMicrophonePermission, !self.permissionState().isReady {
                    self.showPermissions()
                    return
                }
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

    @objc private func pauseSlock() {
        controller.setCaptureEnabled(false)
    }

    @objc private func resumeSlock() {
        controller.setCaptureEnabled(true)
        if !permissionState().isReady { showPermissions() }
    }

    @objc private func showPermissions() {
        _ = permissionState()
        if permissionWindow == nil {
            permissionWindow = PermissionSetupWindow(setup: permissionSetup, onReady: { [weak self] in
                self?.controller.retryCapture()
                self?.controller.retryLED()
            }, readyMessage: { [weak self] in
                guard let self else { return "All required permissions are enabled." }
                if self.controller.capsInterceptor.isActive {
                    return "All required permissions are enabled and Caps Lock capture is active."
                }
                if !self.controller.capsInterceptor.isRequested {
                    return "All required permissions are enabled. Slock remains paused; choose Resume Slock when ready."
                }
                return "All required permissions are enabled. \(self.controller.capsInterceptor.lastError ?? "Quit and reopen slock if capture remains inactive.")"
            }, refreshRequirements: { [weak self] in
                _ = self?.permissionState()
            }, useLightsOnly: { [weak self] in
                self?.controller.disablePTT()
            })
        }
        permissionWindow?.present()
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
        let text = controller.diagnostics()
        let alert = NSAlert()
        alert.messageText = "slock Diagnostics"
        alert.informativeText = text
        alert.addButton(withTitle: "Copy Diagnostics")
        alert.addButton(withTitle: "Close")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
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
        let storage = try PrivateStorage(directory: directory)
        descriptor = try storage.openFile("instance.lock").descriptor
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
