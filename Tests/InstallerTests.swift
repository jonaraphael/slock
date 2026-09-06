import CryptoKit
import Foundation
import Darwin

@main enum InstallerTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("slock-installer-tests-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let key = Curve25519.Signing.PrivateKey()
        var count = 0, failures = 0
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw appError("test", message) }
        }
        func rejects(_ body: () throws -> Void) throws {
            do { try body() } catch { return }
            throw appError("test", "Expected rejection")
        }
        func test(_ name: String, _ body: () throws -> Void) {
            count += 1
            do { try body(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        func plist(_ version: String = "0.2.9") throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": "com.jonaraphael.CapsLink", "CFBundleExecutable": "slock",
                "CFBundleShortVersionString": version, "CFBundleVersion": "11",
                "SlockUpdatePublicKey": key.publicKey.rawRepresentation.base64EncodedString()
            ], format: .xml, options: 0)
        }
        let files = try SignedUpdate.paths.sorted().map { path in
            SignedUpdate.File(path: path, data: path == "Contents/Info.plist" ? try plist() : Data("fixture".utf8))
        }
        func package(_ entries: [SignedUpdate.File]) throws -> Data {
            let payload = try JSONEncoder().encode(SignedUpdate.Contents(format: 1, version: "0.2.9", build: "11", files: entries))
            return try JSONEncoder().encode(SignedUpdate(payload: payload, signature: key.signature(for: payload)))
        }
        func verify(_ data: Data, tag: String = "v0.2.9", publicKey: Data? = nil) throws -> SignedUpdate.Contents {
            try SignedUpdate.verify(data, publicKey: publicKey ?? key.publicKey.rawRepresentation, expectedTag: tag)
        }
        test("a publisher-signed package reconstructs only the expected app files") {
            let contents = try verify(package(files))
            let app = root.appendingPathComponent("staged.app")
            try UpdateInstaller.stage(contents, in: app)
            try check(try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")) == plist(), "plist changed")
            try check(fm.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/slock").path), "executable permission missing")
            var enumerated: Set<String> = []
            for case let url as URL in fm.enumerator(at: app, includingPropertiesForKeys: nil)! {
                if ownedUpdatePath(url, directory: false), let relative = UpdateInstaller.bundleRelativePath(url, root: app) {
                    enumerated.insert(relative)
                }
            }
            try check(enumerated == SignedUpdate.paths, "temporary-directory aliases changed the bundle inventory")
            try check(UpdateInstaller.bundleRelativePath(root.appendingPathComponent("outside"), root: app) == nil,
                      "accepted a path outside the bundle")
            try rejects { try UpdateInstaller.stage(contents, in: app) }
        }
        test("tampered payloads, wrong signing keys, and wrong release tags are rejected") {
            let data = try package(files)
            let envelope = try JSONDecoder().decode(SignedUpdate.self, from: data)
            let bad = SignedUpdate(payload: envelope.payload + Data([32]), signature: envelope.signature)
            try rejects { _ = try verify(JSONEncoder().encode(bad)) }
            try rejects { _ = try verify(data, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation) }
            try rejects { _ = try verify(data, tag: "v0.3.0") }
            try rejects { _ = try verify(Data(count: SignedUpdate.maximumBytes + 1)) }
        }
        test("even signed traversal paths, duplicate files, missing files, and wrong bundle versions fail") {
            for path in ["../outside", "/tmp/outside", "Contents/../outside", "Contents/Resources/extra"] {
                try rejects { _ = try verify(package(Array(files.dropLast()) + [.init(path: path, data: Data([1]))])) }
            }
            try rejects { _ = try verify(package(Array(files.dropLast()) + [files[0]])) }
            try rejects { _ = try verify(package(Array(files.dropLast()))) }
            let wrong = try files.map { SignedUpdate.File(path: $0.path, data: $0.path == "Contents/Info.plist" ? try plist("0.2.8") : $0.data) }
            try rejects { _ = try verify(package(wrong)) }
        }
        func prepared(_ name: String) throws -> PreparedUpdate {
            let parent = root.appendingPathComponent(name)
            try fm.createDirectory(at: parent, withIntermediateDirectories: false)
            let destination = parent.appendingPathComponent("slock.app")
            try fm.createDirectory(at: destination.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try plist("0.2.8").write(to: destination.appendingPathComponent("Contents/Info.plist"))
            let dir = parent.appendingPathComponent(".slock-update-fixture")
            try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let prepared = PreparedUpdate(directory: dir, destination: destination, originalVersion: "0.2.8", newVersion: "0.2.9")
            try UpdateInstaller.stage(verify(package(files)), in: prepared.app)
            return prepared
        }
        test("installation replaces the app in place and relaunches its original path") {
            let p = try prepared("success")
            var opened: URL?
            try p.install(relaunch: { opened = $0 }, verifyBundle: { _, _ in })
            try check(opened == p.destination && !fm.fileExists(atPath: p.directory.path), "wrong relaunch or leftover staging")
            try check(try Data(contentsOf: p.destination.appendingPathComponent("Contents/Info.plist")) == plist(), "old app remained")
        }
        test("a relaunch failure restores the previous app and retries that copy") {
            let p = try prepared("rollback")
            var attempts = 0
            try rejects {
                try p.install(relaunch: { _ in attempts += 1; if attempts == 1 { throw appError("test", "relaunch failed") } },
                              verifyBundle: { _, _ in })
            }
            try check(attempts == 2, "did not try reopening restored app")
            try check(try Data(contentsOf: p.destination.appendingPathComponent("Contents/Info.plist")) == plist("0.2.8"), "rollback lost old app")
        }
        test("bundle validation failure leaves the installed app untouched") {
            let p = try prepared("validation")
            try rejects { try p.install(relaunch: { _ in throw appError("test", "must not relaunch") }) }
            try check(fm.fileExists(atPath: p.destination.path) && !fm.fileExists(atPath: p.backup.path), "invalid bundle replaced the app")
        }
        test("links and unsafe staging permissions are rejected before replacement") {
            let p = try prepared("unsafe")
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p.directory.path)
            try rejects { try p.validateLayout() }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: p.directory.path)
            let actual = p.destination.deletingLastPathComponent().appendingPathComponent("actual.app")
            try fm.moveItem(at: p.destination, to: actual)
            try fm.createSymbolicLink(at: p.destination, withDestinationURL: actual)
            try rejects { try p.install(relaunch: { _ in }, verifyBundle: { _, _ in }) }
            try check(fm.fileExists(atPath: actual.path), "followed or changed linked destination")
        }
        print("\(count - failures)/\(count) installer tests passed")
        if failures > 0 { exit(1) }
    }
}
