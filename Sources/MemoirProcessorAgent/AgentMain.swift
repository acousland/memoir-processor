import Foundation
import MemoirProcessorCore
import Network
import Darwin

actor QueueCoordinator {
    private let store: SessionStore
    private let validator: SessionValidator
    private let normalizer: AudioNormalizer
    private let worker: PythonTranscriptionWorker
    private let config: AppConfig
    private var isRunning = false

    init(store: SessionStore, validator: SessionValidator, normalizer: AudioNormalizer, worker: PythonTranscriptionWorker, config: AppConfig) {
        self.store = store
        self.validator = validator
        self.normalizer = normalizer
        self.worker = worker
        self.config = config
    }

    func startRecovery() async {
        do {
            try store.recoverIncompleteSessions()
            await kick()
        } catch {
            fputs("Recovery failed: \(error)\n", stderr)
        }
    }

    func kick() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        while true {
            let nextSession = try? store.nextRunnableSession()
            guard let sessionID = nextSession ?? nil else { break }
            do {
                try stopIfRequested(sessionID: sessionID)
                try store.setProcessingState(sessionID: sessionID, state: .validating)
                try store.appendLog(sessionID: sessionID, line: "Validation started.")
                let validation = try validator.validate(sessionID: sessionID)
                try stopIfRequested(sessionID: sessionID)
                let normalizedURL = try normalizer.normalizedAudioURL(for: sessionID, sourceURL: validation.systemAudioURL)

                try store.setProcessingState(sessionID: sessionID, state: .transcribing)
                try store.appendLog(sessionID: sessionID, line: "Transcription started.")
                let transcriptResult = try worker.transcribe(
                    audioURL: normalizedURL,
                    sessionID: sessionID,
                    config: config,
                    languageHint: validation.metadata.languageHint ?? config.languageHint,
                    onStart: { pid in
                        try? self.store.setWorkerPID(sessionID: sessionID, pid: pid)
                    }
                )
                try store.setWorkerPID(sessionID: sessionID, pid: nil)
                try stopIfRequested(sessionID: sessionID)
                let sourceFiles = validation.micAudioURL == nil ? ["system": "system.wav"] : ["system": "system.wav", "mic": "mic.wav"]
                let transcript = CanonicalTranscript(
                    sessionID: sessionID,
                    sourceFiles: sourceFiles,
                    transcription: TranscriptionMetadata(engine: transcriptResult.engine, model: transcriptResult.model, language: transcriptResult.language),
                    segments: transcriptResult.segments
                )

                try store.setProcessingState(sessionID: sessionID, state: .writingArtifacts)
                try store.writeTranscriptArtifacts(sessionID: sessionID, transcript: transcript)
                try store.appendLog(sessionID: sessionID, line: "Artifacts written.")
                try store.setProcessingState(sessionID: sessionID, state: .completed)
            } catch let error as ProcessorError {
                try? store.setWorkerPID(sessionID: sessionID, pid: nil)
                if error.code == "session_not_found" {
                    continue
                }
                if (try? store.isStopRequested(sessionID: sessionID)) == true || error.code == "session_stopped" {
                    worker.stopCurrentProcess()
                    try? store.markStopped(sessionID: sessionID)
                } else {
                    try? store.appendLog(sessionID: sessionID, line: "Processing failed: \(error.message)")
                    try? store.markRetryPending(sessionID: sessionID, error: error)
                }
            } catch {
                try? store.setWorkerPID(sessionID: sessionID, pid: nil)
                let processorError = ProcessorError(code: "internal_error", message: error.localizedDescription, retryable: true)
                try? store.appendLog(sessionID: sessionID, line: "Processing failed: \(processorError.message)")
                try? store.markRetryPending(sessionID: sessionID, error: processorError)
            }
        }
    }

    private func stopIfRequested(sessionID: String) throws {
        if try store.isStopRequested(sessionID: sessionID) {
            throw ProcessorError(code: "session_stopped", message: "Processing was stopped by the operator.", retryable: false)
        }
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

struct HTTPResponse {
    let statusCode: Int
    let body: Data
    let contentType: String

    init(statusCode: Int, body: Data = Data(), contentType: String = "application/json") {
        self.statusCode = statusCode
        self.body = body
        self.contentType = contentType
    }
}

final class SimpleHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "MemoirProcessor.HTTPServer")
    private let handler: (HTTPRequest) async -> HTTPResponse

    init(host: String, port: UInt16, handler: @escaping (HTTPRequest) async -> HTTPResponse) throws {
        self.handler = handler
        let parameters = NWParameters.tcp
        let endpointPort = NWEndpoint.Port(rawValue: port)!
        if host != "0.0.0.0" {
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: endpointPort)
            listener = try NWListener(using: parameters)
        } else {
            listener = try NWListener(using: parameters, on: endpointPort)
        }
        listener.service = NWListener.Service(name: "memoir-processor", type: "_memoir._tcp")
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection: connection)
        }
    }

    func start() {
        listener.start(queue: queue)
        dispatchMain()
    }

    private func accept(connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receive(on: connection, accumulated: Data())
            case .failed(let error):
                fputs("Connection failed: \(error)\n", stderr)
                connection.cancel()
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let error {
                fputs("Receive error: \(error)\n", stderr)
                connection.cancel()
                return
            }

            var data = accumulated
            if let content { data.append(content) }
            if let request = Self.parseRequest(from: data) {
                Task {
                    let response = await self.handler(request)
                    self.send(response: response, on: connection)
                }
                return
            }

            if isComplete {
                let response = Self.jsonResponse(status: 400, error: ProcessorError(code: "invalid_request", message: "Incomplete HTTP request.", retryable: false))
                self.send(response: response, on: connection)
                return
            }

            self.receive(on: connection, accumulated: data)
        }
    }

    private func send(response: HTTPResponse, on connection: NWConnection) {
        let statusText = Self.reasonPhrase(for: response.statusCode)
        var headerText = "HTTP/1.1 \(response.statusCode) \(statusText)\r\n"
        headerText += "Content-Type: \(response.contentType)\r\n"
        headerText += "Content-Length: \(response.body.count)\r\n"
        headerText += "Connection: close\r\n\r\n"
        let headerData = Data(headerText.utf8)
        let packet = headerData + response.body
        connection.send(content: packet, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func parseRequest(from data: Data) -> HTTPRequest? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }

        let headerData = data.subdata(in: 0..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let name = line[..<separatorIndex].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespaces)
            headers[name.lowercased()] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else {
            return nil
        }
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        return HTTPRequest(
            method: String(requestParts[0]),
            path: String(requestParts[1]),
            headers: headers,
            body: body
        )
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 201: return "Created"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 422: return "Unprocessable Entity"
        default: return "Internal Server Error"
        }
    }

    static func jsonResponse<T: Encodable>(status: Int, value: T) -> HTTPResponse {
        let body = (try? JSONEncoder.memoir.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(statusCode: status, body: body)
    }

    static func jsonResponse(status: Int, error: ProcessorError) -> HTTPResponse {
        jsonResponse(status: status, value: ErrorEnvelope(error: error))
    }
}

final class HTTPSProxyManager {
    private let process = Process()
    private let pidFileURL: URL
    private let proxyScriptURL: URL

    init(config: AppConfig, certificateURL: URL, privateKeyURL: URL, listenPort: Int, targetPort: Int) throws {
        self.pidFileURL = ProcessorPaths.tlsDirectory(for: config).appendingPathComponent("https-proxy.pid")
        let bundledProxyScript = Bundle.main.resourceURL?.appendingPathComponent("proxy/https_proxy.py")
        if let bundledProxyScript, FileManager.default.fileExists(atPath: bundledProxyScript.path) {
            self.proxyScriptURL = bundledProxyScript
        } else {
            self.proxyScriptURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("proxy/https_proxy.py")
        }
        try terminateExistingProxyIfNeeded()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            proxyScriptURL.path,
            "--bind-host", config.bindHost,
            "--listen-port", String(listenPort),
            "--target-host", "localhost",
            "--target-port", String(targetPort),
            "--cert", certificateURL.path,
            "--key", privateKeyURL.path,
            "--pid-file", pidFileURL.path
        ]
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
    }

    func start() throws {
        try process.run()
    }

    private func terminateExistingProxyIfNeeded() throws {
        var pids = Set<Int32>()
        if let pidString = try? String(contentsOf: pidFileURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(pidString),
           pid > 0 {
            pids.insert(pid)
        }
        pids.formUnion(runningProxyPIDs())

        for pid in pids where pid > 0 {
            if kill(pid, SIGTERM) == 0 {
                for _ in 0..<20 {
                    if kill(pid, 0) != 0 {
                        break
                    }
                    usleep(100_000)
                }
                if kill(pid, 0) == 0 {
                    _ = kill(pid, SIGKILL)
                }
            }
        }
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    private func runningProxyPIDs() -> Set<Int32> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", proxyScriptURL.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return Set(
            text.split(whereSeparator: \.isNewline)
                .compactMap { Int32($0) }
                .filter { $0 != getpid() }
        )
    }
}

@main
enum MemoirProcessorAgentMain {
    static func main() throws {
        let config = try ConfigStore().load()
        let store = try SessionStore(config: config)
        let listenPort = config.tlsEnabled ? config.port + 1 : config.port
        let proxyManager: HTTPSProxyManager?
        if let tlsFiles = try TLSMaterialManager().ensureFiles(for: config) {
            let manager = try HTTPSProxyManager(
                config: config,
                certificateURL: tlsFiles.certificateURL,
                privateKeyURL: tlsFiles.privateKeyURL,
                listenPort: config.port,
                targetPort: listenPort
            )
            try manager.start()
            proxyManager = manager
        } else {
            proxyManager = nil
        }
        let queue = QueueCoordinator(
            store: store,
            validator: SessionValidator(config: config),
            normalizer: AudioNormalizer(config: config),
            worker: PythonTranscriptionWorker(scriptURL: resolveWorkerScript()),
            config: config
        )
        Task { await queue.startRecovery() }

        let server = try SimpleHTTPServer(host: config.tlsEnabled ? "127.0.0.1" : config.bindHost, port: UInt16(listenPort)) { request in
            await handle(request: request, config: config, store: store, queue: queue)
        }
        withExtendedLifetime(proxyManager) {
            server.start()
        }
    }

    static func resolveWorkerScript() -> URL {
        let bundlePath = Bundle.main.resourceURL?.appendingPathComponent("worker/transcribe.py")
        if let bundlePath, FileManager.default.fileExists(atPath: bundlePath.path) {
            return bundlePath
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("worker/transcribe.py")
    }

    static func handle(request: HTTPRequest, config: AppConfig, store: SessionStore, queue: QueueCoordinator) async -> HTTPResponse {
        do {
            if request.method == "GET", request.path == "/health" {
                return SimpleHTTPServer.jsonResponse(status: 200, value: ["status": "ok", "service": "memoir-processor", "api_version": "1"])
            }

            try authorize(request: request, config: config)

            if request.method == "POST", request.path == "/v1/sessions" {
                let body = try JSONDecoder.memoir.decode(CreateSessionRequest.self, from: request.body)
                let idempotencyKey = try requiredHeader("idempotency-key", in: request)
                let (response, status) = try store.createSession(body, idempotencyKey: idempotencyKey, baseURL: "")
                return SimpleHTTPServer.jsonResponse(status: status, value: response)
            }

            if request.method == "GET", let sessionID = pathComponent(after: "/v1/sessions/", in: request.path) {
                return SimpleHTTPServer.jsonResponse(status: 200, value: try store.fetchStatus(sessionID: sessionID))
            }

            if request.method == "PUT", request.path.contains("/files/") {
                let parts = request.path.split(separator: "/")
                guard parts.count == 5 else {
                    throw ProcessorError(code: "invalid_request", message: "Invalid upload path.", retryable: false)
                }
                let sessionID = String(parts[2])
                guard let kind = UploadFileKind(rawValue: String(parts[4])) else {
                    throw ProcessorError(code: "invalid_request", message: "Invalid file kind.", retryable: false)
                }
                let checksum = try requiredHeader("x-content-sha256", in: request)
                let response = try store.saveUpload(sessionID: sessionID, kind: kind, body: request.body, headerChecksum: checksum)
                return SimpleHTTPServer.jsonResponse(status: 200, value: response)
            }

            if request.method == "POST", request.path.hasSuffix("/complete") {
                let parts = request.path.split(separator: "/")
                guard parts.count == 4 else {
                    throw ProcessorError(code: "invalid_request", message: "Invalid complete path.", retryable: false)
                }
                let sessionID = String(parts[2])
                let idempotencyKey = try requiredHeader("idempotency-key", in: request)
                let body = try JSONDecoder.memoir.decode(CompleteSessionRequest.self, from: request.body)
                let (response, status) = try store.completeSession(sessionID: sessionID, request: body, idempotencyKey: idempotencyKey)
                Task { await queue.kick() }
                return SimpleHTTPServer.jsonResponse(status: status, value: response)
            }

            return SimpleHTTPServer.jsonResponse(status: 404, error: ProcessorError(code: "invalid_request", message: "Route not found.", retryable: false))
        } catch let error as ProcessorError {
            return SimpleHTTPServer.jsonResponse(status: status(for: error), error: error)
        } catch {
            return SimpleHTTPServer.jsonResponse(status: 500, error: ProcessorError(code: "internal_error", message: error.localizedDescription, retryable: true))
        }
    }

    static func authorize(request: HTTPRequest, config: AppConfig) throws {
        guard request.headers["x-memoir-api-version"] == "1" else {
            throw ProcessorError(code: "unsupported_api_version", message: "Unsupported API version.", retryable: false)
        }

        let expected = "Bearer \(config.authToken)"
        guard request.headers["authorization"] == expected else {
            throw ProcessorError(code: "unauthorized", message: "Unauthorized.", retryable: false)
        }
    }

    static func requiredHeader(_ name: String, in request: HTTPRequest) throws -> String {
        guard let value = request.headers[name.lowercased()], !value.isEmpty else {
            throw ProcessorError(code: "invalid_request", message: "\(name) header is required.", retryable: false)
        }
        return value
    }

    static func pathComponent(after prefix: String, in path: String) -> String? {
        guard path.hasPrefix(prefix) else { return nil }
        let remainder = String(path.dropFirst(prefix.count))
        guard !remainder.isEmpty, !remainder.contains("/") else { return nil }
        return remainder
    }

    static func status(for error: ProcessorError) -> Int {
        switch error.code {
        case "unauthorized":
            return 401
        case "session_not_found":
            return 404
        case "invalid_metadata":
            return 422
        case "session_conflict", "missing_required_file", "checksum_mismatch", "unexpected_file", "file_conflict":
            return 409
        default:
            return 400
        }
    }
}
