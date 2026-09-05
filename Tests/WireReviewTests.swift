import CryptoKit
import Foundation

private struct WireReviewFailure: Error { let message: String }

private func wireCheck(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw WireReviewFailure(message: message) }
}

// A protocol-v2 peer with the original process-wide boot identifier. Keeping
// this fixture independent of SecureWire also checks the on-wire compatibility.
private final class ProcessBootPeer {
    let identity: IdentityStore
    let boot = randomUInt64()
    private var sequence: UInt64 = 0
    private var remoteHint: UInt64 = 0
    private var remoteBoot: UInt64?
    private var remoteSequence: UInt64 = 0

    init(identity: IdentityStore) { self.identity = identity }

    private func key(for peer: Data) throws -> SymmetricKey {
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer)
        let secret = try identity.privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        let keys = [identity.publicKey, peer].sorted { $0.lexicographicallyPrecedes($1) }
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("CapsLink/v1/E2E".utf8),
                                             sharedInfo: keys[0] + keys[1], outputByteCount: 32)
    }

    func seal(_ kind: WireKind, payload: Data = Data(), to peer: Data,
              recipientBoot: UInt64? = nil) throws -> Data {
        sequence += 1
        var plaintext = Data([kind.rawValue])
        plaintext.appendUInt64(boot)
        plaintext.appendUInt64(sequence)
        plaintext.appendUInt64(recipientBoot ?? (kind == .hello ? remoteHint : remoteBoot) ?? 0)
        plaintext.append(payload)
        let header = Data([2]) + identity.publicKey
        return header + (try ChaChaPoly.seal(plaintext, using: key(for: peer), authenticating: header)).combined
    }

    @discardableResult
    func open(_ packet: Data) throws -> (confirmed: Bool, kind: WireKind, payload: Data) {
        try wireCheck(packet.first == 2 && packet.count >= 86, "Protocol-v2 envelope changed")
        let sender = Data(packet[1..<33])
        let plaintext = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: packet.dropFirst(33)),
                                           using: key(for: sender), authenticating: packet.prefix(33))
        guard let kind = WireKind(rawValue: plaintext[0]), let senderBoot = plaintext.uint64(at: 1),
              let incomingSequence = plaintext.uint64(at: 9), let recipientBoot = plaintext.uint64(at: 17) else {
            throw WireReviewFailure(message: "Malformed protocol-v2 plaintext")
        }
        if kind == .hello {
            if recipientBoot != boot {
                remoteHint = senderBoot
                return (false, kind, Data())
            }
            if remoteBoot != senderBoot { remoteSequence = 0 }
            remoteBoot = senderBoot
        } else {
            try wireCheck(senderBoot == remoteBoot && recipientBoot == boot, "Legacy peer rejected command boot")
        }
        try wireCheck(incomingSequence > remoteSequence, "Legacy peer rejected replayed sequence")
        remoteHint = senderBoot
        remoteSequence = incomingSequence
        return (true, kind, Data(plaintext.dropFirst(25)))
    }
}

enum WireReviewTests {
    static func run(root: URL) throws {
        try replayAfterEviction(root: root)
        try protectedSessionSurvivesFlood(root: root)
        try unknownCommandsDoNotEvictSessions(root: root)
        try outgoingSessionHonorsProtection(root: root)
        try protocolTwoCompatibility(root: root)
    }

    private static func identity(_ name: String, root: URL) throws -> IdentityStore {
        try IdentityStore(directory: root.appendingPathComponent("wire-review-\(name)-\(UUID())"))
    }

    @discardableResult
    private static func handshake(_ a: SecureWire, identity alice: IdentityStore,
                                  _ b: SecureWire, identity bob: IdentityStore) throws -> Data {
        let first = b.open(try a.seal(kind: .hello, payload: Data(), to: bob.publicKey))
        try wireCheck(first?.needsHelloReply == true, "No handshake challenge")
        let second = a.open(try b.seal(kind: .hello, payload: Data(), to: alice.publicKey))
        try wireCheck(second?.sessionConfirmed == true, "Initiator did not confirm peer")
        let confirmedHello = try a.seal(kind: .hello, payload: Data([1]), to: bob.publicKey)
        try wireCheck(b.open(confirmedHello)?.sessionConfirmed == true, "Responder did not confirm peer")
        return confirmedHello
    }

    private static func fillCache(_ wire: SecureWire, receiver: IdentityStore, root: URL,
                                  protecting protected: Set<Data> = []) throws {
        for _ in 0..<32 {
            let stranger = try identity("stranger", root: root)
            let sender = ProcessBootPeer(identity: stranger)
            let hello = try sender.seal(.hello, to: receiver.publicKey)
            try wireCheck(wire.open(hello, protecting: protected)?.sessionConfirmed == false,
                          "An initial stranger HELLO was confirmed")
        }
    }

    static func replayAfterEviction(root: URL) throws {
        let alice = try identity("alice", root: root), bob = try identity("bob", root: root)
        let a = SecureWire(identity: alice), b = SecureWire(identity: bob)
        let hello = try handshake(a, identity: alice, b, identity: bob)
        let command = try a.seal(kind: .pairRequest, payload: Data(), to: bob.publicKey)
        try wireCheck(b.open(command)?.kind == .pairRequest, "Original command was rejected")
        try fillCache(b, receiver: bob, root: root)
        try wireCheck(!b.hasSession(with: alice.publicKey), "Test did not evict Alice's session")
        try wireCheck(b.open(hello)?.sessionConfirmed == false, "Eviction made a recorded HELLO valid again")
        try wireCheck(b.open(command) == nil, "Eviction made a recorded command valid again")
        try handshake(a, identity: alice, b, identity: bob)
        try wireCheck(b.open(command) == nil, "Old command was accepted after a fresh handshake")
        try wireCheck(b.open(try a.seal(kind: .keyState, payload: Data([0]), to: bob.publicKey))?.payload == Data([0]),
                      "Fresh commands stopped working after eviction")
    }

    static func protectedSessionSurvivesFlood(root: URL) throws {
        let alice = try identity("protected-alice", root: root), bob = try identity("protected-bob", root: root)
        let a = SecureWire(identity: alice), b = SecureWire(identity: bob)
        let hello = try handshake(a, identity: alice, b, identity: bob)
        let command = try a.seal(kind: .keyState, payload: Data([1]), to: bob.publicKey)
        try wireCheck(b.open(command) != nil, "Original command was rejected")
        try fillCache(b, receiver: bob, root: root, protecting: [alice.publicKey])
        try wireCheck(b.hasSession(with: alice.publicKey), "A protected session was evicted")
        try wireCheck(b.open(hello) == nil && b.open(command) == nil, "Protected replay state was lost")
        try wireCheck(b.open(try a.seal(kind: .keyState, payload: Data([0]), to: bob.publicKey)) != nil,
                      "Protected peer stopped working after cache pressure")
    }

    static func unknownCommandsDoNotEvictSessions(root: URL) throws {
        let alice = try identity("known-alice", root: root), bob = try identity("known-bob", root: root)
        let a = SecureWire(identity: alice), b = SecureWire(identity: bob)
        try handshake(a, identity: alice, b, identity: bob)
        try fillCache(b, receiver: bob, root: root, protecting: [alice.publicKey])
        let stranger = ProcessBootPeer(identity: try identity("command-stranger", root: root))
        let invalidCommand = try stranger.seal(.keyState, payload: Data([1]), to: bob.publicKey)
        try wireCheck(b.open(invalidCommand) == nil, "Unknown command was accepted")
        try wireCheck(b.hasSession(with: alice.publicKey), "An invalid command evicted a valid peer session")
    }

    static func outgoingSessionHonorsProtection(root: URL) throws {
        let alice = try identity("outgoing-alice", root: root), bob = try identity("outgoing-bob", root: root)
        let a = SecureWire(identity: alice), b = SecureWire(identity: bob)
        try handshake(a, identity: alice, b, identity: bob)
        var protected: Set<Data> = [alice.publicKey]
        for _ in 0..<31 {
            let stranger = try identity("outgoing-stranger", root: root)
            let sender = ProcessBootPeer(identity: stranger)
            try wireCheck(b.open(try sender.seal(.hello, to: bob.publicKey)) != nil, "Stranger HELLO rejected")
            protected.insert(stranger.publicKey)
        }
        let target = try identity("outgoing-target", root: root)
        var refused = false
        do { _ = try b.seal(kind: .hello, payload: Data(), to: target.publicKey, protecting: protected) }
        catch { refused = true }
        try wireCheck(refused, "Outgoing HELLO evicted a protected session from a full cache")
        try wireCheck(b.hasSession(with: alice.publicKey), "A protected peer was lost when all slots were reserved")
        _ = try b.seal(kind: .hello, payload: Data(), to: target.publicKey, protecting: [alice.publicKey])
        try wireCheck(b.hasSession(with: alice.publicKey), "Outgoing HELLO evicted the protected active peer")
        try wireCheck(b.open(try a.seal(kind: .keyState, payload: Data([1]), to: bob.publicKey)) != nil,
                      "Protected active peer stopped working after an outgoing HELLO")
    }

    static func protocolTwoCompatibility(root: URL) throws {
        let alice = try identity("modern", root: root), bob = try identity("legacy", root: root)
        let modern = SecureWire(identity: alice), legacy = ProcessBootPeer(identity: bob)
        try wireCheck(try !legacy.open(modern.seal(kind: .hello, payload: Data(), to: bob.publicKey)).confirmed,
                      "Initial modern HELLO was prematurely confirmed")
        try wireCheck(modern.open(try legacy.seal(.hello, to: alice.publicKey))?.sessionConfirmed == true,
                      "Modern peer did not confirm legacy peer")
        try wireCheck(try legacy.open(modern.seal(kind: .hello, payload: Data(), to: bob.publicKey)).confirmed,
                      "Legacy peer did not confirm modern peer")
        let oldHello = try legacy.seal(.hello, to: alice.publicKey)
        let oldCommand = try legacy.seal(.keyState, payload: Data([1]), to: alice.publicKey)
        try wireCheck(modern.open(oldHello)?.sessionConfirmed == true, "Legacy HELLO rejected")
        try wireCheck(modern.open(oldCommand)?.payload == Data([1]), "Legacy command rejected")
        try wireCheck(try legacy.open(modern.seal(kind: .keyState, payload: Data([0]), to: bob.publicKey)).payload == Data([0]),
                      "Modern command rejected by legacy peer")
        try fillCache(modern, receiver: alice, root: root)
        try wireCheck(!modern.hasSession(with: bob.publicKey), "Test did not evict legacy session")
        try wireCheck(modern.open(oldHello)?.sessionConfirmed == false, "Legacy recording confirmed an evicted session")
        try wireCheck(modern.open(oldCommand) == nil, "Legacy command recording authorized an evicted session")
        try legacy.open(modern.seal(kind: .hello, payload: Data(), to: bob.publicKey))
        try wireCheck(modern.open(try legacy.seal(.hello, to: alice.publicKey))?.sessionConfirmed == true,
                      "Modern peer could not reconnect to legacy peer after eviction")
        try wireCheck(try legacy.open(modern.seal(kind: .hello, payload: Data(), to: bob.publicKey)).confirmed,
                      "Legacy peer could not reconnect to modern peer after eviction")
        try wireCheck(modern.open(oldCommand) == nil, "Old legacy command accepted after reconnection")
        try wireCheck(modern.open(try legacy.seal(.keyState, payload: Data([0]), to: alice.publicKey))?.payload == Data([0]),
                      "Legacy peer could not send fresh commands after reconnection")
    }
}
