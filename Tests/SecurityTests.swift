import Foundation
import CryptoKit
import Darwin

private struct SecurityFailure: Error { let message: String }
private func requireSecurity(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw SecurityFailure(message: message) }
}
private func refuses(_ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw SecurityFailure(message: "Unsafe input was accepted")
}

@main enum SecurityTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("slock-security-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var count = 0, failures = 0
        func test(_ name: String, _ body: () throws -> Void) {
            count += 1
            do { try body(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        func directory() throws -> URL {
            let url = root.appendingPathComponent(UUID().uuidString)
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        }
        test("private storage rejects symlinked directories without changing their target") {
            let target = try directory()
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            let link = root.appendingPathComponent("linked-directory")
            try fm.createSymbolicLink(at: link, withDestinationURL: target)
            try refuses { _ = try IdentityStore(directory: link) }
            try refuses { _ = try SingleInstanceLock(directory: link) }
            let attributes = try fm.attributesOfItem(atPath: target.path)
            try requireSecurity((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755,
                                "rejected directory target was modified")
            try requireSecurity(try fm.contentsOfDirectory(atPath: target.path).isEmpty, "created files through link")
        }
        test("private keys and locks reject symbolic links, hard links and FIFOs") {
            for name in ["identity.key", "instance.lock"] {
                for kind in ["symbolic", "hard", "fifo"] {
                    let support = try directory()
                    let candidate = support.appendingPathComponent(name)
                    let target = root.appendingPathComponent(UUID().uuidString)
                    let bytes = Data(repeating: 42, count: 32)
                    try bytes.write(to: target)
                    try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
                    switch kind {
                    case "symbolic": try fm.createSymbolicLink(at: candidate, withDestinationURL: target)
                    case "hard": try fm.linkItem(at: target, to: candidate)
                    default: try requireSecurity(mkfifo(candidate.path, 0o600) == 0, "could not create test FIFO")
                    }
                    try refuses {
                        if name == "identity.key" { _ = try IdentityStore(directory: support) }
                        else { _ = try SingleInstanceLock(directory: support) }
                    }
                    try requireSecurity(try Data(contentsOf: target) == bytes, "linked file contents changed")
                    let attributes = try fm.attributesOfItem(atPath: target.path)
                    try requireSecurity((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o644,
                                        "linked file permissions changed")
                }
            }
        }
        test("existing identities migrate to private directories without changing the key") {
            let support = try directory()
            let original = try IdentityStore(directory: support)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: support.path)
            let loaded = try IdentityStore(directory: support)
            try requireSecurity(original.publicKey == loaded.publicKey, "identity changed")
            let attributes = try fm.attributesOfItem(atPath: support.path)
            try requireSecurity((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "directory is not private")
        }
        test("private file descriptors cannot be inherited by executed helpers") {
            let storage = try PrivateStorage(directory: directory())
            let fd = try storage.openFile("instance.lock").descriptor
            defer { close(fd) }
            try requireSecurity(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0, "file inherited across exec")
            try requireSecurity(fcntl(storage.descriptor, F_GETFD) & FD_CLOEXEC != 0, "directory inherited across exec")
        }
        test("oversized identities and pairing codes fail closed") {
            let support = try directory()
            let key = support.appendingPathComponent("identity.key")
            try Data(count: 1_000_000).write(to: key)
            try refuses { _ = try IdentityStore(directory: support) }
            try refuses { _ = try IdentityStore.publicKey(fromPairingCode: String(repeating: "A", count: 1_000_000)) }
            try requireSecurity(try Data(contentsOf: key).count == 1_000_000, "invalid identity was replaced")
        }
        test("pair verification displays a 128-bit fingerprint and preserves pairing codes") {
            let identity = try IdentityStore(directory: directory())
            let fingerprint = identity.shortID.replacingOccurrences(of: "-", with: "")
            try requireSecurity(fingerprint.count == 32, "fingerprint is too short")
            try requireSecurity(fingerprint == Data(SHA256.hash(data: identity.publicKey)).prefix(16)
                .map { String(format: "%02X", $0) }.joined(), "fingerprint is not bound to public key")
            try requireSecurity(try IdentityStore.publicKey(fromPairingCode: identity.pairingCode) == identity.publicKey,
                                "existing pairing format broke")
        }
        test("stranger floods cannot consume the reserved peer decryption budget") {
            var budget = InboundBudget()
            for _ in 0..<8 { try requireSecurity(budget.allow(selected: false, at: 100), "initial request rejected") }
            for _ in 0..<10_000 { try requireSecurity(!budget.allow(selected: false, at: 100), "stranger bypassed limit") }
            for _ in 0..<112 { try requireSecurity(budget.allow(selected: true, at: 100), "peer budget starved") }
            try requireSecurity(!budget.allow(selected: true, at: 100), "spoofed peer can do unlimited work")
            try requireSecurity(budget.allow(selected: true, at: 101), "peer budget never recovers")
            try requireSecurity(budget.allow(selected: false, at: 101), "stranger budget never recovers")
        }
        test("MQTT connections use unpredictable identifiers independent of public routing keys") {
            let identifiers = (0..<1_000).map { _ in MQTTClient.freshClientID() }
            try requireSecurity(Set(identifiers).count == identifiers.count, "reused identifier")
            try requireSecurity(identifiers.allSatisfy { $0.utf8.count == 23 && $0.hasPrefix("cl-") }, "invalid MQTT ID")
        }
        print("\(count - failures)/\(count) security tests passed")
        if failures > 0 { exit(1) }
    }
}
