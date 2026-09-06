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

private final class MetadataProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode = request.url!.lastPathComponent
        let headers = mode == "declared" ? ["Content-Length": String(ReleaseRequest.maximumBytes + 1)] : [:]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        if mode == "streamed" {
            for _ in 0..<3 { client?.urlProtocol(self, didLoad: Data(count: ReleaseRequest.maximumBytes / 2)) }
        } else { client?.urlProtocol(self, didLoad: Data("{}".utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

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
        test("a confirmed current version refreshes the menu and a later update restores the action") {
            let server = FakeReleaseServer()
            var now = Date()
            let checker = UpdateChecker(currentVersion: "0.3.0", now: { now }, fetch: server.fetch)
            var changes = 0
            checker.onChange = { changes += 1 }
            try expectUpdate(!checker.isUpToDate, "unchecked version marked current")
            for (data, status) in [(Data("bad JSON".utf8), 200), (try release("v0.3.0", draft: true), 200),
                                   (try release("v0.3.0", prerelease: true), 200), (try release("invalid"), 200),
                                   (try release("v0.2.9"), 200), (Data(), 404), (Data(), 403)] {
                checker.checkNow { _ in }
                server.respond(data, status: status)
                try expectUpdate(!checker.isUpToDate && changes == 0, "unconfirmed result hid the action")
            }
            checker.checkNow { _ in }
            server.respond(try release("v0.3.0"))
            try expectUpdate(checker.isUpToDate && checker.availableUpdate == nil && changes == 1,
                             "first matching result did not refresh the menu")
            checker.checkNow { _ in }
            server.respond(try release("v0.3.0"))
            try expectUpdate(changes == 1, "unchanged match notified again")
            now.addTimeInterval(UpdateChecker.checkInterval)
            checker.checkIfNeeded()
            server.respond(error: URLError(.notConnectedToInternet))
            try expectUpdate(checker.isUpToDate && changes == 1, "temporary failure erased confirmed state")
            now.addTimeInterval(UpdateChecker.retryInterval)
            checker.checkIfNeeded()
            server.respond(try release("v0.3.1"))
            try expectUpdate(!checker.isUpToDate && checker.availableUpdate?.tag == "v0.3.1" && changes == 2,
                             "background check did not restore the update action")
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
        test("clicking update bypasses cached metadata and selects the newest release") {
            let server = FakeReleaseServer()
            let checker = UpdateChecker(currentVersion: "0.2.6", fetch: server.fetch)
            checker.checkIfNeeded()
            server.respond(try release("v0.2.7"))
            var chosen: SlockUpdate?
            checker.checkNow { chosen = try? $0.get() }
            try expectUpdate(server.requests.count == 2, "click reused the hourly cache")
            server.respond(try release("v0.2.9"))
            try expectUpdate(chosen?.tag == "v0.2.9", "click chose an outdated release")
        }
        test("an explicit failed check cannot install a cached update and can retry immediately") {
            let server = FakeReleaseServer()
            let checker = UpdateChecker(currentVersion: "0.2.6", fetch: server.fetch)
            checker.checkIfNeeded()
            server.respond(try release("v0.2.7"))
            var failed = false
            checker.checkNow { if case .failure = $0 { failed = true } }
            server.respond(status: 403)
            try expectUpdate(failed && checker.availableUpdate?.tag == "v0.2.7", "failure installed cached metadata")
            var completed = 0
            checker.checkNow { _ in completed += 1 }
            checker.checkNow { _ in completed += 1 }
            try expectUpdate(server.requests.count == 3, "explicit checks did not coalesce or retry")
            server.respond(try release("v0.2.9"))
            try expectUpdate(completed == 2, "coalesced callbacks were lost")
        }
        test("the update action handles up-to-date, failure, and cancellation without installing") {
            let server = FakeReleaseServer()
            let checker = UpdateChecker(currentVersion: "0.2.9", fetch: server.fetch)
            let updater = AppUpdater()
            var current = 0, errors = 0, restarts = 0
            updater.onUpToDate = { current += 1 }
            updater.onError = { _ in errors += 1 }
            updater.onReadyToRelaunch = { restarts += 1 }
            updater.checkAndInstall(using: checker)
            updater.checkAndInstall(using: checker)
            try expectUpdate(server.requests.count == 1 && updater.status != nil, "overlapping installs")
            server.respond(try release("v0.2.9"))
            try expectUpdate(current == 1 && updater.status == nil, "up-to-date did not reset UI")
            updater.checkAndInstall(using: checker)
            server.respond(status: 500)
            try expectUpdate(errors == 1 && updater.status == nil, "failure did not reset UI")
            updater.checkAndInstall(using: checker)
            updater.cancel()
            server.respond(try release("v0.3.0"))
            try expectUpdate(restarts == 0 && errors == 1, "cancelled update continued")
        }
        test("signed update URLs stay on GitHub and reject path, query and fragment injection") {
            for tag in ["v1.2.3/../../elsewhere", "v1.2.3?download=evil", "v1.2.3#evil", "1.2.3", "https://example.com", "v1.2.3\n"] {
                try expectUpdate(SlockUpdate(tag: tag).packageURL == nil, tag)
            }
            try expectUpdate(SlockUpdate(tag: "v1.2.3").packageURL?.absoluteString ==
                "https://github.com/jonaraphael/slock/releases/download/v1.2.3/slock-update.json", "wrong package URL")
        }
        test("oversized release metadata is rejected") {
            try expectUpdateError {
                _ = try SlockUpdate.available(in: Data(repeating: 32, count: ReleaseRequest.maximumBytes + 1),
                                             currentVersion: "0.2.5")
            }
        }
        test("the HTTP reader bounds both declared and streamed response sizes") {
            for mode in ["small", "declared", "streamed"] {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [MetadataProtocol.self]
                var finished = false, received: Data?, failure: Error?
                ReleaseRequest.fetch(URLRequest(url: URL(string: "https://api.github.com/\(mode)")!),
                                     configuration: configuration) { data, _, error in
                    DispatchQueue.main.async { received = data; failure = error; finished = true }
                }
                let deadline = Date().addingTimeInterval(5)
                while !finished, Date() < deadline { drainUpdates() }
                try expectUpdate(finished, "request never completed")
                if mode == "small" {
                    try expectUpdate(received == Data("{}".utf8) && failure == nil, "valid metadata failed")
                } else {
                    try expectUpdate(received == nil && failure != nil, "oversized response was delivered")
                }
            }
        }
        print("\(count - failures)/\(count) update tests passed")
        if failures > 0 { exit(1) }
    }
}
