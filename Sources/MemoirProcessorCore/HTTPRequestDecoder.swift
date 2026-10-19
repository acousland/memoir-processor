import Foundation

public struct DecodedHTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data
    public let uploadURL: URL?
}

/// One request per connection. Upload bodies are spooled to disk, never accumulated in memory.
public final class HTTPRequestDecoder: @unchecked Sendable {
    public static let maximumUploadBytes = 1_073_741_824
    private var headerBytes = Data()
    private var head: (String, String, [String: String])?
    private var remaining = 0
    private var body = Data()
    private var file: FileHandle?
    private var temporaryURL: URL?
    private let authorize: @Sendable (String, String, [String: String]) throws -> Void

    public init(authorize: @escaping @Sendable (String, String, [String: String]) throws -> Void = { _, _, _ in }) {
        self.authorize = authorize
    }

    deinit {
        try? file?.close()
        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
    }

    public func append(_ bytes: Data) throws -> DecodedHTTPRequest? {
        var payload = bytes
        if head == nil {
            headerBytes.append(bytes)
            guard let separator = headerBytes.range(of: Data("\r\n\r\n".utf8)) else {
                guard headerBytes.count <= 16_384 else { throw failure("Headers are too large.") }
                return nil
            }
            guard separator.lowerBound <= 16_384,
                  let text = String(data: headerBytes[..<separator.lowerBound], encoding: .utf8) else { throw failure("Invalid headers.") }
            let lines = text.components(separatedBy: "\r\n")
            let parts = lines[0].split(separator: " ")
            guard parts.count == 3, parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0",
                  parts[1].hasPrefix("/"), !parts[1].contains("%"), !parts[1].contains("?") else { throw failure("Invalid request line.") }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { throw failure("Invalid header.") }
                let key = line[..<colon].lowercased()
                guard !key.isEmpty, headers[key] == nil else { throw failure("Duplicate header.") }
                headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard headers["transfer-encoding"] == nil else { throw failure("Chunked requests are not supported.") }
            let rawLength = headers["content-length"] ?? "0"
            guard !rawLength.isEmpty, rawLength.utf8.allSatisfy({ (48...57).contains($0) }),
                  let length = Int(rawLength), length <= Self.maximumUploadBytes else { throw failure("Invalid or excessive Content-Length.") }
            let method = String(parts[0]), path = String(parts[1])
            guard method == "PUT" || length <= 1_048_576 else { throw failure("JSON body is too large.") }
            try authorize(method, path, headers)
            head = (method, path, headers)
            remaining = length
            if method == "PUT" {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("memoir-upload-" + UUID().uuidString)
                guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw failure("Cannot create upload spool.") }
                temporaryURL = url
                file = try FileHandle(forWritingTo: url)
            }
            payload = Data(headerBytes[separator.upperBound...])
            headerBytes.removeAll(keepingCapacity: false)
        }
        guard payload.count <= remaining else { throw failure("Body exceeds declared length.") }
        if let file { try file.write(contentsOf: payload) } else { body.append(payload) }
        remaining -= payload.count
        guard remaining == 0, let (method, path, headers) = head else { return nil }
        try file?.close()
        file = nil
        return DecodedHTTPRequest(method: method, path: path, headers: headers, body: body, uploadURL: temporaryURL)
    }

    private func failure(_ message: String) -> ProcessorError {
        ProcessorError(code: "invalid_request", message: message, retryable: false)
    }
}
