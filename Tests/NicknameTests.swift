import Foundation

private final class NickPreferences: Preferences {
    var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func synchronize() -> Bool { true }
}

private final class NickRelay: RelayTransport {
    var onStateChange: ((MQTTClient.State) -> Void)?
    var onMessage: ((String, Data) -> Void)?
    var packets: [Data] = []
    func start() { onStateChange?(.connected) }
    func stop() { onStateChange?(.stopped) }
    func publish(topic: String, payload: Data) { packets.append(payload) }
}

private struct NickFailure: Error { let message: String }
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NickFailure(message: message) }
}

private final class NickMac {
    let preferences = NickPreferences()
    let relay = NickRelay()
    let store: PeerStore
    let controller: SlockController
    init(_ identity: IdentityStore, name: String) {
        store = PeerStore(defaults: preferences)
        store.ownNickname = name
        let interceptor = CapsInterceptor(testDefaults: preferences, process: { _, _ in (0, "()", "") })
        controller = SlockController(identity: identity, peerStore: store, capsInterceptor: interceptor,
            led: CapsLED(directWriter: { _ in true }), transport: relay)
        relay.start()
    }
    deinit { controller.shutdown() }
}

private func exchange(_ a: NickMac, _ b: NickMac) throws {
    for _ in 0..<150 {
        if a.relay.packets.isEmpty && b.relay.packets.isEmpty { return }
        if !a.relay.packets.isEmpty { b.relay.onMessage?("", a.relay.packets.removeFirst()) }
        if !b.relay.packets.isEmpty { a.relay.onMessage?("", b.relay.packets.removeFirst()) }
    }
    throw NickFailure(message: "Nickname exchange did not settle")
}

@main enum NicknameTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("slock-nicknames-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let alice = try IdentityStore(directory: root.appendingPathComponent("alice"))
        let bob = try IdentityStore(directory: root.appendingPathComponent("bob"))
        var failures = 0, count = 0
        func test(_ name: String, _ body: () throws -> Void) {
            count += 1
            do { try body(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        test("recent peers persist and use self-name, local alias, then code suffix") {
            let prefs = NickPreferences(), store = PeerStore(defaults: NickPreferences())
            store.establish(alice.publicKey, ownNickname: "Alice", localNickname: "Desk")
            try expect(store.entry(for: alice.publicKey)?.displayName == "Alice", "self-name did not win")
            store.rename(alice.publicKey, ownNickname: "")
            try expect(store.entry(for: alice.publicKey)?.displayName == "Desk", "local fallback missing")
            store.rename(alice.publicKey, localNickname: "")
            try expect(store.entry(for: alice.publicKey)?.displayName == String(alice.pairingCode.suffix(6)), "wrong fallback")
            let saved = PeerStore(defaults: prefs)
            saved.ownNickname = "My Mac"
            saved.establish(alice.publicKey, ownNickname: "Alice", localNickname: "Desk")
            let restored = PeerStore(defaults: prefs)
            try expect(restored.ownNickname == "My Mac" && restored.recent.first?.displayName == "Alice", "names did not persist")
        }
        test("recent ordering changes only on established pairings, without duplicates") {
            let store = PeerStore(defaults: NickPreferences())
            store.establish(alice.publicKey, ownNickname: "Alice")
            store.establish(bob.publicKey, ownNickname: "Bob")
            store.rename(alice.publicKey, ownNickname: "New Alice")
            try expect(store.recent.map(\.publicKey) == [bob.publicKey, alice.publicKey], "rename reordered history")
            store.establish(alice.publicKey, ownNickname: nil)
            try expect(store.recent.map(\.publicKey) == [alice.publicKey, bob.publicKey], "reconnect not first or duplicated")
            store.peerPublicKey = nil
            try expect(store.recent.count == 2, "unpair erased recents")
        }
        test("existing installations migrate their established peer into Recent") {
            let prefs = NickPreferences()
            prefs.set(bob.publicKey, forKey: "CapsLink.peerPublicKey")
            let store = PeerStore(defaults: prefs)
            try expect(store.recent.first?.publicKey == bob.publicKey, "existing pairing not migrated")
        }
        test("profile payloads bound and sanitize names while preserving explicit removal") {
            try expect(PeerProfile.read(PeerProfile.payload("  Studio\nMac  ")) == "Studio Mac", "name normalization")
            try expect(PeerProfile.read(PeerProfile.payload("")) == "", "empty name could not clear old name")
            try expect(PeerProfile.read(Data()) == nil && PeerProfile.read(Data(repeating: 32, count: 1025)) == nil, "invalid profile accepted")
            try expect(PeerProfile.clean(String(repeating: "x", count: 100)).count == 48, "name length not bounded")
        }
        test("an unsolicited request cannot read the recipient's name before acceptance") {
            let a = NickMac(alice, name: "Alice's Mac"), b = NickMac(bob, name: "Bob's Mac")
            try a.controller.pair(using: bob.pairingCode, localNickname: "My private alias")
            try exchange(a, b)
            try expect(b.controller.incomingNickname == "Alice's Mac", "request did not include sender name")
            try expect(a.controller.outgoingRemoteNickname == nil, "recipient name leaked before acceptance")
            b.controller.saveNicknames(own: "Bob's Mac", peer: alice.publicKey, local: "Private")
            try exchange(a, b)
            try expect(a.controller.outgoingRemoteNickname == nil, "saving names leaked a profile to an unaccepted request")
            try expect(a.store.recent.isEmpty && b.store.recent.isEmpty, "unaccepted request entered Recent")
            b.controller.acceptIncomingPair(expected: alice.publicKey, localNickname: "Other private alias")
            try exchange(a, b)
            try expect(a.store.recent.first?.displayName == "Bob's Mac" && b.store.recent.first?.displayName == "Alice's Mac", "accepted names missing")
            try expect(a.store.recent.first?.localNickname == "My private alias", "local fallback lost")
            try expect(b.store.recent.first?.localNickname == "Other private alias", "alias leaked between peers")
            a.controller.unpair()
            try exchange(a, b)
            try expect(a.store.recent.count == 1 && b.store.recent.count == 1, "history lost on unpair")
        }
        test("nickname withdrawal restores local fallback and updates do not reorder Recent") {
            let a = NickMac(alice, name: "Alice"), b = NickMac(bob, name: "Bob")
            try a.controller.pair(using: bob.pairingCode, localNickname: "Studio")
            try exchange(a, b)
            b.controller.acceptIncomingPair(expected: alice.publicKey)
            try exchange(a, b)
            b.controller.saveNicknames(own: "", peer: alice.publicKey, local: "")
            try exchange(a, b)
            try expect(a.store.recent.first?.displayName == "Studio", "withdrawn name hid local alias")
        }
        test("declined requests never become recent pairings") {
            let a = NickMac(alice, name: "Alice"), b = NickMac(bob, name: "Bob")
            try a.controller.pair(using: bob.pairingCode)
            try exchange(a, b)
            b.controller.rejectIncomingPair(expected: alice.publicKey)
            try exchange(a, b)
            try expect(a.store.recent.isEmpty && b.store.recent.isEmpty, "declined peer persisted")
        }
        print("\(count - failures)/\(count) nickname tests passed")
        if failures > 0 { exit(1) }
    }
}
