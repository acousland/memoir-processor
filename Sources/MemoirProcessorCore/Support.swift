import CryptoKit
import Foundation
import Security

#if canImport(Darwin)
import Darwin
#endif

public enum Time {
    private static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    public static func nowString() -> String {
        formatter().string(from: Date())
    }
}

public enum ProcessorPaths {
    public static func root(for config: AppConfig) -> URL {
        URL(fileURLWithPath: config.storageRoot, isDirectory: true)
    }

    public static func configURL(for config: AppConfig) -> URL {
        root(for: config).appendingPathComponent("config.json")
    }

    public static func databaseURL(for config: AppConfig) -> URL {
        root(for: config).appendingPathComponent("processor.sqlite3")
    }

    public static func sessionsDirectory(for config: AppConfig) -> URL {
        root(for: config).appendingPathComponent("sessions", isDirectory: true)
    }

    public static func sessionDirectory(for config: AppConfig, sessionID: String) -> URL {
        sessionsDirectory(for: config).appendingPathComponent(UUID(uuidString: sessionID) == nil ? "invalid-session" : sessionID, isDirectory: true)
    }

    public static func processingDirectory(for config: AppConfig, sessionID: String) -> URL {
        sessionDirectory(for: config, sessionID: sessionID).appendingPathComponent("processing", isDirectory: true)
    }

    public static func workDirectory(for config: AppConfig, sessionID: String) -> URL {
        processingDirectory(for: config, sessionID: sessionID).appendingPathComponent("work", isDirectory: true)
    }

    public static func runtimeDirectory(for config: AppConfig) -> URL {
        root(for: config).appendingPathComponent("runtime", isDirectory: true)
    }

    public static func whisperModelDirectory(for config: AppConfig, model: String) -> URL {
        runtimeDirectory(for: config).appendingPathComponent("whisperkit/\(model)", isDirectory: true)
    }

    public static func diarizationRuntimeDirectory(for config: AppConfig) -> URL {
        runtimeDirectory(for: config).appendingPathComponent("diarization", isDirectory: true)
    }

    public static func speakerSamplesDirectory(for config: AppConfig, sessionID: String) -> URL {
        processingDirectory(for: config, sessionID: sessionID).appendingPathComponent("speaker_samples", isDirectory: true)
    }

    public static func logsURL(for config: AppConfig, sessionID: String) -> URL {
        processingDirectory(for: config, sessionID: sessionID).appendingPathComponent("logs.txt")
    }

    public static func metadataURL(for config: AppConfig, sessionID: String) -> URL {
        sessionDirectory(for: config, sessionID: sessionID).appendingPathComponent("metadata.json")
    }

    public static func audioURL(for config: AppConfig, sessionID: String, kind: UploadFileKind) -> URL {
        sessionDirectory(for: config, sessionID: sessionID).appendingPathComponent(kind.fileName)
    }

    public static func tlsDirectory(for config: AppConfig) -> URL {
        root(for: config).appendingPathComponent("tls", isDirectory: true)
    }

    public static func tlsCertificateURL(for config: AppConfig) -> URL {
        tlsDirectory(for: config).appendingPathComponent("server.crt")
    }

    public static func tlsPrivateKeyURL(for config: AppConfig) -> URL {
        tlsDirectory(for: config).appendingPathComponent("server.key")
    }

    public static func tlsIdentityURL(for config: AppConfig) -> URL {
        tlsDirectory(for: config).appendingPathComponent("server.p12")
    }

    public static func tlsOpenSSLConfigURL(for config: AppConfig) -> URL {
        tlsDirectory(for: config).appendingPathComponent("openssl.cnf")
    }
}

public final class ConfigStore: @unchecked Sendable {
    private let fileManager = FileManager.default
    private let configURL: URL

    public init(configURL: URL? = nil) {
        let defaultConfig = AppConfig.default()
        self.configURL = configURL ?? ProcessorPaths.root(for: defaultConfig).appendingPathComponent("config.json")
    }

    public func load() throws -> AppConfig {
        if !fileManager.fileExists(atPath: configURL.path) {
            let config = AppConfig.default()
            try save(config)
            return config
        }

        let data = try Data(contentsOf: configURL)
        let decoded = try JSONDecoder.memoir.decode(AppConfig.self, from: data)
        if decoded.authToken.isEmpty {
            guard let token = SecretStore.read(account: secretAccount), !token.isEmpty else {
                throw ProcessorError(code: "configuration_invalid", message: "Processor API token is missing from Keychain.", retryable: false)
            }
            return decoded.updating(authToken: token)
        }
        try save(decoded)
        return decoded
    }

    private var secretAccount: String { "processor-api-" + Hashing.sha256Hex(for: Data(configURL.path.utf8)) }

    public func save(_ config: AppConfig) throws {
        try fileManager.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SecretStore.write(config.authToken, account: secretAccount)
        let data = try JSONEncoder.memoir.encode(config.updating(authToken: ""))
        try data.write(to: configURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }
}

extension JSONEncoder {
    public static var memoir: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    public static var memoir: JSONDecoder {
        JSONDecoder()
    }
}

public enum Hashing {
    public static func sha256Hex(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public extension FileManager {
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories, attributes: nil)
    }
}

public enum NetworkEnvironment {
    public static func localIPv4Addresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return addresses
        }
        defer { freeifaddrs(ifaddr) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            let flags = Int32(interface.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            guard isUp, interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(interface.ifa_addr.pointee.sa_len)
            let result = getnameinfo(
                interface.ifa_addr,
                length,
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let address = String(decoding: hostBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !isLoopback {
                addresses.append(address)
            }
        }

        return Array(Set(addresses)).sorted()
    }
}

public enum TailscaleEnvironment {
    private struct Status: Decodable {
        struct SelfNode: Decodable {
            let dnsName: String?

            enum CodingKeys: String, CodingKey {
                case dnsName = "DNSName"
            }
        }

        let backendState: String?
        let selfNode: SelfNode?

        enum CodingKeys: String, CodingKey {
            case backendState = "BackendState"
            case selfNode = "Self"
        }
    }

    public static func dnsName() -> String? {
        let binaryURL = URL(fileURLWithPath: "/Applications/Tailscale.app/Contents/MacOS/Tailscale")
        guard FileManager.default.fileExists(atPath: binaryURL.path) else { return nil }

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = ["status", "--json"]
        process.environment = ProcessInfo.processInfo.environment.merging(["TAILSCALE_BE_CLI": "1"]) { _, value in value }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard
            let status = try? JSONDecoder().decode(Status.self, from: data),
            status.backendState == "Running",
            let dnsName = status.selfNode?.dnsName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !dnsName.isEmpty
        else {
            return nil
        }

        return dnsName.hasSuffix(".") ? String(dnsName.dropLast()) : dnsName
    }
}

public struct RuntimeDependencyStatus: Sendable {
    public let appleSiliconAvailable: Bool
    public let pythonAvailable: Bool
    public let whisperKitConfigured: Bool
    public let diarizationInstalled: Bool
    public let ffmpegAvailable: Bool
    public let mpsAvailable: Bool
    public let huggingFaceTokenConfigured: Bool

    public var isReadyForTranscription: Bool {
        appleSiliconAvailable && whisperKitConfigured
    }

    public var diarizationRuntimeLabel: String {
        if !diarizationInstalled {
            return "Missing"
        }
        return mpsAvailable ? "MPS" : "CPU fallback"
    }

    public init(
        appleSiliconAvailable: Bool,
        pythonAvailable: Bool,
        whisperKitConfigured: Bool,
        diarizationInstalled: Bool,
        ffmpegAvailable: Bool,
        mpsAvailable: Bool,
        huggingFaceTokenConfigured: Bool
    ) {
        self.appleSiliconAvailable = appleSiliconAvailable
        self.pythonAvailable = pythonAvailable
        self.whisperKitConfigured = whisperKitConfigured
        self.diarizationInstalled = diarizationInstalled
        self.ffmpegAvailable = ffmpegAvailable
        self.mpsAvailable = mpsAvailable
        self.huggingFaceTokenConfigured = huggingFaceTokenConfigured
    }
}

public final class RuntimeDependencyManager: @unchecked Sendable {
    private let pythonURL = URL(fileURLWithPath: "/usr/bin/python3")
    private let brewURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
    private let ffmpegCandidatePaths = [
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/usr/bin/ffmpeg"
    ]
    private let keychainService = "com.memoir.processor"
    private let keychainAccount = "huggingface-token"

    public init() {}

    public func currentStatus(config: AppConfig) -> RuntimeDependencyStatus {
        let appleSiliconAvailable = ProcessInfo.processInfo.machineHardwareName == "arm64"
        let pythonAvailable = FileManager.default.fileExists(atPath: pythonURL.path)
        let whisperKitConfigured = FileManager.default.fileExists(atPath: ProcessorPaths.whisperModelDirectory(for: config, model: config.modelName).path)
        let runtimePython = diarizationPythonURL(config: config)
        let diarizationInstalled = FileManager.default.fileExists(atPath: runtimePython.path) && (try? SubprocessRunner.run(executable: runtimePython, arguments: ["-c", "import torch, torchaudio, pyannote.audio"], timeout: 60).status) == 0
        let ffmpegAvailable = ffmpegCandidatePaths.contains { FileManager.default.fileExists(atPath: $0) }
        let mpsAvailable = diarizationInstalled && (try? SubprocessRunner.run(executable: runtimePython, arguments: ["-c", "import torch; raise SystemExit(0 if torch.backends.mps.is_available() else 1)"], timeout: 60).status) == 0
        return RuntimeDependencyStatus(
            appleSiliconAvailable: appleSiliconAvailable,
            pythonAvailable: pythonAvailable,
            whisperKitConfigured: whisperKitConfigured,
            diarizationInstalled: diarizationInstalled,
            ffmpegAvailable: ffmpegAvailable,
            mpsAvailable: mpsAvailable,
            huggingFaceTokenConfigured: huggingFaceToken() != nil
        )
    }

    public func ensureWhisperModelDirectory(config: AppConfig) throws {
        let modelDirectory = ProcessorPaths.whisperModelDirectory(for: config, model: config.modelName)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
    }

    public func diarizationPythonURL(config: AppConfig) -> URL {
        ProcessorPaths.diarizationRuntimeDirectory(for: config).appendingPathComponent("venv/bin/python3")
    }

    public func installDiarizationRuntime(config: AppConfig) throws {
        let candidates = ["/opt/homebrew/bin/python3.11", "/usr/local/bin/python3.11", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/python3.11").path]
        guard let interpreter = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw ProcessorError(code: "python_missing", message: "Install Python 3.11 with Homebrew (brew install python@3.11), then retry.", retryable: false)
        }
        let root = ProcessorPaths.diarizationRuntimeDirectory(for: config)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let creation = try SubprocessRunner.run(executable: URL(fileURLWithPath: interpreter), arguments: ["-m", "venv", root.appendingPathComponent("venv").path], timeout: 120)
        guard creation.status == 0 else { throw ProcessorError(code: "runtime_install_failed", message: "Unable to create isolated Python environment.", retryable: false) }
        let requirements = Bundle.main.resourceURL?.appendingPathComponent("worker/requirements-lock.txt")
        let requirementsURL = requirements.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("worker/requirements-lock.txt")
        let result = try SubprocessRunner.run(executable: diarizationPythonURL(config: config), arguments: ["-m", "pip", "install", "-r", requirementsURL.path], timeout: 1800)
        guard result.status == 0 else { throw ProcessorError(code: "runtime_install_failed", message: String(data: result.error, encoding: .utf8) ?? "Runtime installation failed.", retryable: true) }
    }

    public func installFFmpeg() throws {
        guard FileManager.default.fileExists(atPath: brewURL.path) else {
            throw ProcessorError(code: "brew_missing", message: "Homebrew is required to install ffmpeg automatically. Install Homebrew or add ffmpeg to PATH manually.", retryable: false)
        }

        let result = try SubprocessRunner.run(executable: brewURL, arguments: ["install", "ffmpeg"], timeout: 1800)
        guard result.status == 0 else { throw ProcessorError(code: "runtime_install_failed", message: String(data: result.error, encoding: .utf8) ?? "ffmpeg installation failed.", retryable: true) }
    }

    public func saveHuggingFaceToken(_ token: String?) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]

        SecItemDelete(baseQuery as CFDictionary)

        guard let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = Data(token.utf8)
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ProcessorError(code: "keychain_write_failed", message: "Failed to store the Hugging Face token in Keychain.", retryable: false)
        }
    }

    public func huggingFaceToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func runPython(arguments: [String], allowFailure: Bool) -> (terminationStatus: Int32, output: String) {
        let process = Process()
        process.executableURL = pythonURL
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (1, error.localizedDescription)
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile() + stderr.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        if !allowFailure && process.terminationStatus != 0 {
            return (process.terminationStatus, output.isEmpty ? "Python command failed." : output)
        }
        return (process.terminationStatus, output)
    }
}

private extension ProcessInfo {
    var machineHardwareName: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(decoding: machine.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

public final class TLSMaterialManager: @unchecked Sendable {
    public init() {}

    public func ensureFiles(for config: AppConfig) throws -> (certificateURL: URL, privateKeyURL: URL)? {
        guard config.tlsEnabled else { return nil }

        let fileManager = FileManager.default
        let tlsDirectory = ProcessorPaths.tlsDirectory(for: config)
        try fileManager.createDirectory(at: tlsDirectory, withIntermediateDirectories: true)

        let certURL = ProcessorPaths.tlsCertificateURL(for: config)
        let keyURL = ProcessorPaths.tlsPrivateKeyURL(for: config)
        if !fileManager.fileExists(atPath: certURL.path) || !fileManager.fileExists(atPath: keyURL.path) {
            try generateMaterials(for: config)
        }

        return (certURL, keyURL)
    }

    private func generateMaterials(for config: AppConfig) throws {
        let tlsDirectory = ProcessorPaths.tlsDirectory(for: config)
        let configURL = ProcessorPaths.tlsOpenSSLConfigURL(for: config)
        let certURL = ProcessorPaths.tlsCertificateURL(for: config)
        let keyURL = ProcessorPaths.tlsPrivateKeyURL(for: config)

        let hostname = Host.current().localizedName?.replacingOccurrences(of: " ", with: "-").lowercased() ?? "memoir-processor"
        let fallbackSubjectName = "\(hostname).local"
        let tailscaleDNSName = TailscaleEnvironment.dnsName()
        let subjectName = tailscaleDNSName ?? fallbackSubjectName
        let ipAddresses = ["127.0.0.1"] + NetworkEnvironment.localIPv4Addresses()
        var altNames = [
            "DNS.1 = localhost",
            "DNS.2 = \(fallbackSubjectName)"
        ]
        if let tailscaleDNSName {
            altNames.append("DNS.\(altNames.count + 1) = \(tailscaleDNSName)")
        }
        for (index, ip) in Array(Set(ipAddresses)).sorted().enumerated() {
            altNames.append("IP.\(index + 1) = \(ip)")
        }

        let opensslConfig = """
        [req]
        default_bits = 2048
        prompt = no
        default_md = sha256
        distinguished_name = dn
        x509_extensions = v3_req

        [dn]
        CN = \(subjectName)

        [v3_req]
        subjectAltName = @alt_names
        extendedKeyUsage = serverAuth

        [alt_names]
        \(altNames.joined(separator: "\n"))
        """
        try opensslConfig.write(to: configURL, atomically: true, encoding: .utf8)

        try runOpenSSL(arguments: [
            "req", "-x509", "-nodes", "-newkey", "rsa:2048",
            "-keyout", keyURL.path,
            "-out", certURL.path,
            "-days", "825",
            "-config", configURL.path
        ], in: tlsDirectory)
    }

    private func runOpenSSL(arguments: [String], in workingDirectory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let output = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "OpenSSL failed."
            throw ProcessorError(code: "tls_generation_failed", message: output, retryable: false)
        }
    }
}

public extension ISO8601DateFormatter {
    static func memoirTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
