import CryptoKit
import Foundation

@main enum SignUpdate {
    static func main() {
        do { try run() }
        catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }

    static func run() throws {
        let args = CommandLine.arguments
        let fm = FileManager.default
        if args.count == 3, args[1] == "--generate-key" {
            let path = URL(fileURLWithPath: args[2])
            guard !fm.fileExists(atPath: path.path) else {
                throw appError("slock.Release", "Refusing to replace an existing update-signing key.")
            }
            try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let key = Curve25519.Signing.PrivateKey()
            guard fm.createFile(atPath: path.path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                attributes: [.posixPermissions: 0o600]) else {
                throw appError("slock.Release", "Could not save the signing key.")
            }
            print(key.publicKey.rawRepresentation.base64EncodedString())
            return
        }
        guard args.count == 3 else { throw appError("slock.Release", "Usage: sign-update app-path output.json") }
        let app = URL(fileURLWithPath: args[1])
        let info = try PropertyListSerialization.propertyList(from:
            Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as! [String: Any]
        // Signing stays local: no Keychain, CI secret, or private key in logs.
        let path = URL(fileURLWithPath: ".release-signing/update.key")
        guard ownedUpdatePath(path, directory: false) else {
            throw appError("slock.Release", "Missing local update-signing key.")
        }
        let encoded = try String(contentsOf: path, encoding: .utf8)
        guard let seed = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw appError("slock.Release", "Invalid update-signing key encoding.")
        }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        guard info["SlockUpdatePublicKey"] as? String == key.publicKey.rawRepresentation.base64EncodedString() else {
            throw appError("slock.Release", "Signing key does not match the public key embedded in the app.")
        }
        let version = info["CFBundleShortVersionString"] as! String
        try UpdateInstaller.validateBundle(app, version)
        let files = try SignedUpdate.paths.sorted().map { path in
            SignedUpdate.File(path: path, data: try Data(contentsOf: app.appendingPathComponent(path)))
        }
        let contents = SignedUpdate.Contents(format: 1, version: version,
                                             build: info["CFBundleVersion"] as! String, files: files)
        let payload = try JSONEncoder().encode(contents)
        let output = try JSONEncoder().encode(SignedUpdate(payload: payload, signature: key.signature(for: payload)))
        let verified = try SignedUpdate.verify(output, publicKey: key.publicKey.rawRepresentation, expectedTag: "v" + version)
        let scratch = fm.temporaryDirectory.appendingPathComponent("slock-update-verify-\(UUID())")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }
        let reconstructed = scratch.appendingPathComponent("slock.app")
        try UpdateInstaller.stage(verified, in: reconstructed)
        try UpdateInstaller.validateBundle(reconstructed, version)
        try output.write(to: URL(fileURLWithPath: args[2]), options: .atomic)
        print("Signed and verified v\(version) update (\(output.count) bytes)")
    }
}
