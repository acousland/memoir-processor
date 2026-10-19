import Foundation
import MemoirProcessorCore
import Network
import Darwin

actor QueueCoordinator {
    private let store: SessionStore
    private var validator: SessionValidator
    private let normalizer: AudioNormalizer
    private let transcriptionWorker: WhisperKitTranscriptionWorker
    private let diarizationWorker: LocalDiarizationWorker
    private var config: AppConfig
    private let selectionConfigURL: URL?
    private let runtimeDependencyManager = RuntimeDependencyManager()
    private var isRunning = false

    init(
        store: SessionStore,
        validator: SessionValidator,
        normalizer: AudioNormalizer,
        transcriptionWorker: WhisperKitTranscriptionWorker,
        diarizationWorker: LocalDiarizationWorker,
        config: AppConfig,
        selectionConfigURL: URL? = nil
    ) {
        self.store = store
        self.validator = validator
        self.normalizer = normalizer
        self.transcriptionWorker = transcriptionWorker
        self.diarizationWorker = diarizationWorker
        self.config = config
        self.selectionConfigURL = selectionConfigURL
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
            let nextSession = try? store.claimNextRunnableSession()
            guard let sessionID = nextSession ?? nil else { break }
            do {
                // Snapshot engine preferences once per meeting; never switch devices
                // or embedding spaces halfway through the two source tracks.
                if let selectionConfigURL {
                    let saved = try JSONDecoder.memoir.decode(AppConfig.self, from: Data(contentsOf: selectionConfigURL))
                    config = config.updating(diarizationEnabled: saved.diarizationEnabled,
                        diarizationEngine: saved.diarizationEngine,
                        speakerAutoMatchThreshold: saved.speakerAutoMatchThreshold,
                        allowCPUFallbackForDiarization: saved.allowCPUFallbackForDiarization)
                    validator = SessionValidator(config: config)
                }
                try stopIfRequested(sessionID: sessionID)
                try store.setProcessingState(sessionID: sessionID, state: .validating)
                try store.appendLog(sessionID: sessionID, line: "Validation started.")
                let validation = try validator.validate(sessionID: sessionID)
                try stopIfRequested(sessionID: sessionID)

                try store.setProcessingState(sessionID: sessionID, state: .transcribing)
                try store.appendLog(sessionID: sessionID, line: "Transcription started.")
                let systemNormalizedURL = try normalizer.normalizedAudioURL(for: sessionID, sourceURL: validation.systemAudioURL)
                let micNormalizedURL = try validation.micAudioURL.map { try normalizer.normalizedAudioURL(for: sessionID, sourceURL: $0) }

                let languageHint = validation.metadata.languageHint ?? config.languageHint
                let huggingFaceToken = config.diarizationEnabled ? (config.diarizationEngine == .pyannote ? runtimeDependencyManager.huggingFaceToken() : nil) : nil
                var sourceTranscripts: [SourceTranscript] = []

                try store.appendLog(sessionID: sessionID, line: "Transcribing system audio with WhisperKit.")
                let transcriptionStart = Date()
                let systemTranscript = try await transcribeCancellably(sessionID: sessionID,
                    audioURL: systemNormalizedURL,
                    config: config,
                    languageHint: languageHint,
                    token: nil
                )
                try store.appendLog(
                    sessionID: sessionID,
                    line: String(format: "System transcription completed in %.2fs using %@ (%@).", Date().timeIntervalSince(transcriptionStart), systemTranscript.runtime ?? "WhisperKit", systemTranscript.backend ?? "accelerated")
                )
                sourceTranscripts.append(SourceTranscript(kind: .system, transcript: systemTranscript))
                var inferredLanguage = systemTranscript.language

                if let micNormalizedURL {
                    try store.appendLog(sessionID: sessionID, line: "Transcribing microphone audio with WhisperKit.")
                    let micStart = Date()
                    let micTranscript = try await transcribeCancellably(sessionID: sessionID,
                        audioURL: micNormalizedURL,
                        config: config,
                        languageHint: languageHint,
                        token: nil
                    )
                    try store.appendLog(
                        sessionID: sessionID,
                        line: String(format: "Microphone transcription completed in %.2fs using %@ (%@).", Date().timeIntervalSince(micStart), micTranscript.runtime ?? "WhisperKit", micTranscript.backend ?? "accelerated")
                    )
                    sourceTranscripts.append(SourceTranscript(kind: .mic, transcript: micTranscript))
                    if inferredLanguage == "unknown" {
                        inferredLanguage = micTranscript.language
                    }
                }

                let alignedTracks = TranscriptAlignment.align(sourceTranscripts: sourceTranscripts, streamSync: validation.streamSync)
                var mergedSegments = TranscriptAlignment.mergeAndDedupe(alignedTracks)
                var diarizationArtifact: DiarizationArtifact?

                if config.diarizationEnabled {
                    try stopIfRequested(sessionID: sessionID)
                    try store.setProcessingState(sessionID: sessionID, state: .diarizing)
                    try store.appendLog(sessionID: sessionID, line: "Diarization started with \(config.diarizationEngine.title).")
                    do {
                        var combinedTurns: [DiarizationTurn] = []
                        var embeddingsByCluster: [String: SpeakerEmbeddingResult] = [:]

                        let systemDiarizationStart = Date()
                        let systemDiarization = try diarizationWorker.diarize(
                            audioURL: systemNormalizedURL,
                            sessionID: sessionID,
                            sourceTrack: .system,
                            config: config,
                            huggingFaceToken: huggingFaceToken,
                            onStart: { pid in try? self.store.setWorkerPID(sessionID: sessionID, pid: pid) }
                        )
                        try store.appendLog(
                            sessionID: sessionID,
                            line: String(format: "System diarization completed in %.2fs using %@ (%@).", Date().timeIntervalSince(systemDiarizationStart), systemDiarization.runtime, systemDiarization.backend)
                        )
                        var diarizationBackends = Set(systemDiarization.backend.split(separator: "+").map(String.init))
                        combinedTurns.append(contentsOf: systemDiarization.turns)
                        systemDiarization.embeddings.forEach { embeddingsByCluster[$0.clusterID] = $0 }

                        if let micNormalizedURL {
                            let micDiarizationStart = Date()
                            let micDiarization = try diarizationWorker.diarize(
                                audioURL: micNormalizedURL,
                                sessionID: sessionID,
                                sourceTrack: .mic,
                                config: config,
                                huggingFaceToken: huggingFaceToken,
                            onStart: { pid in try? self.store.setWorkerPID(sessionID: sessionID, pid: pid) }
                            )
                            try store.appendLog(
                                sessionID: sessionID,
                                line: String(format: "Microphone diarization completed in %.2fs using %@ (%@).", Date().timeIntervalSince(micDiarizationStart), micDiarization.runtime, micDiarization.backend)
                            )
                            diarizationBackends.formUnion(micDiarization.backend.split(separator: "+").map(String.init))
                            combinedTurns.append(contentsOf: micDiarization.turns)
                            micDiarization.embeddings.forEach { embeddingsByCluster[$0.clusterID] = $0 }
                        }

                        try store.setWorkerPID(sessionID: sessionID, pid: nil)
                        var alignedTurns = TranscriptAlignment.align(turns: combinedTurns, streamSync: validation.streamSync)
                        if let zero = validation.metadata.streamSync.flatMap({ Double($0.sessionZeroHostTimeNS) }).map({ $0 / 1e9 }) {
                            let reconciled = try store.reconcileLiveTurns(sessionID: sessionID, turns: alignedTurns, zeroHostSeconds: zero)
                            alignedTurns = reconciled.turns
                            reconciled.mixedClusters.forEach { embeddingsByCluster.removeValue(forKey: $0) }
                        }
                        let profiles = try store.listSpeakerProfiles()
                        let profilesByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
                        let profileEmbeddings = try store.speakerProfileEmbeddings(embeddingSpace: config.diarizationEngine.embeddingSpace)

                        let sessionSpeakers = try buildSessionSpeakers(
                            sessionID: sessionID,
                            turns: alignedTurns,
                            embeddingsByCluster: embeddingsByCluster,
                            profilesByID: profilesByID,
                            profileEmbeddings: profileEmbeddings,
                            zeroHostSeconds: validation.metadata.streamSync.flatMap { Double($0.sessionZeroHostTimeNS) }.map { $0 / 1e9 }
                        )
                        try store.replaceSessionSpeakers(sessionID: sessionID, speakers: sessionSpeakers)
                        for (clusterID, embeddingResult) in embeddingsByCluster {
                            try store.saveSessionSpeakerEmbedding(sessionID: sessionID, clusterID: clusterID, vector: embeddingResult.embedding, embeddingSpace: config.diarizationEngine.embeddingSpace)
                            if embeddingResult.durationSeconds >= 2.5,
                               let speaker = sessionSpeakers.first(where: { $0.clusterID == clusterID }),
                               let profileID = speaker.matchedProfileID,
                               let zero = validation.metadata.streamSync.flatMap({ Double($0.sessionZeroHostTimeNS) }).map({ $0 / 1e9 }),
                               let bridge = try store.liveProfileBridge(sessionID: sessionID,
                                    turns: alignedTurns.filter { $0.clusterID == clusterID }, zeroHostSeconds: zero),
                               bridge.confirmed, bridge.profileID == profileID {
                                try store.saveVoiceSample(profileID: profileID, sessionID: sessionID, clusterID: clusterID,
                                    vector: embeddingResult.embedding, quality: embeddingResult.durationSeconds, space: config.diarizationEngine.embeddingSpace)
                            }
                        }

                        let speakerByCluster = Dictionary(uniqueKeysWithValues: sessionSpeakers.map { ($0.clusterID, $0) })
                        mergedSegments = TranscriptSpeakerAlignment.apply(to: mergedSegments, turns: alignedTurns, speakersByCluster: speakerByCluster)
                        diarizationArtifact = DiarizationArtifact(
                            sessionID: sessionID,
                            runtime: systemDiarization.runtime,
                            backend: diarizationBackends.sorted(by: >).joined(separator: "+"),
                            turns: alignedTurns.map { turn in
                                let speaker = speakerByCluster[turn.clusterID]
                                return DiarizationTurn(
                                    id: turn.id,
                                    clusterID: turn.clusterID,
                                    start: turn.start,
                                    end: turn.end,
                                    sourceTrack: turn.sourceTrack,
                                    matchedProfileID: speaker?.matchedProfileID,
                                    matchedProfileName: speaker?.matchedProfileName,
                                    matchConfidence: speaker?.matchConfidence,
                                    representativeText: speaker?.representativeText
                                )
                            }
                        )
                    } catch let diarizationError as ProcessorError {
                        try store.addWarning(sessionID: sessionID, code: diarizationError.code, message: diarizationError.message)
                        try store.appendLog(sessionID: sessionID, line: "Diarization warning: \(diarizationError.message)")
                    } catch {
                        try store.addWarning(sessionID: sessionID, code: "diarization_failed", message: error.localizedDescription)
                        try store.appendLog(sessionID: sessionID, line: "Diarization warning: \(error.localizedDescription)")
                    }
                }

                try stopIfRequested(sessionID: sessionID)

                let sourceFiles = validation.micAudioURL == nil ? ["system": "system.wav"] : ["system": "system.wav", "mic": "mic.wav"]
                let transcript = CanonicalTranscript(
                    sessionID: sessionID,
                    sourceFiles: sourceFiles,
                    transcription: TranscriptionMetadata(
                        engine: config.transcriptionEngine,
                        model: config.modelName,
                        language: inferredLanguage.isEmpty ? (languageHint ?? "unknown") : inferredLanguage,
                        runtime: systemTranscript.runtime,
                        backend: systemTranscript.backend
                    ),
                    segments: mergedSegments
                )

                try store.setProcessingState(sessionID: sessionID, state: .writingArtifacts)
                try store.writeTranscriptArtifacts(sessionID: sessionID, transcript: transcript)
                if let diarizationArtifact {
                    try store.writeDiarizationArtifact(sessionID: sessionID, artifact: diarizationArtifact)
                }
                try store.appendLog(sessionID: sessionID, line: "Artifacts written.")
                try store.setProcessingState(sessionID: sessionID, state: .completed)
            } catch let error as ProcessorError {
                if error.code == "session_not_found" {
                    continue
                }
                if (try? store.isStopRequested(sessionID: sessionID)) == true || error.code == "session_stopped" {
                    try? store.markStopped(sessionID: sessionID)
                } else {
                    try? store.appendLog(sessionID: sessionID, line: "Processing failed: \(error.message)")
                    try? store.markRetryPending(sessionID: sessionID, error: error)
                }
            } catch {
                let processorError = ProcessorError(code: "internal_error", message: error.localizedDescription, retryable: true)
                try? store.appendLog(sessionID: sessionID, line: "Processing failed: \(processorError.message)")
                try? store.markRetryPending(sessionID: sessionID, error: processorError)
            }
        }
    }

    private func transcribeCancellably(sessionID: String, audioURL: URL, config: AppConfig, languageHint: String?, token: String?) async throws -> WorkerTranscriptResult {
        let worker = transcriptionWorker
        let store = self.store
        let work = Task { try await worker.transcribe(audioURL: audioURL, config: config, languageHint: languageHint, token: token) }
        let monitor = Task {
            while !Task.isCancelled {
                if (try? store.isStopRequested(sessionID: sessionID)) != false { work.cancel(); return }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { monitor.cancel() }
        return try await work.value
    }

    func prepareWhisperModel() async throws -> [String: String] {
        let token = runtimeDependencyManager.huggingFaceToken()
        let modelURL = try await transcriptionWorker.ensureModelDownloaded(config: config, token: token)
        return [
            "accepted": "true",
            "model": config.modelName,
            "path": modelURL.path
        ]
    }

    private func stopIfRequested(sessionID: String) throws {
        if try store.isStopRequested(sessionID: sessionID) {
            throw ProcessorError(code: "session_stopped", message: "Processing was stopped by the operator.", retryable: false)
        }
    }

    private func buildSessionSpeakers(
        sessionID: String,
        turns: [DiarizationTurn],
        embeddingsByCluster: [String: SpeakerEmbeddingResult],
        profilesByID: [String: SpeakerProfile],
        profileEmbeddings: [String: [[Double]]],
        zeroHostSeconds: Double?
    ) throws -> [SessionSpeaker] {
        let groupedTurns = Dictionary(grouping: turns, by: \.clusterID)
        let sortedClusters = groupedTurns.keys.sorted()
        var anonymousIndex = 1
        var speakers: [SessionSpeaker] = []

        for clusterID in sortedClusters {
            let clusterTurns = groupedTurns[clusterID] ?? []
            let duration = clusterTurns.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
            let sourceTrack = clusterTurns.first?.sourceTrack ?? .unknown
            var match = embeddingsByCluster[clusterID].map {
                SpeakerMatching.bestMatch(
                    embedding: $0.embedding,
                    profileEmbeddings: profileEmbeddings,
                    profilesByID: profilesByID,
                    threshold: config.speakerAutoMatchThreshold
                )
            } ?? SpeakerMatchDecision(profileID: nil, profileName: nil, confidence: nil, assignmentState: .anonymous)

            if let zeroHostSeconds, let bridge = try store.liveProfileBridge(sessionID: sessionID, turns: clusterTurns, zeroHostSeconds: zeroHostSeconds) {
                match = SpeakerMatchDecision(profileID: bridge.profileID, profileName: bridge.name,
                    confidence: bridge.confirmed ? 1 : bridge.confidence, assignmentState: .confirmed)
            }
            let label = match.assignmentState == .suggested ? "Speaker \(anonymousIndex)" : match.profileName ?? "Speaker \(anonymousIndex)"
            if match.profileName == nil || match.assignmentState == .suggested {
                anonymousIndex += 1
            }
            speakers.append(
                SessionSpeaker(
                    sessionID: sessionID,
                    clusterID: clusterID,
                    displayLabel: label,
                    sourceTrack: sourceTrack,
                    speakingDurationSeconds: duration,
                    matchedProfileID: match.profileID,
                    matchedProfileName: match.profileName,
                    matchConfidence: match.confidence,
                    assignmentState: match.assignmentState,
                    representativeText: representativeText(for: clusterTurns)
                )
            )
        }

        return speakers.sorted { $0.speakingDurationSeconds > $1.speakingDurationSeconds }
    }

    private func representativeText(for turns: [DiarizationTurn]) -> String? {
        let turn = turns.sorted { ($0.end - $0.start) > ($1.end - $1.start) }.first
        return turn?.representativeText
    }


}

typealias HTTPRequest = DecodedHTTPRequest

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
    private var activeConnections = Set<ObjectIdentifier>()
    private let listener: NWListener
    private let queue = DispatchQueue(label: "MemoirProcessor.HTTPServer")
    private let handler: (HTTPRequest) async -> HTTPResponse
    private let authorizeHeaders: @Sendable (String, String, [String: String]) throws -> Void

    init(host: String, port: UInt16, authorize: @escaping @Sendable (String, String, [String: String]) throws -> Void, handler: @escaping (HTTPRequest) async -> HTTPResponse) throws {
        self.handler = handler
        self.authorizeHeaders = authorize
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
        guard activeConnections.count < 64 else { connection.cancel(); return }
        let identity = ObjectIdentifier(connection)
        activeConnections.insert(identity)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let decoder = HTTPRequestDecoder(authorize: self.authorizeHeaders)
                self.queue.asyncAfter(deadline: .now() + 600) { connection.cancel() }
                self.receive(on: connection, decoder: decoder)
            case .failed(let error):
                self.activeConnections.remove(identity)
                fputs("Connection failed: \(error)\n", stderr)
                connection.cancel()
            case .cancelled:
                self.activeConnections.remove(identity)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection, decoder: HTTPRequestDecoder) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let error {
                fputs("Receive error: \(error)\n", stderr)
                connection.cancel()
                return
            }

            do {
                if let request = try decoder.append(content ?? Data()) {
                    Task {
                        let response = await self.handler(request)
                        self.send(response: response, on: connection)
                        withExtendedLifetime(decoder) {}
                    }
                    return
                }
                if isComplete { throw ProcessorError(code: "invalid_request", message: "Incomplete request.", retryable: false) }
                self.receive(on: connection, decoder: decoder)
            } catch {
                let failure = error as? ProcessorError ?? ProcessorError(code: "invalid_request", message: error.localizedDescription, retryable: false)
                self.send(response: Self.jsonResponse(status: failure.code == "unauthorized" ? 401 : 400, error: failure), on: connection)
            }
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

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
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
            "--pid-file", pidFileURL.path,
            "--parent-pid", String(getpid())
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
        let config: AppConfig
        let selectionConfigURL: URL
        if let index = CommandLine.arguments.firstIndex(of: "--config"), CommandLine.arguments.indices.contains(index + 1) {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            config = try JSONDecoder.memoir.decode(AppConfig.self, from: Data(contentsOf: url))
            selectionConfigURL = url
        } else {
            config = try ConfigStore().load()
            selectionConfigURL = ProcessorPaths.configURL(for: config)
        }
        guard (1...65534).contains(config.port) else { throw ProcessorError(code: "configuration_invalid", message: "Port must be between 1 and 65534.", retryable: false) }
        try FileManager.default.createDirectory(at: ProcessorPaths.root(for: config), withIntermediateDirectories: true)
        let lockFD = open(ProcessorPaths.root(for: config).appendingPathComponent("agent.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            throw ProcessorError(code: "agent_already_running", message: "Another processor agent owns this storage root.", retryable: false)
        }
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
            transcriptionWorker: WhisperKitTranscriptionWorker(),
            diarizationWorker: LocalDiarizationWorker(scriptURL: resolveDiarizationScript()),
            config: config,
            selectionConfigURL: selectionConfigURL
        )
        Task.detached(priority: .utility) {
            for sample in (try? store.pendingLiveVoiceSamples()) ?? [] {
                if (try? store.speakerProfileEmbeddings(embeddingSpace: LiveSpeakerConstants.embeddingSpace)[sample.profileID]) != nil { continue }
                try? LiveVoiceEnrollment.enrol(store: store, config: config, sessionID: sample.sessionID, clusterID: sample.clusterID)
            }
        }
        let live = LiveSpeakerCoordinator(store: store, config: config, selectionConfigURL: selectionConfigURL)
        Task {
            await queue.startRecovery()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await queue.kick()
            }
        }

        guard (1...65534).contains(config.port) else { throw ProcessorError(code: "configuration_invalid", message: "Port must be between 1 and 65534.", retryable: false) }
        let server = try SimpleHTTPServer(host: config.tlsEnabled ? "127.0.0.1" : config.bindHost, port: UInt16(listenPort), authorize: { method, path, headers in
            if method == "GET" && path == "/health" { return }
            try authorize(headers: headers, config: config)
        }) { request in
            await handle(request: request, config: config, store: store, queue: queue, live: live)
        }
        withExtendedLifetime(proxyManager) {
            server.start()
        }
    }

    static func resolveDiarizationScript() -> URL {
        let bundlePath = Bundle.main.resourceURL?.appendingPathComponent("worker/diarize.py")
        if let bundlePath, FileManager.default.fileExists(atPath: bundlePath.path) {
            return bundlePath
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("worker/diarize.py")
    }

    static func handle(request: HTTPRequest, config: AppConfig, store: SessionStore, queue: QueueCoordinator, live: LiveSpeakerCoordinator) async -> HTTPResponse {
        do {
            if request.method == "GET", request.path == "/health" {
                return SimpleHTTPServer.jsonResponse(status: 200, value: ["status": "ok", "service": "memoir-processor", "api_version": "1"])
            }

            try authorize(headers: request.headers, config: config)
            if request.method == "GET", request.path == "/v1/connection" {
                return SimpleHTTPServer.jsonResponse(status: 200, value: ["status": "authenticated"])
            }

            if request.path.hasPrefix("/v1/live/") {
                let parts = request.path.split(separator: "/")
                guard parts.count >= 3 else { throw ProcessorError(code: "invalid_request", message: "Invalid live path.", retryable: false) }
                let id = String(parts[2])
                if parts.count == 3, request.method == "POST" {
                    return SimpleHTTPServer.jsonResponse(status: 200, value: try await live.begin(id))
                }
                if parts.count == 3, request.method == "GET" {
                    return SimpleHTTPServer.jsonResponse(status: 200, value: try store.liveSnapshot(id))
                }
                if parts.count == 4, request.method == "POST" {
                    switch parts[3] {
                    case "chunks":
                        let chunk = try JSONDecoder.memoir.decode(LiveAudioChunk.self, from: request.body)
                        return SimpleHTTPServer.jsonResponse(status: 200, value: try await live.process(id, chunk: chunk))
                    case "speaker":
                        let name = try JSONDecoder.memoir.decode(LiveNameRequest.self, from: request.body)
                        return SimpleHTTPServer.jsonResponse(status: 200, value: try store.nameLiveSpeaker(id, request: name))
                    case "close":
                        return SimpleHTTPServer.jsonResponse(status: 200, value: try store.closeLiveSession(id))
                    default: break
                    }
                }
            }

            if request.method == "GET", request.path == "/v1/meetings" {
                return SimpleHTTPServer.jsonResponse(status: 200, value: try store.searchMeetings())
            }
            if request.method == "POST", request.path == "/v1/meetings/search" {
                let body = try JSONDecoder.memoir.decode(MeetingSearchRequest.self, from: request.body)
                return SimpleHTTPServer.jsonResponse(status: 200, value: try store.searchMeetings(query: body.query, offset: body.offset, limit: body.limit))
            }
            if request.path.hasPrefix("/v1/meetings/") {
                let parts = request.path.split(separator: "/")
                if request.method == "GET", parts.count == 3 {
                    return SimpleHTTPServer.jsonResponse(status: 200, value: try store.meetingDocument(sessionID: String(parts[2])))
                }
                if request.method == "POST", parts.count == 4, parts[3] == "title" {
                    let body = try JSONDecoder.memoir.decode(MeetingTitleRequest.self, from: request.body)
                    return SimpleHTTPServer.jsonResponse(status: 200, value: try store.renameMeeting(sessionID: String(parts[2]), title: body.title, expectedRevision: body.expectedRevision))
                }
                if request.method == "POST", parts.count == 4, parts[3] == "speaker" {
                    let body = try JSONDecoder.memoir.decode(MeetingSpeakerRequest.self, from: request.body)
                    let id = String(parts[2])
                    let document = try store.renameMeetingSpeaker(sessionID: id, speakerID: body.speakerID, name: body.name, expectedRevision: body.expectedRevision)
                    Task.detached(priority: .utility) {
                        do { try LiveVoiceEnrollment.enrol(store: store, config: config, sessionID: id, clusterID: body.speakerID) }
                        catch { try? store.appendLog(sessionID: id, line: "Live voice enrolment pending: \(error.localizedDescription)") }
                    }
                    return SimpleHTTPServer.jsonResponse(status: 200, value: document)
                }
                if request.method == "POST", parts.count == 4, parts[3] == "retry" {
                    let id = String(parts[2])
                    guard try store.fetchStatus(sessionID: id).processingState == .failed else {
                        throw ProcessorError(code: "session_busy", message: "Only a failed transcription can be retried here.", retryable: false)
                    }
                    try store.retrySession(sessionID: id)
                    Task { await queue.kick() }
                    return SimpleHTTPServer.jsonResponse(status: 202, value: ["status": "queued"])
                }
            }

            if request.method == "POST", request.path == "/v1/operator/queue/kick" {
                Task { await queue.kick() }
                return SimpleHTTPServer.jsonResponse(status: 202, value: ["accepted": true])
            }

            if request.method == "POST", request.path == "/v1/operator/runtime/prepare-whisper-model" {
                let response = try await queue.prepareWhisperModel()
                return SimpleHTTPServer.jsonResponse(status: 200, value: response)
            }

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
                guard let uploadURL = request.uploadURL else { throw ProcessorError(code: "invalid_request", message: "Missing upload body.", retryable: false) }
                let response = try store.saveUpload(sessionID: sessionID, kind: kind, fileURL: uploadURL, headerChecksum: checksum)
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
        } catch is DecodingError {
            return SimpleHTTPServer.jsonResponse(status: 400, error: ProcessorError(code: "invalid_request", message: "The request contains invalid JSON fields.", retryable: false))
        } catch {
            return SimpleHTTPServer.jsonResponse(status: 500, error: ProcessorError(code: "internal_error", message: error.localizedDescription, retryable: true))
        }
    }

    static func authorize(headers: [String: String], config: AppConfig) throws {
        guard headers["x-memoir-api-version"] == "1" else {
            throw ProcessorError(code: "unsupported_api_version", message: "Unsupported API version.", retryable: false)
        }

        let expected = "Bearer \(config.authToken)"
        guard headers["authorization"] == expected else {
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
        case "session_conflict", "missing_required_file", "checksum_mismatch", "unexpected_file", "file_conflict", "meeting_conflict", "session_busy":
            return 409
        default:
            return 400
        }
    }
}
