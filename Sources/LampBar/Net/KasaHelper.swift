import Foundation

/// Runs `scripts/kasa-helper.py` (python-kasa) for plugs whose firmware needs a TP-Link login.
/// The login goes to the helper on stdin, never in arguments, so it does not show in `ps`.
struct KasaHelper: Sendable {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LampBar")
    static let python = directory.appendingPathComponent("kasa-venv/bin/python")
    static let script = directory.appendingPathComponent("kasa-helper.py")

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: python.path) && FileManager.default.fileExists(atPath: script.path)
    }

    enum HelperError: Error, CustomStringConvertible {
        case notInstalled
        case failed(String)

        var description: String {
            switch self {
            case .notInstalled: return "the Kasa login helper is not installed"
            case let .failed(reason): return "the Kasa login helper failed (\(reason))"
            }
        }
    }

    private struct Reply: Decodable {
        struct Outlet: Decodable {
            var deviceID: String
            var childID: String?
            var host: String
            var alias: String
            var deviceAlias: String
            var model: String
            var isOn: Bool
        }

        var outlets: [Outlet]?
        var error: String?
    }

    func discover(_ login: TPLinkCredentials) throws -> [KasaOutlet] {
        try run(["command": "discover", "targets": Network.broadcastAddresses()], login)
    }

    func setPower(_ on: Bool, outlet: KasaOutlet, _ login: TPLinkCredentials) throws {
        _ = try run(["command": "set", "host": outlet.host, "child": outlet.childID as Any, "on": on], login)
    }

    private func run(_ request: [String: Any], _ login: TPLinkCredentials) throws -> [KasaOutlet] {
        guard Self.isInstalled else { throw HelperError.notInstalled }
        var body = request
        body["username"] = login.username
        body["password"] = login.password
        let input = try JSONSerialization.data(withJSONObject: body)

        let process = Process()
        process.executableURL = Self.python
        process.arguments = ["-I", Self.script.path]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(input)
        try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let reply = try? JSONDecoder().decode(Reply.self, from: output) else { throw HelperError.failed("no reply") }
        if let error = reply.error { throw HelperError.failed(error) }
        return (reply.outlets ?? []).map {
            KasaOutlet(deviceID: $0.deviceID, childID: $0.childID, host: $0.host, alias: $0.alias,
                       deviceAlias: $0.deviceAlias, model: $0.model, isOn: $0.isOn, viaHelper: true)
        }
    }
}
