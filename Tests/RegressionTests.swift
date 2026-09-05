import Foundation
import Darwin
import CoreGraphics

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
    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func synchronize() -> Bool { true }
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
        test("Accessibility prompts only once across activation attempts and relaunches") {
            let prefs = MemoryPreferences(), hid = FakeHID()
            var prompts = 0
            let capture = CapsInterceptor(testDefaults: prefs, process: hid.run,
                                          trustCheck: { false }, permissionPrompt: { prompts += 1 })
            capture.requestPermissionAndStart()
            capture.requestPermissionAndStart()
            capture.stop()
            capture.requestPermissionAndStart()
            capture.stop()
            let relaunched = CapsInterceptor(testDefaults: prefs, process: hid.run,
                                             trustCheck: { false }, permissionPrompt: { prompts += 1 })
            relaunched.requestPermissionAndStart()
            relaunched.stop()
            try check(prompts == 1, "permission UI reopened after the first request")
            try check(hid.writes.isEmpty, "untrusted capture changed the keyboard mapping")
        }
        test("existing installs do not prompt again when upgraded") {
            for legacyKey in ["CapsLink.captureEnabled", "CapsLink.didConfigureLaunchAtLogin"] {
                let prefs = MemoryPreferences(), hid = FakeHID()
                prefs.set(false, forKey: legacyKey)
                var prompts = 0
                let capture = CapsInterceptor(testDefaults: prefs, process: hid.run,
                                              trustCheck: { false }, permissionPrompt: { prompts += 1 })
                capture.requestPermissionAndStart()
                capture.stop()
                try check(prompts == 0, "upgrade prompted again for \(legacyKey)")
            }
        }
        test("permission granted later enables capture without another prompt") {
            let prefs = MemoryPreferences(), hid = FakeHID()
            var trusted = true
            var prompts = 0
            let capture = CapsInterceptor(testDefaults: prefs, process: hid.run,
                                          trustCheck: { trusted }, permissionPrompt: { prompts += 1 })
            capture.requestPermissionAndStart()
            try check(capture.isActive, "trusted capture did not start")
            capture.stop()
            trusted = false
            capture.requestPermissionAndStart()
            try check(!capture.isActive && prompts == 0, "revoked permission reopened the prompt")
            trusted = true
            capture.requestPermissionAndStart()
            try check(capture.isActive && prompts == 0, "capture did not resume quietly")
            capture.stop()
        }
        test("capture rejects a successful hidutil command that did not install the mapping") {
            let prefs = MemoryPreferences(), hid = FakeHID()
            hid.ignoreWrites = true
            let capture = CapsInterceptor(testDefaults: prefs, process: hid.run)
            capture.start()
            try check(!capture.isActive && capture.lastError != nil, "claimed capture without a mapping")
            try check(prefs.string(forKey: "CapsLink.staleOriginalMapping") == nil, "empty original mapping was not recovered")
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
        test("Dit's tail gives outgoing activity priority over notifications") {
            try check(FireflyIcon.tailState(localActive: false, attention: false) == .idle,
                      "idle tail state")
            try check(FireflyIcon.tailState(localActive: false, attention: true) == .notification,
                      "notification tail state")
            try check(FireflyIcon.tailState(localActive: true, attention: true) == .outgoing,
                      "outgoing key did not get tail priority")
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
