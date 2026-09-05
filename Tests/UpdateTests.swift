import Foundation
import CryptoKit
import Darwin

private struct UpdateFailure: Error { let message: String }
private func expectUpdate(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw UpdateFailure(message: message) }
}
private func expectUpdateError(_ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw UpdateFailure(message: "Expected failure")
}
private func release(_ tag: String, draft: Bool = false, prerelease: Bool = false) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["tag_name": tag, "draft": draft, "prerelease": prerelease])
}
private func drainUpdates() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

private final class FakeReleaseServer {
    var requests: [URLRequest] = []
    var completions: [UpdateChecker.Completion] = []
    func fetch(_ request: URLRequest, completion: @escaping UpdateChecker.Completion) {
        requests.append(request)
        completions.append(completion)
    }
    func respond(_ data: Data? = nil, status: Int = 200, error: Error? = nil) {
        completions.removeFirst()(data, HTTPURLResponse(url: UpdateChecker.latestReleaseURL,
            statusCode: status, httpVersion: nil, headerFields: nil), error)
        drainUpdates()
    }
}

@main enum UpdateTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("slock-update-tests-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var count = 0, failures = 0
        func test(_ name: String, _ body: () throws -> Void) {
            count += 1
            do { try body(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        func fixture() throws -> PreparedUpdate {
            let parent = root.appendingPathComponent(UUID().uuidString)
            let prepared = PreparedUpdate(directory: parent.appendingPathComponent("staging"),
                                          destination: parent.appendingPathComponent("slock.app"))
            try fm.createDirectory(at: prepared.app, withIntermediateDirectories: true)
            try fm.createDirectory(at: prepared.destination, withIntermediateDirectories: true)
            try Data("old".utf8).write(to: prepared.destination.appendingPathComponent("version"))
            try Data("new".utf8).write(to: prepared.app.appendingPathComponent("version"))
            return prepared
        }
        func installedVersion(_ app: URL) throws -> String {
            try String(contentsOf: app.appendingPathComponent("version"), encoding: .utf8)
        }

        test("updates compare numeric tags and never offer the same or an older version") {
            try expectUpdate(SlockUpdate.available(in: release("v0.2.4"), currentVersion: "0.2.4") == nil, "same tag")
            try expectUpdate(SlockUpdate.available(in: release("v0.2.3"), currentVersion: "0.2.4") == nil, "downgrade")
            try expectUpdate(SlockUpdate.available(in: release("v0.2.10"), currentVersion: "v0.2.9")?.tag == "v0.2.10", "lexical comparison")
            try expectUpdate(SlockUpdate.available(in: release("v0.10.0"), currentVersion: "0.9.99") != nil, "minor bump")
            try expectUpdate(SlockUpdate.available(in: release("v1.0.0"), currentVersion: "0.99.99") != nil, "major bump")
        }
        test("draft, preview and malformed release versions cannot trigger an update") {
            for tag in ["v1.0", "v1.0.0-beta.1", "v1.0.0+build", "v01.0.0", "v1..0", "v-1.0.0", " v1.0.0", "v1.0.0/../../", "v9999999999999999999999999.0.0"] {
                try expectUpdate(SlockUpdate.available(in: release(tag), currentVersion: "0.2.4") == nil, tag)
            }
            try expectUpdate(SlockUpdate.available(in: release("v1.0.0", draft: true), currentVersion: "0.2.4") == nil, "draft")
            try expectUpdate(SlockUpdate.available(in: release("v1.0.0", prerelease: true), currentVersion: "0.2.4") == nil, "preview")
            try expectUpdate(SlockUpdate.available(in: release("v1.0.0"), currentVersion: "unknown") == nil, "unknown local version")
            try expectUpdateError { _ = try SlockUpdate.available(in: Data("{}".utf8), currentVersion: "0.2.4") }
        }
        test("release checks coalesce requests, throttle retries, and deliver state on the main thread") {
            let server = FakeReleaseServer()
            var now = Date()
            let checker = UpdateChecker(currentVersion: "0.2.4", now: { now }, fetch: server.fetch)
            var changes = 0, onMain = false
            checker.onChange = { changes += 1; onMain = Thread.isMainThread }
            checker.checkIfNeeded()
            checker.checkIfNeeded()
            try expectUpdate(server.requests.count == 1, "overlapping requests")
            try expectUpdate(server.requests[0].url == UpdateChecker.latestReleaseURL, "wrong endpoint")
            try expectUpdate(server.requests[0].value(forHTTPHeaderField: "User-Agent") == "slock/0.2.4", "missing user agent")
            server.respond(try release("v0.2.5"))
            try expectUpdate(checker.availableUpdate?.tag == "v0.2.5" && changes == 1 && onMain, "update not delivered")
            checker.checkIfNeeded()
            try expectUpdate(server.requests.count == 1, "no success throttle")
            now.addTimeInterval(UpdateChecker.checkInterval)
            checker.checkIfNeeded()
            server.respond(try release("v0.2.5"))
            try expectUpdate(changes == 1, "unchanged result notified")
            now.addTimeInterval(UpdateChecker.checkInterval)
            checker.checkIfNeeded()
            server.respond(try release("v0.2.4"))
            try expectUpdate(checker.availableUpdate == nil && changes == 2, "withdrawn update kept")
        }
        test("offline, malformed and rate-limited checks preserve an update and recover") {
            let server = FakeReleaseServer()
            var now = Date()
            let checker = UpdateChecker(currentVersion: "0.2.4", now: { now }, fetch: server.fetch)
            checker.checkIfNeeded()
            server.respond(error: URLError(.notConnectedToInternet))
            try expectUpdate(checker.availableUpdate == nil, "offline fabricated an update")
            checker.checkIfNeeded()
            try expectUpdate(server.requests.count == 1, "offline retry loop")
            now.addTimeInterval(UpdateChecker.retryInterval)
            checker.checkIfNeeded()
            server.respond(try release("v0.2.5"))
            now.addTimeInterval(UpdateChecker.checkInterval)
            for (data, status) in [(Data("bad JSON".utf8), 200), (Data(), 403), (Data(), 500)] {
                checker.checkIfNeeded()
                server.respond(data, status: status)
                try expectUpdate(checker.availableUpdate?.tag == "v0.2.5", "failure erased an update")
                now.addTimeInterval(UpdateChecker.retryInterval)
            }
            checker.checkIfNeeded()
            server.respond(status: 404)
            try expectUpdate(checker.availableUpdate == nil, "removed release still offered")
        }
        test("download checksums reject tampering, missing entries and duplicate entries") {
            let archive = root.appendingPathComponent("archive.zip")
            let data = Data("downloaded app".utf8)
            try data.write(to: archive)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let sums = "\(hash)  slock.app.zip\n"
            try UpdateInstaller.verifyChecksum(Data(sums.utf8), archive: archive)
            try expectUpdateError { try UpdateInstaller.verifyChecksum(Data((sums + sums).utf8), archive: archive) }
            try expectUpdateError { try UpdateInstaller.verifyChecksum(Data("missing".utf8), archive: archive) }
            try Data("tampered".utf8).write(to: archive)
            try expectUpdateError { try UpdateInstaller.verifyChecksum(Data(sums.utf8), archive: archive) }
        }
        test("archive paths cannot write outside the staging directory") {
            try expectUpdate(UpdateInstaller.validArchivePaths("slock.app/\nslock.app/Contents/MacOS/slock\n__MACOSX/slock.app/._Contents\n"), "valid package")
            for path in ["", "/slock.app/Contents", "slock.app/../../outside", "__MACOSX/../../outside", "elsewhere/app", "slock.app/../outside"] {
                try expectUpdate(!UpdateInstaller.validArchivePaths(path), path)
            }
        }
        test("bundle verification checks identity, version, executable and signature") {
            let app = root.appendingPathComponent("validate.app")
            let binary = app.appendingPathComponent("Contents/MacOS/slock")
            try fm.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: binary)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            var info = ["CFBundleIdentifier": "com.jonaraphael.CapsLink", "CFBundleExecutable": "slock", "CFBundleShortVersionString": "0.2.5"]
            func saveInfo() throws {
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                    .write(to: app.appendingPathComponent("Contents/Info.plist"))
            }
            try saveInfo()
            var verified = false
            try UpdateInstaller.validateBundle(app, expectedTag: "v0.2.5") { _ in verified = true }
            try expectUpdate(verified, "signature skipped")
            try expectUpdateError { try UpdateInstaller.validateBundle(app, expectedTag: "v0.2.5") { _ in throw UpdateFailure(message: "bad signature") } }
            try expectUpdateError { try UpdateInstaller.validateBundle(app, expectedTag: "v0.2.6") { _ in } }
            info["CFBundleIdentifier"] = "another.app"
            try saveInfo()
            try expectUpdateError { try UpdateInstaller.validateBundle(app, expectedTag: "v0.2.5") { _ in } }
        }
        test("installation replaces the app, relaunches its existing path and removes staging") {
            let prepared = try fixture()
            var opened = false
            try prepared.install { url in
                try expectUpdate(url == prepared.destination, "changed app location")
                try expectUpdate(installedVersion(url) == "new", "launched old app")
                try expectUpdate(installedVersion(prepared.backup) == "old", "no backup")
                opened = true
            }
            try expectUpdate(opened && !fm.fileExists(atPath: prepared.directory.path), "no relaunch or staging remains")
        }
        test("failed replacement restores and reopens the previous app") {
            let prepared = try fixture()
            try fm.removeItem(at: prepared.app)
            var opened = false
            try expectUpdateError {
                try prepared.install { url in opened = true; try expectUpdate(installedVersion(url) == "old", "wrong restored app") }
            }
            try expectUpdate(opened && installedVersion(prepared.destination) == "old", "old app lost")
        }
        test("failed relaunch rolls back before reopening the previous app") {
            let prepared = try fixture()
            var launches = 0
            try expectUpdateError {
                try prepared.install { url in
                    launches += 1
                    if launches == 1 { throw UpdateFailure(message: "launch failed") }
                    try expectUpdate(installedVersion(url) == "old", "rollback launch used new app")
                }
            }
            try expectUpdate(launches == 2 && installedVersion(prepared.destination) == "old", "no rollback")
        }
        test("failed backup leaves the original app intact and reopens it") {
            let prepared = try fixture()
            try fm.createDirectory(at: prepared.backup, withIntermediateDirectories: false)
            var opened = false
            try expectUpdateError { try prepared.install { _ in opened = true } }
            try expectUpdate(opened && installedVersion(prepared.destination) == "old", "original app changed")
        }
        test("failed rollback preserves the backup for recovery") {
            let prepared = try fixture()
            try expectUpdateError {
                try prepared.install { _ in
                    try fm.createDirectory(at: prepared.app, withIntermediateDirectories: false)
                    throw UpdateFailure(message: "launch failed with occupied staging path")
                }
            }
            try expectUpdate(installedVersion(prepared.backup) == "old", "backup lost after rollback failure")
        }
        print("\(count - failures)/\(count) update tests passed")
        if failures > 0 { exit(1) }
    }
}
