import Foundation
import Darwin
import CoreGraphics
import AppKit

private struct Failure: Error { let message: String }
private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw Failure(message: message) }
}
private func mustThrow(_ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw Failure(message: "Expected an error")
}

private final class MemoryPreferences: Preferences {
    var values: [String: Any] = [:]
    var syncSucceeds = true
    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func synchronize() -> Bool { syncSucceeds }
}

private final class FakeHID {
    var output = "(null)"
    var writes: [String] = []
    var failWrites = false
    var ignoreWrites = false
    func run(_ command: String, _ arguments: [String]) -> (Int32, String, String) {
        if arguments.contains("--get") { return (0, output, "") }
        writes.append(arguments.last!)
        if !failWrites, !ignoreWrites,
           let data = arguments.last?.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let entries = object["UserKeyMapping"] as? [[String: NSNumber]] {
            output = "(" + entries.map {
                "{ HIDKeyboardModifierMappingSrc = \($0["HIDKeyboardModifierMappingSrc"]!); HIDKeyboardModifierMappingDst = \($0["HIDKeyboardModifierMappingDst"]!); }"
            }.joined(separator: ",") + ")"
        }
        return failWrites ? (1, "", "Simulated hidutil failure") : (0, "", "")
    }
}

private func drainMainQueue() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
}

private final class FakeRelay: RelayTransport {
    var onStateChange: ((MQTTClient.State) -> Void)?
    var onMessage: ((String, Data) -> Void)?
    var packets: [Data] = []
    func start() { onStateChange?(.connected) }
    func stop() { onStateChange?(.stopped) }
    func publish(topic: String, payload: Data) { packets.append(payload) }
}

private final class FakeCapture: VoiceCapture {
    var onError: ((String) -> Void)?
    var onBatch: ((Data) -> Void)?
    var running = false
    func start(onBatch: @escaping (Data) -> Void) throws { self.onBatch = onBatch; running = true }
    func stop() { running = false }
}

private final class FakePlayback: VoicePlayback {
    var onError: ((String) -> Void)?
    var onDrain: (() -> Void)?
    func beginTalk() { onDrain = nil }
    func receiveBatch(_ batch: Data) {}
    func endTalk(completion: @escaping () -> Void) { onDrain = completion }
    func stopImmediately() { onDrain = nil }
    func finish() { let callback = onDrain; onDrain = nil; callback?() }
}

private final class FakeLEDOutput: CapsLEDOutput {
    let allowedAtCreation: Bool
    var lastError: String? { allowedAtCreation ? nil : "Cached keyboard permission denial" }
    var diagnostics: String { allowedAtCreation ? "1 keyboard, 1 successful write" : "1 keyboard, 0 successful writes" }
    init(allowed: Bool) { allowedAtCreation = allowed }
    func set(_ on: Bool) -> Bool { allowedAtCreation }
}

private final class TestMac {
    final class Clock {
        var usesSystemTime = false
        private var fixedTime: TimeInterval = 100
        var time: TimeInterval {
            get { usesSystemTime ? ProcessInfo.processInfo.systemUptime : fixedTime }
            set { fixedTime = newValue }
        }
        var lightWrites: [(time: TimeInterval, down: Bool)] = []
    }
    let clock = Clock()
    let defaults = MemoryPreferences()
    let hid = FakeHID()
    let relay = FakeRelay()
    let capture = FakeCapture()
    let playback = FakePlayback()
    let controller: SlockController
    let peerStore: PeerStore

    init(_ identity: IdentityStore, peer: Data? = nil,
         requestMicrophone: @escaping (@escaping (Bool) -> Void) -> Void = { $0(true) }) {
        peerStore = PeerStore(defaults: defaults)
        peerStore.peerPublicKey = peer
        let interceptor = CapsInterceptor(testDefaults: defaults, process: hid.run)
        let capture = capture, playback = playback, clock = clock
        controller = SlockController(identity: identity, peerStore: peerStore, capsInterceptor: interceptor,
            led: CapsLED(directWriter: { down in
                clock.lightWrites.append((clock.time, down))
                return true
            }), transport: relay,
            makeCapture: { capture }, makePlayback: { playback }, checkAudio: {},
            requestMicrophone: requestMicrophone, now: { clock.time })
        interceptor.start()
    }

    deinit { controller.shutdown() }
    func key(_ down: Bool, timestamp: UInt64? = nil) { controller.capsInterceptor.onKeyState?(down, timestamp) }
    func advance(to time: TimeInterval) {
        clock.time = time
        controller.advanceLightPlayback()
    }
}

private func exchange(_ a: TestMac, _ b: TestMac) throws {
    for _ in 0..<100 {
        if a.relay.packets.isEmpty && b.relay.packets.isEmpty { return }
        if !a.relay.packets.isEmpty { b.relay.onMessage?("", a.relay.packets.removeFirst()) }
        if !b.relay.packets.isEmpty { a.relay.onMessage?("", b.relay.packets.removeFirst()) }
    }
    throw Failure(message: "Controllers did not finish exchanging messages")
}

// A peer that only understands legacy HELLOs lets us inject authenticated
// status packets and verify that old peers keep their key/PTT snapshots.
private func exchange(_ mac: TestMac, _ peer: SecureWire) throws -> [OpenedMessage] {
    var messages: [OpenedMessage] = []
    for _ in 0..<100 {
        if mac.relay.packets.isEmpty { return messages }
        guard let message = peer.open(mac.relay.packets.removeFirst()) else { continue }
        messages.append(message)
        if message.needsHelloReply {
            mac.relay.onMessage?("", try peer.seal(kind: .hello, payload: Data(repeating: 0, count: 9),
                                                  to: mac.controller.identity.publicKey))
        }
    }
    throw Failure(message: "Legacy peer handshake did not settle")
}

@main
enum RegressionTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CapsLink-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var failures = 0
        var count = 0
        func test(_ name: String, _ body: () throws -> Void) {
            count += 1
            do { try body(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        let alice = try IdentityStore(directory: root.appendingPathComponent("alice"))
        let bob = try IdentityStore(directory: root.appendingPathComponent("bob"))
        func handshake(_ a: SecureWire, _ b: SecureWire) throws {
            let first = b.open(try a.seal(kind: .hello, payload: Data(), to: bob.publicKey))
            try check(first?.needsHelloReply == true, "No handshake response")
            let second = a.open(try b.seal(kind: .hello, payload: Data(), to: alice.publicKey))
            try check(second?.sessionConfirmed == true, "Alice did not confirm Bob")
            let third = b.open(try a.seal(kind: .hello, payload: Data(), to: bob.publicKey))
            try check(third?.sessionConfirmed == true, "Bob did not confirm Alice")
        }

        test("byte helpers handle nonzero Data indices and overflowing offsets") {
            var data = Data([99, 1, 2, 3, 4, 5, 6, 7, 8])
            data.removeFirst()
            try check(data.uint16(at: 0) == 0x0102, "uint16 slice")
            try check(data.uint32(at: 0) == 0x01020304, "uint32 slice")
            try check(data.uint64(at: 0) == 0x0102030405060708, "uint64 slice")
            try check(data.uint64(at: Int.max) == nil, "overflow offset")
            try check(data.uint16(at: -1) == nil, "negative offset")
        }
        test("MQTT parses coalesced packets after removing a prefix") {
            var parser = MQTTPacketDecoder()
            try parser.append(Data([0x20, 2, 0, 0, 0x90, 3, 0, 1, 0, 0xd0, 0]))
            try check(try parser.next()?.header == 0x20, "CONNACK")
            try check(try parser.next()?.body == Data([0, 1, 0]), "SUBACK")
            try check(try parser.next()?.header == 0xd0, "PINGRESP")
            try check(try parser.next() == nil, "buffer should be empty")
        }
        test("MQTT parses packets split at every byte boundary") {
            var parser = MQTTPacketDecoder()
            var headers: [UInt8] = []
            for byte: UInt8 in [0x20, 2, 0, 0, 0x90, 3, 0, 1, 0] {
                try parser.append(Data([byte]))
                while let packet = try parser.next() { headers.append(packet.header) }
            }
            try check(headers == [0x20, 0x90], "fragmented stream")
        }
        test("MQTT bounds declared lengths and incomplete input") {
            var parser = MQTTPacketDecoder()
            try parser.append(Data([0x30, 0xff, 0xff, 0xff, 0x7f]))
            try mustThrow { _ = try parser.next() }
            var other = MQTTPacketDecoder()
            try mustThrow { try other.append(Data(count: 65_537)) }
        }
        test("commands require a confirmed fresh session") {
            let a = SecureWire(identity: alice), b = SecureWire(identity: bob)
            try mustThrow { _ = try a.seal(kind: .keyState, payload: Data([1]), to: bob.publicKey) }
            try handshake(a, b)
            let packet = try a.seal(kind: .keyState, payload: Data([1]), to: bob.publicKey)
            try check(b.open(packet)?.payload == Data([1]), "valid command")
            try check(b.open(packet) == nil, "duplicate was accepted")
        }
        test("ciphertext tampering is rejected") {
            let a = SecureWire(identity: alice), b = SecureWire(identity: bob)
            try handshake(a, b)
            var packet = try a.seal(kind: .keyState, payload: Data([1]), to: bob.publicKey)
            packet[packet.endIndex - 1] ^= 1
            try check(b.open(packet) == nil, "tampered authentication tag")
        }
        test("sender restart cannot roll replay protection back to an old boot") {
            let a = SecureWire(identity: alice), b = SecureWire(identity: bob)
            try handshake(a, b)
            let recorded = try a.seal(kind: .pttDisable, payload: Data(count: 8), to: bob.publicKey)
            try check(b.open(recorded) != nil, "original packet")
            let restarted = SecureWire(identity: alice)
            try handshake(restarted, b)
            try check(b.open(recorded) == nil, "old boot replay")
            let laterOldPacket = try a.seal(kind: .keyState, payload: Data([1]), to: bob.publicKey)
            try check(b.open(laterOldPacket) == nil, "retired boot with higher sequence")
            try check(b.open(try restarted.seal(kind: .keyState, payload: Data([0]), to: bob.publicKey)) != nil,
                      "new boot stopped working")
        }
        test("receiver restart rejects recorded hellos and commands as authorization") {
            let a = SecureWire(identity: alice), b = SecureWire(identity: bob)
            try handshake(a, b)
            let hello = try a.seal(kind: .hello, payload: Data([1]), to: bob.publicKey)
            let command = try a.seal(kind: .keyState, payload: Data([1]), to: bob.publicKey)
            let restarted = SecureWire(identity: bob)
            try check(restarted.open(hello)?.sessionConfirmed == false, "old hello confirmed new receiver")
            try check(restarted.open(command) == nil, "old receiver command accepted")
            try handshake(a, restarted)
            try check(restarted.open(command) == nil, "recording accepted after fresh handshake")
        }
        test("session cache eviction requires a fresh receiver challenge") {
            try WireReviewTests.replayAfterEviction(root: root)
        }
        test("session cache pressure preserves protected peers") {
            try WireReviewTests.protectedSessionSurvivesFlood(root: root)
        }
        test("unknown commands cannot evict a legitimate session") {
            try WireReviewTests.unknownCommandsDoNotEvictSessions(root: root)
        }
        test("outgoing handshakes preserve protected sessions and reject a full protected cache") {
            try WireReviewTests.outgoingSessionHonorsProtection(root: root)
        }
        test("per-peer challenges interoperate with original protocol 2 peers") {
            try WireReviewTests.protocolTwoCompatibility(root: root)
        }
        test("unsolicited and stale PTT acceptances never enable the microphone") {
            var consent = PTTConsent()
            try check(!consent.receiveAcceptance(42), "unsolicited acceptance")
            consent.invite()
            let invitation = consent.outgoing!
            try check(!consent.receiveAcceptance(invitation &+ 1), "wrong invitation")
            consent.disable()
            try check(!consent.receiveAcceptance(invitation), "acceptance after disable")
            try check(consent.active == nil, "PTT enabled without consent")
        }
        test("PTT invitations need local acceptance and revocations survive lost controls") {
            var consent = PTTConsent()
            try check(consent.receiveInvitation(42) == nil, "auto-accepted incoming invitation")
            try check(consent.active == nil, "incoming invitation enabled audio")
            try check(consent.accept(42), "local consent")
            consent.receiveRevocation(42)
            try check(consent.active == nil && consent.revoked == 42, "HELLO revocation")
            _ = consent.receiveInvitation(43)
            consent.accept(43)
            consent.receiveRevocation(42)
            try check(consent.active == 43, "old revocation disabled a new agreement")
        }
        test("simultaneous PTT invitations converge on the same agreement") {
            var a = PTTConsent(outgoing: 17), b = PTTConsent(outgoing: 23)
            _ = a.receiveInvitation(23)
            _ = b.receiveInvitation(17)
            try check(a.active == 17 && b.active == 17, "different agreements")
        }
        test("simultaneous PTT invitations recover when the smaller invitation is lost") {
            var a = PTTConsent(outgoing: 17), b = PTTConsent(outgoing: 23)
            let acknowledgment = a.receiveInvitation(23)!
            try check(!b.receiveAcceptance(acknowledgment), "unmatched acceptance was trusted")
            try check(a.outgoing == 17, "chosen invitation was not retained for retry")
            let reply = b.receiveInvitation(a.outgoing!)!
            try check(a.receiveAcceptance(reply), "retried invitation was not acknowledged")
            try check(a.active == 17 && b.active == 17, "lost invitation prevented convergence")
            let confirmation = a.receiveInvitation(b.outgoing!)!
            try check(b.receiveAcceptance(confirmation), "peer could not finish retrying")
            try check(a.receiveInvitation(23) == 17 && a.incoming == nil, "delayed original invite prompted again")
        }
        test("pending PTT negotiation survives restart without reviving disabled consent") {
            let prefs = MemoryPreferences()
            let store = PeerStore(defaults: prefs)
            store.peerPublicKey = bob.publicKey
            store.ptt = PTTConsent(outgoing: 17)
            _ = store.ptt.receiveInvitation(23)
            let restarted = PeerStore(defaults: prefs)
            try check(restarted.ptt.outgoing == 17 && restarted.ptt.active == 17, "negotiation retry lost at restart")
            restarted.ptt.disable()
            try check(PeerStore(defaults: prefs).ptt.outgoing == nil, "disabled invitation restarted")
        }
        test("PTT menu actions refuse a changed invitation before requesting microphone access") {
            var permissionRequests = 0
            let mac = TestMac(alice, peer: bob.publicKey, requestMicrophone: { permissionRequests += 1; $0(true) })
            mac.peerStore.ptt.incoming = 42
            var accepted: Bool?
            mac.controller.acceptPTTInvite(expected: 41) { accepted = $0 }
            try check(accepted == false && permissionRequests == 0, "stale menu action requested access")
            try check(!mac.controller.pttEnabled && mac.peerStore.ptt.incoming == 42, "accepted an unseen invitation")
            mac.controller.rejectPTTInvite(expected: 41)
            try check(mac.peerStore.ptt.incoming == 42, "stale menu rejected a newer invitation")
        }
        test("microphone permission completion cannot accept an invitation changed while waiting") {
            var grant: ((Bool) -> Void)?
            let mac = TestMac(alice, peer: bob.publicKey, requestMicrophone: { grant = $0 })
            mac.peerStore.ptt.incoming = 41
            mac.controller.acceptPTTInvite(expected: 41) { _ in }
            mac.peerStore.ptt.incoming = 42
            grant?(true)
            try check(!mac.controller.pttEnabled && mac.peerStore.ptt.incoming == 42, "stale permission granted consent")
            try check(!mac.controller.requiresMicrophonePermission,
                      "stale acceptance retained its microphone requirement")
        }
        test("remote withdrawal and replacement cancel only their pending microphone acceptance") {
            for replacing in [false, true] {
                var grants: [(Bool) -> Void] = []
                let a = TestMac(alice, peer: bob.publicKey)
                let b = TestMac(bob, peer: alice.publicKey, requestMicrophone: { grants.append($0) })
                a.relay.start(); b.relay.start(); try exchange(a, b)
                a.controller.invitePTT { _ in }
                try exchange(a, b)
                b.controller.acceptPTTInvite(expected: b.peerStore.ptt.incoming!) { _ in }
                try check(b.controller.requiresMicrophonePermission && grants.count == 1,
                          "local acceptance did not await microphone access")
                if replacing { a.controller.invitePTT { _ in } }
                else { a.controller.disablePTT() }
                try exchange(a, b)
                try check(!b.controller.requiresMicrophonePermission,
                          "withdrawn or replaced invitation retained its microphone requirement")
                if replacing {
                    let currentInvitation = b.peerStore.ptt.incoming!
                    b.controller.acceptPTTInvite(expected: currentInvitation) { _ in }
                    try check(grants.count == 2, "replacement acceptance did not request permission")
                    grants[0](false)
                    try check(b.controller.requiresMicrophonePermission
                              && b.peerStore.ptt.incoming == currentInvitation && b.controller.lastError == nil,
                              "stale completion canceled or rejected the newer local acceptance")
                    grants[1](true)
                    try check(b.controller.pttEnabled && b.peerStore.ptt.active == currentInvitation,
                              "newer acceptance could not finish after the stale callback")
                } else {
                    grants[0](false)
                    try check(!b.controller.requiresMicrophonePermission && !b.controller.pttEnabled
                              && b.controller.lastError == nil,
                              "late denial revived a withdrawn microphone request")
                }
            }
        }
        test("a lost PTT rejection is retried without prompting the recipient again") {
            let a = TestMac(alice, peer: bob.publicKey), b = TestMac(bob, peer: alice.publicKey)
            a.relay.start(); b.relay.start(); try exchange(a, b)
            a.controller.invitePTT { _ in }
            try exchange(a, b)
            let invitation = b.peerStore.ptt.incoming!
            b.controller.rejectPTTInvite(expected: invitation)
            b.relay.packets.removeAll()
            a.relay.start(); try exchange(a, b)
            try check(!a.controller.outgoingPTTInvite && !b.controller.incomingPTTInvite, "lost rejection revived a declined invitation")
            try check(PeerStore(defaults: b.defaults).ptt.revoked == invitation, "declined invitation was forgotten at restart")
        }
        test("an unsolicited PTT invitation does not require or request microphone access") {
            var recipientRequests = 0
            let a = TestMac(alice, peer: bob.publicKey)
            let b = TestMac(bob, peer: alice.publicKey, requestMicrophone: {
                recipientRequests += 1
                $0(false)
            })
            a.relay.start(); b.relay.start(); try exchange(a, b)
            a.controller.invitePTT { _ in }
            try exchange(a, b)
            try check(b.controller.incomingPTTInvite, "recipient did not receive the invitation")
            try check(recipientRequests == 0 && !b.controller.requiresMicrophonePermission,
                      "remote invitation requested local microphone permission without acceptance")
            try check(a.controller.requiresMicrophonePermission,
                      "locally requested outgoing PTT omitted its microphone requirement")
        }
        test("denied local PTT requests remain visible until returning to lights only") {
            for accepting in [false, true] {
                var requests = 0
                let mac = TestMac(alice, peer: bob.publicKey, requestMicrophone: {
                    requests += 1
                    $0(false)
                })
                var result: Bool?
                if accepting {
                    mac.peerStore.ptt.incoming = 41
                    mac.controller.acceptPTTInvite(expected: 41) { result = $0 }
                } else {
                    mac.controller.invitePTT { result = $0 }
                }
                try check(requests == 1 && result == false && mac.controller.requiresMicrophonePermission,
                          "denied local PTT action lost its required-permission indicator")
                try check(!mac.controller.pttEnabled && !mac.controller.outgoingPTTInvite && !mac.capture.running,
                          "denied access enabled PTT or the microphone")
                mac.controller.disablePTT()
                try check(!mac.controller.requiresMicrophonePermission && mac.controller.lastError == nil,
                          "returning to lights only retained the microphone warning")
            }
        }
        test("returning to lights only cancels a pending microphone approval") {
            var grant: ((Bool) -> Void)?
            let mac = TestMac(alice, peer: bob.publicKey, requestMicrophone: { grant = $0 })
            mac.controller.invitePTT { _ in }
            try check(mac.controller.requiresMicrophonePermission, "pending local PTT omitted its requirement")
            mac.controller.disablePTT()
            grant?(true)
            try check(!mac.controller.requiresMicrophonePermission && !mac.controller.outgoingPTTInvite
                      && !mac.controller.pttEnabled && !mac.capture.running,
                      "late approval revived PTT after choosing lights only")
        }
        test("saved active PTT requires microphone permission while lights only does not") {
            let mac = TestMac(alice, peer: bob.publicKey)
            try check(!mac.controller.requiresMicrophonePermission, "lights only required microphone access")
            mac.peerStore.ptt = PTTConsent(active: 41)
            try check(mac.controller.requiresMicrophonePermission, "saved active PTT omitted microphone access")
            let ready = mac.controller.permissionState(grants:
                KeyboardPermissionState(accessibility: true, inputMonitoring: true, microphone: true))
            try check(ready.isReady && ready.microphoneRequired,
                      "observing a microphone grant removed an active PTT requirement")
            mac.controller.disablePTT()
            try check(!mac.controller.requiresMicrophonePermission, "disabled agreement still required microphone access")
        }
        test("ordinary permission refresh recovers a denied microphone without reopening the guide") {
            let mac = TestMac(alice, peer: bob.publicKey, requestMicrophone: { $0(false) })
            mac.controller.invitePTT { _ in }
            var grants = KeyboardPermissionState(accessibility: true, inputMonitoring: true)
            let blocked = mac.controller.permissionState(grants: grants)
            try check(!blocked.isReady && blocked.microphoneRequired && mac.controller.lastError != nil,
                      "denied access did not expose its requirement")
            drainMainQueue()
            var notifications = 0
            mac.controller.onStateChange = { [weak controller = mac.controller] in
                notifications += 1
                _ = controller?.permissionState(grants: grants)
            }
            grants.microphone = true
            let recovered = mac.controller.permissionState(grants: grants)
            try check(recovered.isReady && !recovered.microphoneRequired && mac.controller.lastError == nil,
                      "ordinary status refresh hid the permission item but retained a stale microphone error")
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            PermissionMenu.update(item, state: recovered)
            try check(item.isHidden && !mac.controller.pttEnabled && !mac.controller.outgoingPTTInvite,
                      "grant recovery retained the warning or silently enabled PTT")
            drainMainQueue()
            drainMainQueue()
            try check(notifications == 1, "permission recovery recursively emitted status changes")
            grants.microphone = false
            let lightsOnly = mac.controller.permissionState(grants: grants)
            try check(lightsOnly.isReady && !lightsOnly.microphoneRequired,
                      "a recovered failed PTT attempt made lights only depend on microphone access")
        }
        test("two controllers pair only after approval and relay held keys") {
            let a = TestMac(alice), b = TestMac(bob)
            a.relay.start(); b.relay.start()
            try b.controller.pair(using: alice.pairingCode)
            try exchange(a, b)
            try check(a.controller.incomingPairPublicKey == bob.publicKey && a.controller.peerPublicKey == nil, "pairing skipped approval")
            a.controller.acceptIncomingPair(expected: alice.publicKey)
            try check(a.controller.peerPublicKey == nil, "stale pair action paired a different identity")
            a.controller.acceptIncomingPair(expected: bob.publicKey)
            try exchange(a, b)
            try check(a.controller.peerPublicKey == bob.publicKey && b.controller.peerPublicKey == alice.publicKey, "pairing did not persist on both Macs")
            b.key(true); try exchange(a, b)
            try check(a.controller.remoteKeyDown && a.controller.led.isOn && !b.controller.led.isOn, "held key lit the wrong keyboard")
            b.key(false); try exchange(a, b)
            try check(!a.controller.remoteKeyDown && !a.controller.led.isOn, "release did not clear the light")
            try check(b.controller.diagnostics().contains("Local Caps presses: 1"), "local capture counter missing")
            try check(b.controller.diagnostics().contains("Key messages queued: 2"), "queued key counter missing")
            try check(a.controller.diagnostics().contains("Key messages received: 2"), "received key counter missing")
            try check(a.controller.diagnostics().contains("Last peer key state: up"), "last received key state missing")
        }
        test("a paired peer stays unavailable until connected and confirmed, and recovers after transport loss") {
            let a = TestMac(alice, peer: bob.publicKey), b = TestMac(bob, peer: alice.publicKey)
            try check(a.controller.peerUnavailable, "offline saved pairing appeared available at launch")
            a.relay.start(); b.relay.start()
            try check(a.controller.peerUnavailable, "relay connection alone made the peer available")
            try exchange(a, b)
            try check(!a.controller.peerUnavailable, "confirmed active peer remained unavailable")
            for state: MQTTClient.State in [.stopped, .connecting, .error("Disconnected")] {
                a.relay.onStateChange?(state)
                a.key(true)
                try check(FireflyIcon.tailState(localActive: a.controller.localKeyDown, attention: false,
                                               peerUnavailable: a.controller.peerUnavailable) == .unavailable,
                          "transport loss did not keep the tail blue during a press: \(state)")
                a.key(false)
                a.relay.start()
                try check(a.controller.peerUnavailable, "reconnect used stale presence")
                try exchange(a, b)
                try check(!a.controller.peerUnavailable, "peer did not recover after reconnect: \(state)")
            }
        }
        test("a silent paired peer turns blue after presence expiry and clears on recovery or unpair") {
            let a = TestMac(alice, peer: bob.publicKey), b = TestMac(bob, peer: alice.publicKey)
            a.relay.start(); b.relay.start(); try exchange(a, b)
            a.clock.time += SlockConfig.onlineTimeout
            a.controller.advanceMaintenance()
            try check(!a.controller.peerUnavailable, "peer expired before its presence deadline")
            a.clock.time += 1
            a.controller.advanceMaintenance()
            try check(a.controller.transportState == .connected && !a.controller.peerPaused,
                      "test lost the relay or paused the peer")
            try check(FireflyIcon.tailState(localActive: false, attention: false,
                                           peerUnavailable: a.controller.peerUnavailable) == .unavailable,
                      "silent peer did not turn the tail blue")
            try exchange(a, b)
            try check(!a.controller.peerUnavailable, "fresh peer messages did not clear blue")
            a.relay.stop()
            try check(a.controller.peerUnavailable, "disconnected peer appeared available")
            a.controller.unpair()
            try check(!a.controller.peerUnavailable, "unpaired Mac kept the blue tail")
            a.relay.start()
            try a.controller.pair(using: bob.pairingCode)
            try check(a.controller.peerPublicKey == nil && !a.controller.peerUnavailable,
                      "pending pairing showed a blue tail before acceptance")
        }
        test("pause and resume immediately update the paired peer's tail and status") {
            let a = TestMac(alice, peer: bob.publicKey), b = TestMac(bob, peer: alice.publicKey)
            a.relay.start(); b.relay.start(); try exchange(a, b)
            try check(!a.controller.peerPaused && !b.controller.peerPaused, "active peer reported paused")
            b.controller.setCaptureEnabled(false); try exchange(a, b)
            try check(a.controller.peerOnline && a.controller.peerPaused, "pause was not shared immediately")
            try check(!b.controller.peerPaused, "local pause was mistaken for peer pause")
            try check(a.controller.statusText == "Paired • Paused", "pause explanation missing")
            a.key(true); try exchange(a, b)
            try check(!b.controller.remoteKeyDown, "paused peer received a light signal")
            try check(FireflyIcon.tailState(localActive: a.controller.localKeyDown, attention: false,
                                           peerUnavailable: a.controller.peerUnavailable) == .unavailable,
                      "press hid the paused peer")
            a.key(false)
            b.controller.setCaptureEnabled(true); try exchange(a, b)
            try check(!a.controller.peerPaused, "resume was not shared immediately")
            try check(!a.controller.peerUnavailable, "resume kept the blue tail")
            a.key(true); try exchange(a, b)
            try check(b.controller.remoteKeyDown, "resumed peer stopped receiving")
        }
        test("an already paused peer is reported after reconnecting or accepting a new pairing") {
            for alreadyPaired in [false, true] {
                let a = TestMac(alice, peer: alreadyPaired ? bob.publicKey : nil)
                let b = TestMac(bob, peer: alreadyPaired ? alice.publicKey : nil)
                b.controller.setCaptureEnabled(false)
                a.relay.start(); b.relay.start()
                if !alreadyPaired {
                    try a.controller.pair(using: bob.pairingCode)
                    try exchange(a, b)
                    try check(!a.controller.peerPaused, "unaccepted pairing changed pause status")
                    b.controller.acceptIncomingPair(expected: alice.publicKey)
                }
                try exchange(a, b)
                try check(a.controller.peerPaused && !b.controller.peerPaused, "initial pause status missing")
            }
        }
        test("a peer pause cancels pending and held lights even when its release packet is lost") {
            for alreadyLit in [false, true] {
                let a = TestMac(alice, peer: bob.publicKey), b = TestMac(bob, peer: alice.publicKey)
                a.relay.start(); b.relay.start(); try exchange(a, b)
                b.key(true, timestamp: 1_000_000_000); try exchange(a, b)
                if alreadyLit {
                    a.advance(to: 101)
                    try check(a.controller.led.isOn, "initial held light missing")
                }
                b.controller.setCaptureEnabled(false)
                try check(b.relay.packets.count == 2, "pause did not send release followed by capture state")
                b.relay.packets.removeFirst()
                try exchange(a, b)
                try check(a.controller.peerPaused && !a.controller.remoteKeyDown && !a.controller.led.isOn,
                          "peer pause left a held light on")
                a.advance(to: 102)
                try check(!a.controller.led.isOn && a.controller.diagnostics().contains("Pending light transitions: 0"),
                          "peer pause replayed a buffered pulse")
            }
        }
        test("HELLO refreshes recover lost pause and resume updates") {
            let a = TestMac(alice, peer: bob.publicKey), b = TestMac(bob, peer: alice.publicKey)
            a.relay.start(); b.relay.start(); try exchange(a, b)
            for enabled in [false, true] {
                b.controller.setCaptureEnabled(enabled)
                b.relay.packets.removeAll()
                try check(a.controller.peerPaused == enabled, "status changed before receiving the update")
                a.clock.time += SlockConfig.helloInterval
                a.controller.advanceMaintenance(); try exchange(a, b)
                try check(a.controller.peerPaused == !enabled, "HELLO did not repair the lost update")
            }
        }
        test("peer pause is cleared on disconnect, expiry, unpair and a fresh legacy session") {
            for action in 0..<4 {
                let a = TestMac(alice, peer: bob.publicKey), b = TestMac(bob, peer: alice.publicKey)
                a.relay.start(); b.relay.start(); try exchange(a, b)
                b.controller.setCaptureEnabled(false); try exchange(a, b)
                try check(a.controller.peerPaused, "missing initial pause")
                switch action {
                case 0:
                    a.relay.stop()
                    try check(!a.controller.peerPaused, "disconnect kept stale pause")
                    a.relay.start(); try exchange(a, b)
                    try check(a.controller.peerPaused, "reconnect did not refresh pause")
                    a.relay.stop()
                case 1:
                    a.clock.time += SlockConfig.onlineTimeout + 1
                    a.controller.advanceMaintenance()
                case 2:
                    a.controller.unpair()
                default:
                    let legacy = SecureWire(identity: bob)
                    a.clock.time += 2
                    a.relay.onMessage?("", try legacy.seal(kind: .hello, payload: Data(), to: alice.publicKey))
                    let messages = try exchange(a, legacy)
                    try check(messages.contains { $0.kind == .hello && $0.sessionConfirmed && $0.payload.count == 9 },
                              "legacy HELLO snapshot format changed")
                }
                try check(!a.controller.peerPaused, "stale pause survived action \(action)")
            }
        }
        test("failed capture stop does not tell the peer it is paused") {
            let a = TestMac(alice, peer: bob.publicKey), b = TestMac(bob, peer: alice.publicKey)
            a.relay.start(); b.relay.start(); try exchange(a, b)
            b.hid.failWrites = true
            b.controller.setCaptureEnabled(false); try exchange(a, b)
            try check(b.controller.capsInterceptor.isActive && !a.controller.peerPaused,
                      "failed pause was advertised as successful")
            b.hid.failWrites = false
        }
        test("only valid fresh status from the paired peer can change its pause indicator") {
            let a = TestMac(alice, peer: bob.publicKey), b = SecureWire(identity: bob)
            a.relay.start(); _ = try exchange(a, b)
            let paused = try b.seal(kind: .captureState, payload: Data([0]), to: alice.publicKey)
            a.relay.onMessage?("", paused)
            try check(a.controller.peerPaused, "authenticated pause missing")
            for payload in [Data(), Data([2]), Data([0, 1])] {
                a.relay.onMessage?("", try b.seal(kind: .captureState, payload: payload, to: alice.publicKey))
                try check(a.controller.peerPaused, "malformed state changed pause")
            }
            a.relay.onMessage?("", try b.seal(kind: .captureState, payload: Data([1]), to: alice.publicKey))
            a.relay.onMessage?("", paused)
            try check(!a.controller.peerPaused, "replayed pause replaced resume")
            a.relay.packets.removeAll()
            let stranger = SecureWire(identity: try IdentityStore(directory: root.appendingPathComponent("stranger")))
            a.relay.onMessage?("", try stranger.seal(kind: .hello, payload: Data(), to: alice.publicKey))
            try check(a.relay.packets.isEmpty, "paired Mac answered a stranger's handshake")
            try check(!stranger.hasSession(with: alice.publicKey), "stranger established a session")
            try check(!a.controller.peerPaused, "unpaired sender changed pause status")
        }
        test("timestamped controllers preserve short ON and OFF lengths despite delivery jitter") {
            let a = TestMac(alice, peer: bob.publicKey), b = TestMac(bob, peer: alice.publicKey)
            a.relay.start(); b.relay.start(); try exchange(a, b)
            b.key(true, timestamp: 10_000_000_000); try exchange(a, b)
            try check(!a.controller.led.isOn, "press skipped the rhythm buffer")
            a.clock.time = 100.7
            b.key(false, timestamp: 10_100_000_000); try exchange(a, b)
            a.clock.time = 100.71
            b.key(true, timestamp: 10_300_000_000); try exchange(a, b)
            b.key(false, timestamp: 10_350_000_000); try exchange(a, b)
            a.advance(to: 101)
            try check(a.controller.led.isOn && !b.controller.led.isOn, "wrong keyboard or missing first flash")
            a.advance(to: 101.099)
            try check(a.controller.led.isOn, "100 ms flash ended early")
            a.advance(to: 101.1)
            try check(!a.controller.led.isOn, "100 ms flash followed the 700 ms packet gap")
            a.advance(to: 101.299)
            try check(!a.controller.led.isOn, "200 ms OFF gap was compressed")
            a.advance(to: 101.3)
            try check(a.controller.led.isOn, "second flash missed its deadline")
            a.advance(to: 101.35)
            try check(!a.controller.led.isOn, "50 ms flash did not end")
            try check(b.controller.diagnostics().contains("Key messages queued: 4"), "timing added network messages")
            try check(a.controller.diagnostics().contains("Pending light transitions: 0"), "playback queue did not drain")
        }
        test("held-key refreshes and HELLOs do not jump buffered edges") {
            let a = TestMac(alice, peer: bob.publicKey), b = TestMac(bob, peer: alice.publicKey)
            a.relay.start(); b.relay.start(); try exchange(a, b)
            b.key(true, timestamp: 1_000_000_000); try exchange(a, b)
            b.controller.advanceMaintenance(); try exchange(a, b)
            try check(!a.controller.led.isOn, "held refresh bypassed the buffer")
            a.advance(to: 101)
            try check(a.controller.led.isOn, "refresh erased the pending press")
            // Long holds remain lit through the original one-byte refresh cadence.
            a.clock.time = 102
            b.controller.advanceMaintenance(); try exchange(a, b)
            a.clock.time = 103
            a.controller.advanceMaintenance()
            try check(a.controller.led.isOn, "fresh long hold expired")
            b.key(false, timestamp: 5_000_000_000); try exchange(a, b)
            b.relay.start(); try exchange(a, b)
            try check(a.controller.led.isOn, "HELLO jumped the buffered release")
            a.advance(to: 104)
            try check(!a.controller.led.isOn, "long hold did not release")
        }
        test("disconnect, pause, unpair, shutdown and expiry cancel pending light playback") {
            for action in 0..<5 {
                let a = TestMac(alice, peer: bob.publicKey), b = TestMac(bob, peer: alice.publicKey)
                a.relay.start(); b.relay.start(); try exchange(a, b)
                b.key(true, timestamp: 1_000_000_000); try exchange(a, b)
                switch action {
                case 0: a.relay.onStateChange?(.error("offline"))
                case 1: a.controller.setCaptureEnabled(false)
                case 2: a.controller.unpair()
                case 3: a.controller.shutdown()
                default: a.clock.time = 103; a.controller.advanceMaintenance()
                }
                a.advance(to: 104)
                try check(!a.controller.remoteKeyDown && !a.controller.led.isOn, "cancelled press replayed: \(action)")
                try check(a.controller.diagnostics().contains("Pending light transitions: 0"), "cancelled queue survived: \(action)")
            }
        }
        test("legacy releases still cancel a buffered press immediately") {
            let a = TestMac(alice, peer: bob.publicKey), b = TestMac(bob, peer: alice.publicKey)
            a.relay.start(); b.relay.start(); try exchange(a, b)
            b.key(true, timestamp: 1_000_000_000); try exchange(a, b)
            b.key(false); try exchange(a, b)
            a.advance(to: 101)
            try check(!a.controller.led.isOn && !a.controller.remoteKeyDown, "emergency release left a queued press")
        }
        test("light freshness is measured at receipt, not delayed playback") {
            let a = TestMac(alice, peer: bob.publicKey), b = TestMac(bob, peer: alice.publicKey)
            a.relay.start(); b.relay.start(); try exchange(a, b)
            b.key(true, timestamp: 1_000_000_000); try exchange(a, b)
            a.advance(to: 101)
            try check(a.controller.led.isOn, "buffered press did not play")
            a.clock.time = 102.6
            a.controller.advanceMaintenance()
            try check(!a.controller.led.isOn, "playback extended the stale-key lease")
        }
        test("a fresh peer session cannot replay the old session's buffered light") {
            let a = TestMac(alice, peer: bob.publicKey), b = TestMac(bob, peer: alice.publicKey)
            a.relay.start(); b.relay.start(); try exchange(a, b)
            b.key(true, timestamp: 1_000_000_000); try exchange(a, b)
            let restarted = TestMac(bob, peer: alice.publicKey)
            // The handshake response throttle permits the new boot after a second.
            a.clock.time = 101.01
            restarted.relay.start(); try exchange(a, restarted)
            a.advance(to: 101.01)
            try check(!a.controller.led.isOn, "old session's press survived the fresh handshake")
            try check(a.controller.diagnostics().contains("Pending light transitions: 0"), "old session kept its queue")
        }
        test("the real playback timer delivers buffered edges without a maintenance tick") {
            let a = TestMac(alice, peer: bob.publicKey), b = TestMac(bob, peer: alice.publicKey)
            a.clock.usesSystemTime = true; b.clock.usesSystemTime = true
            a.relay.start(); b.relay.start(); try exchange(a, b)
            a.clock.lightWrites.removeAll()
            let started = a.clock.time
            b.key(true, timestamp: 1_000_000_000)
            b.key(false, timestamp: 1_060_000_000)
            try exchange(a, b)
            let limit = Date().addingTimeInterval(3)
            while a.clock.lightWrites.count < 2, Date() < limit { drainMainQueue() }
            try check(a.clock.lightWrites.map(\.down) == [true, false], "timer failed to emit the pulse")
            let writes = a.clock.lightWrites
            try check(writes[0].time - started >= 0.999, "timer skipped the playback buffer")
            try check(writes[1].time - writes[0].time >= 0.059, "timer compressed the 60 ms pulse")
        }
        test("simultaneous PTT holds choose one speaker and transfer only after playback drains") {
            let a = TestMac(alice, peer: bob.publicKey), b = TestMac(bob, peer: alice.publicKey)
            a.relay.start(); b.relay.start(); try exchange(a, b)
            a.peerStore.ptt.active = 42; b.peerStore.ptt.active = 42
            a.key(true); b.key(true); try exchange(a, b); drainMainQueue(); try exchange(a, b)
            let winner = dataLexicographicallyPrecedes(alice.publicKey, bob.publicKey) ? a : b
            let loser = winner === a ? b : a
            try check(winner.controller.localTalking && loser.controller.remoteTalking && !loser.capture.running, "collision left both microphones running")
            winner.key(false); drainMainQueue(); try exchange(a, b)
            try check(!loser.capture.running && loser.playback.onDrain != nil, "floor transferred before playback drained")
            loser.playback.finish(); try exchange(a, b)
            try check(loser.controller.localTalking && winner.controller.remoteTalking, "held key did not acquire the released floor")
            loser.relay.onStateChange?(.error("disconnected"))
            try check(!loser.capture.running && !loser.controller.localTalking, "connection loss left the microphone running")
        }
        test("errors from an earlier talk cannot stop a new transmission") {
            let a = TestMac(alice, peer: bob.publicKey), b = TestMac(bob, peer: alice.publicKey)
            a.relay.start(); b.relay.start(); try exchange(a, b)
            a.peerStore.ptt.active = 42; b.peerStore.ptt.active = 42
            a.key(true)
            let oldError = a.capture.onError
            a.key(false); drainMainQueue(); a.key(true)
            oldError?("old conversion error")
            try check(a.controller.localTalking && a.capture.running, "old error stopped the new hold")
            a.capture.onError?("current conversion error")
            try check(!a.capture.running && a.controller.diagnostics().contains("current conversion error"), "current error was ignored or missing from diagnostics")
        }
        test("pair changes clear consent and persisted revocations reload") {
            let preferences = MemoryPreferences()
            let peer = PeerStore(defaults: preferences)
            peer.peerPublicKey = alice.publicKey
            peer.ptt.incoming = 42
            peer.ptt.accept(42)
            try check(PeerStore(defaults: preferences).ptt.active == 42, "active agreement did not persist")
            peer.ptt.disable()
            try check(PeerStore(defaults: preferences).ptt.revoked == 42, "revocation did not persist")
            peer.peerPublicKey = bob.publicKey
            try check(peer.ptt.active == nil && peer.ptt.revoked == nil, "consent leaked to new peer")
        }
        test("empty hidutil arrays round-trip after capture is disabled") {
            for value in ["(null)", "null", "[]", "()", "(\n)", "(\n    \n)"] {
                try check(try CapsInterceptor.parseMappings(value).isEmpty, "Rejected \(value)")
            }
            let mappings = try CapsInterceptor.parseMappings("({ HIDKeyboardModifierMappingSrc = 0x700000004; HIDKeyboardModifierMappingDst = 30064771077; })")
            try check(mappings.count == 1 && mappings[0].src == 0x700000004, "existing mapping")
            try mustThrow { _ = try CapsInterceptor.parseMappings("{ unknown = 1; }") }
        }
        test("mapping parsing refuses truncated arrays and partial numeric tokens") {
            for text in [
                "({ HIDKeyboardModifierMappingSrc = 4; HIDKeyboardModifierMappingDst = 5; }, { HIDKeyboardModifierMappingSrc = 6;",
                "({ HIDKeyboardModifierMappingSrc = 4invalid; HIDKeyboardModifierMappingDst = 5; })",
                "({ HIDKeyboardModifierMappingSrc = 4; HIDKeyboardModifierMappingDst = 5; HIDKeyboardModifierMappingSrc = 6; })"
            ] {
                try mustThrow { _ = try CapsInterceptor.parseMappings(text) }
            }
        }
        test("capture cannot remap Caps Lock until both keyboard permissions are granted") {
            for (trusted, listening) in [(false, false), (true, false), (false, true)] {
                let prefs = MemoryPreferences(), hid = FakeHID()
                let capture = CapsInterceptor(testDefaults: prefs, process: hid.run,
                                              trustCheck: { trusted }, listenCheck: { listening })
                defer { capture.stop() }
                capture.requestPermissionAndStart()
                try check(capture.isRequested && !capture.isActive, "missing permission claimed active capture")
                capture.start()
                try check(!capture.isActive && hid.writes.isEmpty, "direct start bypassed a missing permission")
                try check(prefs.string(forKey: "CapsLink.staleOriginalMapping") == nil,
                          "missing permission claimed keyboard recovery ownership")
            }
        }
        test("capture automatically resumes after both keyboard grants arrive") {
            let prefs = MemoryPreferences(), hid = FakeHID()
            var trusted = false, listening = false
            let capture = CapsInterceptor(testDefaults: prefs, process: hid.run,
                                          trustCheck: { trusted }, listenCheck: { listening })
            defer { capture.stop() }
            capture.requestPermissionAndStart()
            trusted = true
            capture.requestPermissionAndStart()
            try check(!capture.isActive && hid.writes.isEmpty, "Accessibility alone started capture")
            listening = true
            let deadline = Date().addingTimeInterval(2.5)
            while !capture.isActive && Date() < deadline { drainMainQueue() }
            try check(capture.isActive && capture.lastError == nil, "permission polling did not resume capture")
            try check(hid.writes.count == 1, "permission recovery remapped Caps Lock more than once")
        }
        test("paused capture stays paused when keyboard permissions arrive") {
            let prefs = MemoryPreferences(), hid = FakeHID()
            var grants = KeyboardPermissionState(accessibility: false, inputMonitoring: false)
            var prompts: [KeyboardPermission] = []
            let setup = KeyboardPermissionSetup(defaults: prefs, check: { grants }, prompt: { prompts.append($0) })
            let capture = CapsInterceptor(testDefaults: prefs, process: hid.run,
                                          trustCheck: { grants.accessibility }, listenCheck: { grants.inputMonitoring })
            defer { capture.stop() }
            capture.requestPermissionAndStart()
            capture.stop()
            try check(!setup.shouldShowOnLaunch(captureRequested: capture.isRequested), "paused launch opened setup")
            grants = KeyboardPermissionState(accessibility: true, inputMonitoring: true)
            RunLoop.main.run(until: Date().addingTimeInterval(1.7))
            try check(!capture.isRequested && !capture.isActive && hid.writes.isEmpty,
                      "a pending permission timer resumed paused capture")
            try check(prompts.isEmpty, "paused setup requested permission")
        }
        test("permission setup requests each missing permission once in order across relaunches") {
            let prefs = MemoryPreferences()
            var grants = KeyboardPermissionState(accessibility: false, inputMonitoring: false)
            var prompts: [KeyboardPermission] = []
            let setup = KeyboardPermissionSetup(defaults: prefs, check: { grants }, prompt: { prompts.append($0) })
            setup.requestNextAutomatically()
            setup.requestNextAutomatically()
            try check(prompts == [.accessibility], "requested monitoring before Accessibility was granted")
            let relaunched = KeyboardPermissionSetup(defaults: prefs, check: { grants }, prompt: { prompts.append($0) })
            relaunched.requestNextAutomatically()
            try check(prompts == [.accessibility], "relaunch duplicated an unresolved Accessibility request")
            grants.accessibility = true
            relaunched.requestNextAutomatically()
            relaunched.requestNextAutomatically()
            try check(prompts == [.accessibility, .inputMonitoring], "did not request Input Monitoring exactly once")
            let relaunchedAgain = KeyboardPermissionSetup(defaults: prefs, check: { grants }, prompt: { prompts.append($0) })
            relaunchedAgain.requestNextAutomatically()
            try check(prompts.count == 2, "relaunch duplicated an unresolved Input Monitoring request")
        }
        test("requesting a keyboard permission never assumes it was granted") {
            let prefs = MemoryPreferences()
            var grants = KeyboardPermissionState(accessibility: false, inputMonitoring: false)
            let setup = KeyboardPermissionSetup(defaults: prefs, check: { grants }, prompt: { _ in })
            setup.request(.accessibility)
            try check(!setup.state.isReady && setup.state.firstMissing == .accessibility,
                      "requesting Accessibility marked it as granted")
            grants.accessibility = true
            setup.request(.inputMonitoring)
            try check(!setup.state.isReady && setup.state.firstMissing == .inputMonitoring,
                      "requesting Input Monitoring marked it as granted")
            try check(setup.shouldShowOnLaunch(captureRequested: true), "pending grants hid setup")
        }
        test("retained request flags and legacy preferences cannot hide missing keyboard grants") {
            for legacyKey in ["CapsLink.captureEnabled", "CapsLink.didConfigureLaunchAtLogin"] {
                let prefs = MemoryPreferences()
                prefs.set(true, forKey: legacyKey)
                for permission in KeyboardPermission.allCases { prefs.set(true, forKey: permission.requestKey) }
                for grants in [KeyboardPermissionState(accessibility: false, inputMonitoring: false),
                               KeyboardPermissionState(accessibility: true, inputMonitoring: false),
                               KeyboardPermissionState(accessibility: false, inputMonitoring: true)] {
                    var prompts: [KeyboardPermission] = []
                    let setup = KeyboardPermissionSetup(defaults: prefs, check: { grants }, prompt: { prompts.append($0) })
                    try check(setup.shouldShowOnLaunch(captureRequested: true), "retained \(legacyKey) hid setup")
                    setup.requestNextAutomatically()
                    try check(prompts.isEmpty, "retained request flags repeated a native prompt automatically")
                }
            }
        }
        test("explicit permission retries work after a previous request") {
            let prefs = MemoryPreferences()
            var prompts: [KeyboardPermission] = []
            let setup = KeyboardPermissionSetup(defaults: prefs,
                check: { KeyboardPermissionState(accessibility: false, inputMonitoring: false) },
                prompt: { prompts.append($0) })
            for permission in KeyboardPermission.allCases {
                try check(!setup.request(permission), "first request was reported as a retry")
                try check(setup.request(permission), "prior request did not expose the Settings fallback")
            }
            try check(prompts == [.accessibility, .accessibility, .inputMonitoring, .inputMonitoring,
                                  .microphone, .microphone],
                      "saved request flags suppressed explicit retry")
        }
        test("permission requirements follow lights only and PTT mode changes") {
            var grants = KeyboardPermissionState(accessibility: true, inputMonitoring: true)
            var prompts: [KeyboardPermission] = []
            let setup = KeyboardPermissionSetup(defaults: MemoryPreferences(), check: { grants },
                                                prompt: { prompts.append($0) })
            try check(setup.state.isReady && setup.state.firstMissing == nil,
                      "lights only was blocked by an unapproved microphone")
            setup.requestNextAutomatically()
            try check(prompts.isEmpty, "lights only prompted for the microphone")
            setup.microphoneRequired = true
            try check(!setup.state.isReady && setup.state.firstMissing == .microphone,
                      "PTT did not identify the missing microphone grant")
            setup.requestNextAutomatically()
            setup.requestNextAutomatically()
            try check(prompts == [.microphone] && !setup.state.isReady,
                      "microphone request repeated automatically or implied approval")
            grants.microphone = true
            try check(setup.state.isReady && setup.state.firstMissing == nil,
                      "granted microphone did not finish PTT permissions")
            grants.microphone = false
            try check(!setup.state.isReady, "microphone revocation did not invalidate PTT permissions")
            setup.microphoneRequired = false
            try check(setup.state.isReady, "switching back to lights only retained the microphone requirement")
        }
        test("overlapping permission requests neither duplicate nor stack native prompts") {
            var grants = KeyboardPermissionState(accessibility: false, inputMonitoring: false)
            var prompts: [KeyboardPermission] = []
            var finish: (() -> Void)?
            var callbacks: [String] = []
            let setup = KeyboardPermissionSetup(defaults: MemoryPreferences(), check: { grants },
                request: { permission, completion in prompts.append(permission); finish = completion })
            setup.request(.accessibility) { callbacks.append("first") }
            setup.request(.accessibility) { callbacks.append("duplicate") }
            setup.request(.inputMonitoring) { callbacks.append("overlap") }
            grants.accessibility = true
            setup.requestNextAutomatically()
            try check(prompts == [.accessibility] && setup.requestingPermission == .accessibility,
                      "overlapping attempts opened more than one native prompt")
            try check(callbacks.isEmpty && !setup.hasRequested(.inputMonitoring),
                      "an overlapping request claimed to finish or consumed its future request")
            finish?()
            try check(callbacks == ["first", "duplicate"] && setup.requestingPermission == nil,
                      "shared request did not finish its callers exactly once")
            setup.requestNextAutomatically()
            try check(prompts == [.accessibility, .inputMonitoring]
                      && setup.requestingPermission == .inputMonitoring,
                      "next permission did not start after the previous request finished")
            finish?()
        }
        test("asynchronous request completion does not imply a permission grant") {
            let grants = KeyboardPermissionState(accessibility: true, inputMonitoring: false)
            var finish: (() -> Void)?
            var completed = false
            let setup = KeyboardPermissionSetup(defaults: MemoryPreferences(), check: { grants },
                request: { _, completion in finish = completion })
            setup.request(.inputMonitoring) { completed = true }
            try check(setup.requestingPermission == .inputMonitoring && !setup.state.isReady,
                      "pending request claimed permission was ready")
            finish?()
            try check(completed && setup.requestingPermission == nil && !setup.state.isReady
                      && setup.state.firstMissing == .inputMonitoring,
                      "completed native request was treated as an approval")
        }
        test("Permissions Required menu item is red and follows grants and mode changes") {
            let item = NSMenuItem(title: "Permissions…", action: nil, keyEquivalent: "")
            var state = KeyboardPermissionState(accessibility: false, inputMonitoring: true)
            PermissionMenu.update(item, state: state)
            try check(item.title == "Permissions Required" && !item.isHidden,
                      "missing keyboard permission did not expose the single required item")
            let color = item.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            try check(color == .systemRed, "required menu item was not red")
            state.accessibility = true
            PermissionMenu.update(item, state: state)
            try check(item.isHidden, "ready lights-only mode retained the permission item")
            state.microphoneRequired = true
            PermissionMenu.update(item, state: state)
            try check(!item.isHidden, "PTT mode hid a missing microphone grant")
            state.microphone = true
            PermissionMenu.update(item, state: state)
            try check(item.isHidden, "fully approved PTT retained the permission item")
            state.microphone = false
            PermissionMenu.update(item, state: state)
            try check(!item.isHidden, "revoked microphone did not restore the permission item")
            state.microphoneRequired = false
            PermissionMenu.update(item, state: state)
            try check(item.isHidden, "leaving PTT did not hide an irrelevant microphone requirement")
        }
        test("already granted keyboard permissions keep launch and automatic requests quiet") {
            let prefs = MemoryPreferences()
            var prompts: [KeyboardPermission] = []
            let setup = KeyboardPermissionSetup(defaults: prefs,
                check: { KeyboardPermissionState(accessibility: true, inputMonitoring: true) },
                prompt: { prompts.append($0) })
            try check(setup.state.isReady && setup.state.firstMissing == nil, "ready state still listed a missing permission")
            try check(!setup.shouldShowOnLaunch(captureRequested: true), "ready launch opened setup")
            setup.requestNextAutomatically()
            setup.requestNextAutomatically()
            try check(prompts.isEmpty, "ready setup opened a native permission prompt")
        }
        test("capture rejects a successful hidutil command that did not install the mapping") {
            let prefs = MemoryPreferences(), hid = FakeHID()
            hid.ignoreWrites = true
            let capture = CapsInterceptor(testDefaults: prefs, process: hid.run)
            capture.start()
            try check(!capture.isActive && capture.lastError != nil, "claimed capture without a mapping")
            try check(prefs.string(forKey: "CapsLink.staleOriginalMapping") == nil, "empty original mapping was not recovered")
        }
        test("a modifier-only event tap cannot claim capture or remap the keyboard") {
            let prefs = MemoryPreferences(), hid = FakeHID()
            let capture = CapsInterceptor(testDefaults: prefs, process: hid.run,
                verifyTap: { try KeyboardTapAccess.validate(mask: 1 << CGEventType.flagsChanged.rawValue) })
            capture.requestPermissionAndStart()
            try check(!capture.isActive && capture.lastError != nil, "partial tap claimed capture")
            try check(hid.writes.isEmpty, "partial tap changed keyboard mapping")
            try check(prefs.string(forKey: "CapsLink.staleOriginalMapping") == nil, "partial tap claimed recovery ownership")
            try KeyboardTapAccess.validate(mask: KeyboardTapAccess.requiredMask)
            capture.stop()
        }
        test("capture clears a preexisting Caps Lock latch and restores it only after stopping") {
            let prefs = MemoryPreferences(), hid = FakeHID()
            var writes: [Bool] = []
            let capture = CapsInterceptor(testDefaults: prefs, process: hid.run,
                                          readLock: { true }, writeLock: { writes.append($0); return true })
            capture.start()
            try check(capture.isActive && writes == [false], "capture kept Caps Lock enabled")
            capture.stop()
            try check(!capture.isActive && writes == [false, true], "prior lock state was not restored")
            capture.stop()
            try check(writes == [false, true], "second stop changed normal Caps Lock")
        }
        test("a silently ignored restoration keeps capture and its recovery journal") {
            let prefs = MemoryPreferences(), hid = FakeHID()
            let capture = CapsInterceptor(testDefaults: prefs, process: hid.run)
            capture.start()
            hid.ignoreWrites = true
            capture.stop()
            try check(capture.isActive, "capture released before mapping restoration")
            try check(prefs.string(forKey: "CapsLink.staleOriginalMapping") != nil, "lost recovery journal")
            hid.ignoreWrites = false
            capture.stop()
            try check(!capture.isActive, "capture did not recover")
        }
        test("capture rolls its mapping back when the system lock cannot be cleared") {
            let prefs = MemoryPreferences(), hid = FakeHID()
            let capture = CapsInterceptor(testDefaults: prefs, process: hid.run, writeLock: { _ in false })
            capture.start()
            try check(!capture.isActive && capture.lastError != nil, "capture ignored lock reset failure")
            try check(try CapsInterceptor.parseMappings(hid.output).isEmpty, "capture left its mapping behind")
        }
        test("native Caps Lock events are consumed and other modifiers survive filtering") {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 57, keyDown: true)!
            event.flags = [.maskAlphaShift, .maskShift, .maskCommand]
            var resets = 0
            try check(!suppressCapsLock(in: event, clearLock: { resets += 1 }), "native Caps Lock leaked")
            try check(resets == 1 && !event.flags.contains(.maskAlphaShift), "logical lock was not cleared")
            try check(event.flags.contains([.maskShift, .maskCommand]), "other modifiers were removed")
            event.setIntegerValueField(.keyboardEventKeycode, value: 0)
            try check(suppressCapsLock(in: event, clearLock: { resets += 1 }), "ordinary key was swallowed")
            try check(resets == 1, "ordinary key unnecessarily reset the LED")
            event.setIntegerValueField(.keyboardEventKeycode, value: SlockConfig.f18CGKeyCode)
            try check(suppressCapsLock(in: event, type: .keyDown, clearLock: { resets += 1 }), "remapped Caps press was swallowed early")
            try check(resets == 2, "remapped Caps press did not force the local lock off")
        }
        test("LED failure is reported instead of enabling logical Caps Lock") {
            var requests: [Bool] = []
            let led = CapsLED(directWriter: { requests.append($0); return false })
            try check(!led.set(true) && led.mode == .unavailable && !led.isOn, "unsupported LED claimed success")
            try check(!led.set(false) && requests == [true, false], "LED output did not stay independent")
            let working = CapsLED(directWriter: { _ in true })
            try check(working.set(true) && working.isOn && working.mode == .directHID, "direct LED failed")
            try check(working.set(false) && !working.isOn, "direct LED latched on")
        }
        test("LED devices are created only after keyboard access and recreated after revocation") {
            var access = HIDEventAccess.unknown
            var created = 0
            let led = CapsLED(accessCheck: { access }, makeOutput: {
                created += 1
                return FakeLEDOutput(allowed: access == .granted)
            })
            try check(created == 0, "LED initialization opened keyboard devices")
            try check(!led.set(true) && created == 0 && led.mode == .permissionRequired, "opened devices before permission")
            access = .granted
            try check(led.set(true) && created == 1 && led.isOn, "permission grant did not enable LED output")
            try check(led.set(false) && created == 1, "working device was unnecessarily reopened")
            access = .denied
            try check(!led.set(true) && led.mode == .permissionRequired, "permission revocation was ignored")
            access = .granted
            try check(led.set(true) && created == 2 && led.lastError == nil, "regrant reused a denied device")
        }
        test("a cached HID denial is discarded so a later LED retry can recover") {
            var created = 0
            let led = CapsLED(accessCheck: { .granted }, makeOutput: {
                created += 1
                return FakeLEDOutput(allowed: created > 1)
            })
            try check(!led.set(true) && led.lastError == "Cached keyboard permission denial", "failure reason was hidden")
            try check(led.diagnostics.contains("0 successful writes"), "device failure details were hidden")
            try check(led.set(true) && created == 2 && led.isOn && led.lastError == nil,
                      "cached denial survived retry after permission was granted")
        }
        test("Dit's tail gives outgoing activity priority over notifications") {
            try check(FireflyIcon.tailState(localActive: false, attention: false, peerUnavailable: false) == .idle,
                      "idle tail state")
            try check(FireflyIcon.tailState(localActive: false, attention: true, peerUnavailable: false) == .notification,
                      "notification tail state")
            try check(FireflyIcon.tailState(localActive: true, attention: true, peerUnavailable: false) == .outgoing,
                      "outgoing key did not get tail priority")
        }
        test("Dit's red permission tail takes priority over outgoing activity") {
            for localActive in [false, true] {
                for attention in [false, true] {
                    for peerUnavailable in [false, true] {
                        try check(FireflyIcon.tailState(localActive: localActive, attention: attention,
                                                       peerUnavailable: peerUnavailable, permissionsRequired: true) == .notification,
                                  "missing permissions failed to select the red tail")
                    }
                }
            }
            try check(FireflyIcon.tailState(localActive: true, attention: false,
                                           permissionsRequired: false) == .outgoing,
                      "satisfied permissions prevented the outgoing tail")
        }
        test("Dit's blue tail keeps an unavailable peer visible during activity and notifications") {
            for localActive in [false, true] {
                for attention in [false, true] {
                    try check(FireflyIcon.tailState(localActive: localActive, attention: attention, peerUnavailable: true) == .unavailable,
                              "unavailable tail lost priority")
                }
            }
            try check(!FireflyIcon.image(tail: .unavailable).isTemplate, "blue tail was made monochrome")
            try check(FireflyIcon.image(tail: .unavailable).accessibilityDescription?.contains("peer unavailable") == true,
                      "unavailable indication is only conveyed by color")
        }
        test("a second stop never overwrites mappings changed after capture stopped") {
            let prefs = MemoryPreferences(), hid = FakeHID()
            hid.output = "({ HIDKeyboardModifierMappingSrc = 4; HIDKeyboardModifierMappingDst = 5; })"
            let capture = CapsInterceptor(testDefaults: prefs, process: hid.run)
            capture.start()
            try check(capture.isActive, "start failed")
            capture.stop()
            let writesAfterStop = hid.writes.count
            capture.stop()
            try check(hid.writes.count == writesAfterStop, "repeated stop wrote stale mappings")
        }
        test("failed restoration preserves the recovery journal and active tap") {
            let prefs = MemoryPreferences(), hid = FakeHID()
            let capture = CapsInterceptor(testDefaults: prefs, process: hid.run)
            capture.start()
            hid.failWrites = true
            capture.stop()
            try check(prefs.string(forKey: "CapsLink.staleOriginalMapping") != nil, "lost journal")
            try check(capture.isActive, "tap released while Caps remained remapped")
            hid.failWrites = false
            capture.stop()
            try check(!capture.isActive && prefs.string(forKey: "CapsLink.staleOriginalMapping") == nil, "recovery failed")
        }
        test("failed startup recovery cannot overwrite the original journal") {
            let prefs = MemoryPreferences(), hid = FakeHID()
            let original = "{\"UserKeyMapping\":[{\"HIDKeyboardModifierMappingSrc\":4,\"HIDKeyboardModifierMappingDst\":5}]}"
            prefs.set(original, forKey: "CapsLink.staleOriginalMapping")
            hid.failWrites = true
            let capture = CapsInterceptor(testDefaults: prefs, process: hid.run)
            capture.start()
            try check(!capture.isActive, "started despite failed recovery")
            try check(prefs.string(forKey: "CapsLink.staleOriginalMapping") == original, "journal overwritten")
            hid.failWrites = false
            capture.stop()
        }
        test("a corrupt recovery journal is rejected before executing hidutil") {
            let prefs = MemoryPreferences(), hid = FakeHID()
            prefs.set("{\"UserKeyMapping\":[{\"HIDKeyboardModifierMappingSrc\":4}]}", forKey: "CapsLink.staleOriginalMapping")
            let capture = CapsInterceptor(testDefaults: prefs, process: hid.run)
            capture.start()
            try check(hid.writes.isEmpty && !capture.isActive, "corrupt journal was sent to hidutil")
            try check(CapsInterceptor.emergencyMappingJSON == nil, "corrupt journal reached emergency cleanup")
            try check(prefs.string(forKey: "CapsLink.staleOriginalMapping") != nil, "corrupt journal was discarded")
        }
        test("emergency recovery includes only validated keyboard mappings") {
            let prefs = MemoryPreferences(), hid = FakeHID()
            prefs.set("{\"UserKeyMapping\":[],\"UnsupportedProperty\":123}", forKey: "CapsLink.staleOriginalMapping")
            hid.failWrites = true
            let capture = CapsInterceptor(testDefaults: prefs, process: hid.run)
            try check(CapsInterceptor.emergencyMappingJSON == "{\"UserKeyMapping\":[]}", "emergency cleanup kept unsupported properties")
            hid.failWrites = false
            capture.stop()
        }
        test("failed startup rollback preserves the prior Caps Lock state for stop and retry") {
            for retry in [false, true] {
                let prefs = MemoryPreferences(), hid = FakeHID()
                var lock = true, failReset = true
                let capture = CapsInterceptor(testDefaults: prefs, process: hid.run,
                    readLock: { lock }, writeLock: { value in
                        lock = value
                        if failReset && !value { failReset = false; hid.failWrites = true; return false }
                        return true
                    })
                capture.start()
                try check(!capture.isActive && !lock && prefs.string(forKey: "CapsLink.staleOriginalMapping") != nil, "failure was not reproduced")
                hid.failWrites = false
                if retry {
                    capture.start()
                    try check(capture.isActive && capture.priorCapsLockOn, "retry forgot the original lock state")
                }
                capture.stop()
                try check(lock && prefs.string(forKey: "CapsLink.staleOriginalMapping") == nil, "cleanup lost the prior lock after failed startup")
            }
        }
        test("capture refuses to remap when the recovery journal cannot be saved") {
            let prefs = MemoryPreferences(), hid = FakeHID()
            prefs.syncSucceeds = false
            let capture = CapsInterceptor(testDefaults: prefs, process: hid.run)
            capture.start()
            try check(!capture.isActive && hid.writes.isEmpty, "remapped without a durable recovery journal")
        }
        test("duplicate mapping results cannot stand in for a missing mapping") {
            let prefs = MemoryPreferences(), hid = FakeHID()
            let journal = "{\"UserKeyMapping\":[{\"HIDKeyboardModifierMappingSrc\":4,\"HIDKeyboardModifierMappingDst\":5},{\"HIDKeyboardModifierMappingSrc\":6,\"HIDKeyboardModifierMappingDst\":7}]}"
            prefs.set(journal, forKey: "CapsLink.staleOriginalMapping")
            hid.ignoreWrites = true
            hid.output = "({ HIDKeyboardModifierMappingSrc = 4; HIDKeyboardModifierMappingDst = 5; }, { HIDKeyboardModifierMappingSrc = 4; HIDKeyboardModifierMappingDst = 5; })"
            let capture = CapsInterceptor(testDefaults: prefs, process: hid.run)
            try check(prefs.string(forKey: "CapsLink.staleOriginalMapping") == journal && !capture.isActive, "duplicate mapping passed verification")
        }
        test("queued key presses cannot survive a tap release or capture restart") {
            let delivery = CapturedKeyDelivery()
            var states: [Bool] = []
            var timestamps: [UInt64?] = []
            delivery.handler = { states.append($0); timestamps.append($1) }
            delivery.enqueue(true, timestamp: 10)
            delivery.release()
            drainMainQueue()
            try check(states == [false], "old press relatched after tap disable")
            delivery.enqueue(true, timestamp: 20)
            delivery.reset()
            delivery.handler = { states.append($0); timestamps.append($1) }
            drainMainQueue()
            try check(states == [false], "old press reached the new capture session")
            delivery.enqueue(true, timestamp: 100); delivery.enqueue(false, timestamp: 250); drainMainQueue()
            try check(states == [false, true, false], "valid key transitions lost their ordering")
            try check(timestamps == [nil, 100, 250], "queue delivery replaced event timestamps")
        }
        test("re-pairing the current peer stops microphone capture when consent is cleared") {
            let a = TestMac(alice, peer: bob.publicKey), b = TestMac(bob, peer: alice.publicKey)
            a.relay.start(); b.relay.start(); try exchange(a, b)
            a.controller.invitePTT { _ in }; try exchange(a, b)
            b.controller.acceptPTTInvite(expected: b.peerStore.ptt.incoming!) { _ in }
            try exchange(a, b)
            a.key(true); try exchange(a, b)
            try check(a.capture.running && b.controller.remoteTalking, "test did not start voice")
            try a.controller.pair(using: bob.pairingCode); try exchange(a, b)
            try check(!a.controller.pttEnabled && !a.capture.running && !a.controller.localTalking,
                      "microphone kept recording after pairing cleared consent")
            drainMainQueue(); try exchange(a, b)
            try check(!b.controller.remoteTalking, "peer kept playing after consent was cleared")
        }
        test("queued voice packets cannot restart playback after disconnect or pause") {
            for pause in [false, true] {
                let a = TestMac(alice, peer: bob.publicKey), remote = SecureWire(identity: bob)
                a.relay.start(); _ = try exchange(a, remote)
                a.peerStore.ptt.active = 42
                var payload = Data(); payload.appendUInt64(123)
                let packet = try remote.seal(kind: .talkStart, payload: payload, to: alice.publicKey)
                if pause { a.controller.setCaptureEnabled(false) } else { a.relay.stop() }
                a.relay.onMessage?("", packet)
                try check(!a.controller.remoteTalking, "voice restarted after \(pause ? "pause" : "disconnect")")
            }
        }
        test("pausing immediately stops playback as well as capture") {
            let a = TestMac(alice, peer: bob.publicKey), remote = SecureWire(identity: bob)
            a.relay.start(); _ = try exchange(a, remote)
            a.peerStore.ptt.active = 42
            var payload = Data(); payload.appendUInt64(123)
            a.relay.onMessage?("", try remote.seal(kind: .talkStart, payload: payload, to: alice.publicKey))
            try check(a.controller.remoteTalking, "test did not start playback")
            a.controller.setCaptureEnabled(false)
            try check(!a.controller.remoteTalking, "pause left voice playback active")
        }
        test("identity persists with private permissions and corrupt keys are not replaced") {
            let location = root.appendingPathComponent("alice")
            try check(try IdentityStore(directory: location).publicKey == alice.publicKey, "identity changed")
            let key = location.appendingPathComponent("identity.key")
            let attributes = try FileManager.default.attributesOfItem(atPath: key.path)
            try check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "private key permissions")
            try Data([1]).write(to: key)
            try mustThrow { _ = try IdentityStore(directory: location) }
            try check(try Data(contentsOf: key) == Data([1]), "corrupt key silently replaced")
        }
        test("only one instance can own the keyboard recovery journal") {
            let directory = root.appendingPathComponent("lock")
            var first: SingleInstanceLock? = try SingleInstanceLock(directory: directory)
            try withExtendedLifetime(first) { try mustThrow { _ = try SingleInstanceLock(directory: directory) } }
            first = nil
            _ = try SingleInstanceLock(directory: directory)
        }
        test("subprocess output drains both pipes without deadlock") {
            let result = try runProcess("/bin/sh", ["-c", "head -c 100000 /dev/zero; head -c 100000 /dev/zero >&2"])
            try check(result.0 == 0 && result.1.utf8.count == 100_000 && result.2.utf8.count == 100_000, "truncated process output")
        }
        test("native Opus encodes and decodes consecutive 20 ms frames") {
            let encoder = try OpusEncoder(), decoder = try OpusDecoder()
            for index in 0..<12 {
                let packet = try encoder.encode(Data(count: AudioConfig.bytesPerPCMFrame))
                let pcm = try decoder.decode(packet)
                // Native decoder priming can trim the first packet (280 samples
                // on macOS 14). Subsequent packets must retain the 20 ms cadence.
                try check(index == 0 ? (pcm.frameLength > 0 && pcm.frameLength <= 320) : pcm.frameLength == 320,
                          "unexpected decoded frame size: \(pcm.frameLength)")
            }
        }
        print("\(count - failures)/\(count) tests passed")
        if failures > 0 { exit(1) }
    }
}
