import CryptoKit
import Foundation

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
        sessionsDirectory(for: config).appendingPathComponent(sessionID, isDirectory: true)
    }

    public static func processingDirectory(for config: AppConfig, sessionID: String) -> URL {
        sessionDirectory(for: config, sessionID: sessionID).appendingPathComponent("processing", isDirectory: true)
    }

    public static func workDirectory(for config: AppConfig, sessionID: String) -> URL {
        processingDirectory(for: config, sessionID: sessionID).appendingPathComponent("work", isDirectory: true)
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
        return try JSONDecoder.memoir.decode(AppConfig.self, from: data)
    }

    public func save(_ config: AppConfig) throws {
        try fileManager.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.memoir.encode(config)
        try data.write(to: configURL, options: .atomic)
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
            let address = String(cString: hostBuffer)
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
