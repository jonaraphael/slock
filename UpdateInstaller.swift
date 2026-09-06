import AppKit
import CryptoKit
import Darwin
import Foundation

// Only these six regular files are carried by an update. There is no archive
// extraction, downloaded script, link, or arbitrary filename to execute.
struct SignedUpdate: Codable {
    let payload: Data
    let signature: Data
    struct File: Codable { let path: String; let data: Data }
    struct Contents: Codable {
        let format: Int
        let version: String
        let build: String
        let files: [File]
    }
    static let maximumBytes = 32 * 1024 * 1024
    static let paths: Set<String> = ["Contents/Info.plist", "Contents/MacOS/slock",
        "Contents/Resources/AppIcon.icns", "Contents/Resources/LICENSE",
        "Contents/Resources/THIRD_PARTY_NOTICES.md", "Contents/_CodeSignature/CodeResources"]

    static func verify(_ data: Data, publicKey: Data, expectedTag: String) throws -> Contents {
        guard data.count <= maximumBytes else { throw appError("slock.Update", "The update exceeds its size limit.") }
        let envelope = try JSONDecoder().decode(Self.self, from: data)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        guard key.isValidSignature(envelope.signature, for: envelope.payload) else {
            throw appError("slock.Update", "The update's publisher signature is invalid. Nothing was installed.")
        }
        let contents = try JSONDecoder().decode(Contents.self, from: envelope.payload)
        guard contents.format == 1, expectedTag == "v" + contents.version,
              ReleaseVersion(contents.version) != nil,
              !contents.build.isEmpty, contents.build.utf8.allSatisfy({ (48...57).contains($0) }),
              contents.files.count == paths.count, Set(contents.files.map(\.path)) == paths,
              contents.files.allSatisfy({ !$0.data.isEmpty }),
              let plist = contents.files.first(where: { $0.path == "Contents/Info.plist" }),
              let info = try PropertyListSerialization.propertyList(from: plist.data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "com.jonaraphael.CapsLink",
              info["CFBundleExecutable"] as? String == "slock",
              info["CFBundleShortVersionString"] as? String == contents.version,
              info["CFBundleVersion"] as? String == contents.build,
              info["SlockUpdatePublicKey"] as? String == publicKey.base64EncodedString() else {
            throw appError("slock.Update", "The signed update does not contain the expected slock release.")
        }
        return contents
    }
}

func ownedUpdatePath(_ url: URL, directory: Bool, privateDirectory: Bool = false) -> Bool {
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_uid == geteuid(),
          info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else { return false }
    return directory ? (!privateDirectory || info.st_mode & 0o777 == 0o700) : info.st_nlink == 1
}

struct PreparedUpdate {
    let directory: URL
    let destination: URL
    let originalVersion: String
    let newVersion: String
    var app: URL { directory.appendingPathComponent("slock.app") }
    var backup: URL { directory.appendingPathComponent("previous.app") }
    var helper: URL { directory.appendingPathComponent("install-update") }

    func validateLayout() throws {
        guard directory.path == directory.standardizedFileURL.path, destination.path == destination.standardizedFileURL.path,
              directory.deletingLastPathComponent().path == destination.deletingLastPathComponent().path,
              directory.lastPathComponent.hasPrefix(".slock-update-"), destination.pathExtension == "app",
              ownedUpdatePath(directory, directory: true, privateDirectory: true),
              let next = ReleaseVersion(newVersion), let old = ReleaseVersion(originalVersion), next > old else {
            throw appError("slock.Update", "The update staging location or version is invalid.")
        }
    }

    func launchHelper() throws {
        try validateLayout()
        guard ownedUpdatePath(helper, directory: false) else {
            throw appError("slock.Update", "The local update helper is invalid.")
        }
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--slock-install-update", String(getpid()), directory.path,
                             destination.path, originalVersion, newVersion]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    func install(relaunch: (URL) throws -> Void = { url in
        let (status, _, _) = try runProcess("/usr/bin/open", ["-n", url.path])
        guard status == 0 else { throw appError("slock.Update", "Could not reopen slock.") }
    }, verifyBundle: (URL, String) throws -> Void = UpdateInstaller.validateBundle) throws {
        try validateLayout()
        let fm = FileManager.default
        guard ownedUpdatePath(destination, directory: true), !fm.fileExists(atPath: backup.path) else {
            throw appError("slock.Update", "The installed app changed while downloading. Please check for updates again.")
        }
        let installedData = try Data(contentsOf: destination.appendingPathComponent("Contents/Info.plist"))
        guard let installedInfo = try PropertyListSerialization.propertyList(from: installedData, format: nil) as? [String: Any],
              installedInfo["CFBundleShortVersionString"] as? String == originalVersion else {
            throw appError("slock.Update", "The installed app changed while downloading. Please check for updates again.")
        }
        try verifyBundle(app, newVersion)
        try fm.moveItem(at: destination, to: backup)
        do {
            try fm.moveItem(at: app, to: destination)
            try relaunch(destination)
        } catch {
            let failure = error
            do {
                if fm.fileExists(atPath: destination.path) { try fm.moveItem(at: destination, to: app) }
                try fm.moveItem(at: backup, to: destination)
            } catch {
                throw appError("slock.Update", "Could not restore the previous app. It remains at \(backup.path).")
            }
            try? relaunch(destination)
            throw failure
        }
        try? fm.removeItem(at: directory)
    }
}

enum UpdateInstaller {
    static let assetHosts: Set<String> = ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"]

    static func bundleRelativePath(_ url: URL, root: URL) -> String? {
        // macOS enumeration can expand /var to /private/var even when the root
        // URL uses the shorter alias. Normalize both sides before comparison.
        let path = url.resolvingSymlinksInPath().path
        let prefix = root.resolvingSymlinksInPath().path + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    static func validateBundle(_ input: URL, _ version: String) throws {
        guard ownedUpdatePath(input, directory: true) else {
            throw appError("slock.Update", "The staged app is invalid.")
        }
        let app = input.resolvingSymlinksInPath()
        guard
              let enumerator = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil) else {
            throw appError("slock.Update", "The staged app is invalid.")
        }
        var files: Set<String> = []
        for case let url as URL in enumerator {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_uid == geteuid(),
                  info.st_mode & S_IFMT == S_IFDIR || (info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1) else {
                throw appError("slock.Update", "The staged app contains an unexpected link or special file.")
            }
            if info.st_mode & S_IFMT == S_IFREG {
                guard let relative = bundleRelativePath(url, root: app) else {
                    throw appError("slock.Update", "An update file is outside its app bundle.")
                }
                files.insert(relative)
            }
        }
        guard files == SignedUpdate.paths else {
            throw appError("slock.Update", "The staged app contains unexpected files.")
        }
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleShortVersionString"] as? String == version,
              FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/slock").path) else {
            throw appError("slock.Update", "The staged app does not match the expected release.")
        }
        let (status, _, _) = try runProcess("/usr/bin/codesign", ["--verify", "--strict", app.path])
        guard status == 0 else { throw appError("slock.Update", "The downloaded app failed its bundle integrity check.") }
    }

    static func stage(_ contents: SignedUpdate.Contents, in app: URL) throws {
        let fm = FileManager.default
        // Callers pass only verified contents; also enforce paths at this write boundary.
        guard contents.files.count == SignedUpdate.paths.count, Set(contents.files.map(\.path)) == SignedUpdate.paths else {
            throw appError("slock.Update", "Unexpected update files.")
        }
        guard !fm.fileExists(atPath: app.path) else { throw appError("slock.Update", "The update staging path already exists.") }
        for file in contents.files {
            let url = app.appendingPathComponent(file.path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            guard fm.createFile(atPath: url.path, contents: file.data,
                attributes: [.posixPermissions: file.path == "Contents/MacOS/slock" ? 0o755 : 0o644]) else {
                throw appError("slock.Update", "Could not stage the downloaded app.")
            }
        }
    }

    static func prepare(_ update: SlockUpdate, currentApp: URL, executable: URL,
                        status: @escaping (String) -> Void) async throws -> PreparedUpdate {
        let fm = FileManager.default
        let destination = currentApp.standardizedFileURL
        guard let url = update.packageURL, let next = ReleaseVersion(update.tag),
              let bundle = Bundle(url: destination), destination.pathExtension == "app",
              ownedUpdatePath(destination, directory: true),
              let current = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let old = ReleaseVersion(current), next > old,
              let encodedKey = bundle.object(forInfoDictionaryKey: "SlockUpdatePublicKey") as? String,
              let key = Data(base64Encoded: encodedKey), key.count == 32 else {
            throw appError("slock.Update", "Run the current slock.app from a writable Applications folder to update it.")
        }
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            ReleaseRequest.fetch(request, maximumBytes: SignedUpdate.maximumBytes, redirectHosts: assetHosts) { data, response, error in
                if let error { continuation.resume(throwing: error) }
                else if (response as? HTTPURLResponse)?.statusCode == 200, let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: appError("slock.Update", "The signed update is unavailable. Please try again later.")) }
            }
        }
        try Task.checkCancellation()
        status("Verifying update…")
        let contents = try SignedUpdate.verify(data, publicKey: key, expectedTag: update.tag)
        let directory = destination.deletingLastPathComponent().appendingPathComponent(".slock-update-\(UUID())")
        do { try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { throw appError("slock.Update", "slock cannot replace itself here. Move it to a writable Applications folder and try again.") }
        let prepared = PreparedUpdate(directory: directory, destination: destination,
                                      originalVersion: current, newVersion: contents.version)
        var keep = false
        defer { if !keep { try? fm.removeItem(at: directory) } }
        try stage(contents, in: prepared.app)
        try validateBundle(prepared.app, contents.version)
        try fm.copyItem(at: executable, to: prepared.helper)
        try Task.checkCancellation()
        keep = true
        return prepared
    }

    static func runHelperIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.dropFirst().first == "--slock-install-update" else { return false }
        guard args.count == 7, let parent = Int32(args[2]), parent > 1 else { return true }
        let prepared = PreparedUpdate(directory: URL(fileURLWithPath: args[3]), destination: URL(fileURLWithPath: args[4]),
                                      originalVersion: args[5], newVersion: args[6])
        do {
            try prepared.validateLayout()
            guard ownedUpdatePath(prepared.helper, directory: false),
                  Bundle.main.executableURL?.resolvingSymlinksInPath().path == prepared.helper.resolvingSymlinksInPath().path else {
                throw appError("slock.Update", "Only the staged local helper can install an update.")
            }
            let deadline = Date().addingTimeInterval(30)
            while kill(parent, 0) == 0 || errno == EPERM {
                guard Date() < deadline else { throw appError("slock.Update", "slock did not quit in time. Please try again.") }
                Thread.sleep(forTimeInterval: 0.1)
            }
            try prepared.install()
        } catch {
            NSApplication.shared.setActivationPolicy(.accessory)
            let alert = NSAlert()
            alert.messageText = "Could not update slock"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            // Keep staging on failure: it can contain the only previous copy.
        }
        return true
    }
}

final class AppUpdater: @unchecked Sendable {
    private(set) var status: String?
    var onChange: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onReadyToRelaunch: (() -> Void)?
    var onUpToDate: (() -> Void)?
    private var task: Task<Void, Never>?
    private var cancelled = false

    func checkAndInstall(using checker: UpdateChecker) {
        guard status == nil else { return }
        cancelled = false
        status = "Checking for updates…"
        onChange?()
        checker.checkNow { [weak self] result in
            guard let self, !self.cancelled else { return }
            switch result {
            case .failure(let error): self.failed(error)
            case .success(nil): self.status = nil; self.onChange?(); self.onUpToDate?()
            case .success(let update?): self.install(update)
            }
        }
    }

    private func install(_ update: SlockUpdate) {
        guard let executable = Bundle.main.executableURL else { return }
        status = "Downloading update…"
        onChange?()
        let app = Bundle.main.bundleURL
        task = Task.detached(priority: .utility) { [weak self] in
            do {
                let prepared = try await UpdateInstaller.prepare(update, currentApp: app, executable: executable) { text in
                    DispatchQueue.main.async { guard self?.cancelled == false else { return }; self?.status = text; self?.onChange?() }
                }
                DispatchQueue.main.async {
                    guard let self, !self.cancelled else { try? FileManager.default.removeItem(at: prepared.directory); return }
                    do {
                        try prepared.launchHelper()
                        self.status = "Restarting slock…"
                        self.onChange?()
                        self.onReadyToRelaunch?()
                    } catch {
                        try? FileManager.default.removeItem(at: prepared.directory)
                        self.failed(error)
                    }
                }
            } catch {
                DispatchQueue.main.async { guard self?.cancelled == false else { return }; self?.failed(error) }
            }
        }
    }

    func cancel() { cancelled = true; task?.cancel() }
    private func failed(_ error: Error) {
        status = nil
        task = nil
        onChange?()
        onError?(error)
    }
}
