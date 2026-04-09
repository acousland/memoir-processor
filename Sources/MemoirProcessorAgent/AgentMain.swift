import Foundation
import MemoirProcessorCore
import Network
import Darwin

private func normalizeTranscriptText(_ text: String) -> String {
    let lowered = text.lowercased()
    let scalars = lowered.unicodeScalars.map { scalar -> Character in
        CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
    }
    return String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

private func textSimilarity(_ lhs: String, _ rhs: String) -> Double {
    let normalizedLeft = normalizeTranscriptText(lhs)
    let normalizedRight = normalizeTranscriptText(rhs)
    guard !normalizedLeft.isEmpty, !normalizedRight.isEmpty else { return 0 }
    if normalizedLeft == normalizedRight { return 1 }
    if normalizedLeft.contains(normalizedRight) || normalizedRight.contains(normalizedLeft) {
        return 0.92
    }

    let leftTokens = Set(normalizedLeft.split(separator: " ").map(String.init))
    let rightTokens = Set(normalizedRight.split(separator: " ").map(String.init))
    let intersection = leftTokens.intersection(rightTokens).count
    let union = leftTokens.union(rightTokens).count
    guard union > 0 else { return 0 }
    return Double(intersection) / Double(union)
}

private func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
}

private struct SegmentMatch {
    let systemIndex: Int
    let micIndex: Int
    let similarity: Double
    let offset: Double
}

private func alignAndMergeSegments(systemSegments: [TranscriptSegment], micSegments: [TranscriptSegment]) -> (segments: [TranscriptSegment], shiftedSource: String, offset: Double, droppedDuplicates: Int) {
    var candidates: [SegmentMatch] = []
    for (systemIndex, system) in systemSegments.enumerated() {
        for (micIndex, mic) in micSegments.enumerated() {
            let similarity = textSimilarity(system.text, mic.text)
            if similarity >= 0.6 {
                candidates.append(
                    SegmentMatch(
                        systemIndex: systemIndex,
                        micIndex: micIndex,
                        similarity: similarity,
                        offset: mic.start - system.start
                    )
                )
            }
        }
    }

    candidates.sort {
        if $0.similarity == $1.similarity {
            return abs($0.offset) < abs($1.offset)
        }
        return $0.similarity > $1.similarity
    }

    var usedSystem = Set<Int>()
    var usedMic = Set<Int>()
    var matches: [SegmentMatch] = []
    for candidate in candidates {
        guard !usedSystem.contains(candidate.systemIndex), !usedMic.contains(candidate.micIndex) else { continue }
        usedSystem.insert(candidate.systemIndex)
        usedMic.insert(candidate.micIndex)
        matches.append(candidate)
    }

    let offsets = matches.map(\.offset)
    let rawOffset = offsets.isEmpty ? 0 : median(offsets)
    let shiftSystem = rawOffset >= 0
    let appliedOffset = abs(rawOffset)

    let alignedSystem = systemSegments.map {
        TranscriptSegment(
            start: shiftSystem ? max(0, $0.start + appliedOffset) : $0.start,
            end: shiftSystem ? max(0, $0.end + appliedOffset) : $0.end,
            speaker: "System",
            text: $0.text
        )
    }
    let alignedMic = micSegments.map {
        TranscriptSegment(
            start: shiftSystem ? $0.start : max(0, $0.start + appliedOffset),
            end: shiftSystem ? $0.end : max(0, $0.end + appliedOffset),
            speaker: "Mic",
            text: $0.text
        )
    }

    var keptMic: [TranscriptSegment] = []
    var droppedDuplicates = 0
    for mic in alignedMic {
        let duplicateSystemSegment = alignedSystem.first { system in
            let overlapWindow = abs(system.start - mic.start) <= 3.0 || mic.start <= system.end + 0.75
            return overlapWindow && textSimilarity(system.text, mic.text) >= 0.58
        }

        if duplicateSystemSegment != nil {
            droppedDuplicates += 1
            continue
        }

        keptMic.append(mic)
    }

    let merged = (alignedSystem + keptMic).sorted {
        if $0.start == $1.start { return $0.end < $1.end }
        return $0.start < $1.start
    }

    return (
        merged,
        shiftSystem ? "System" : "Mic",
        appliedOffset,
        droppedDuplicates
    )
}

actor QueueCoordinator {
    private let store: SessionStore
    private let validator: SessionValidator
    private let normalizer: AudioNormalizer
    private let transcriptionWorker: WhisperKitTranscriptionWorker
    private let diarizationWorker: PythonDiarizationWorker
    private let config: AppConfig
    private let runtimeDependencyManager = RuntimeDependencyManager()
    private var isRunning = false

    init(
        store: SessionStore,
        validator: SessionValidator,
        normalizer: AudioNormalizer,
        transcriptionWorker: WhisperKitTranscriptionWorker,
        diarizationWorker: PythonDiarizationWorker,
        config: AppConfig
    ) {
        self.store = store
        self.validator = validator
        self.normalizer = normalizer
        self.transcriptionWorker = transcriptionWorker
        self.diarizationWorker = diarizationWorker
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

                try store.setProcessingState(sessionID: sessionID, state: .transcribing)
                try store.appendLog(sessionID: sessionID, line: "Transcription started.")
                let systemNormalizedURL = try normalizer.normalizedAudioURL(for: sessionID, sourceURL: validation.systemAudioURL)
                let micNormalizedURL = try validation.micAudioURL.map { try normalizer.normalizedAudioURL(for: sessionID, sourceURL: $0) }

                let languageHint = validation.metadata.languageHint ?? config.languageHint
                let huggingFaceToken = runtimeDependencyManager.huggingFaceToken()
                var sourceTranscripts: [SourceTranscript] = []

                try store.appendLog(sessionID: sessionID, line: "Transcribing system audio with WhisperKit.")
                let transcriptionStart = Date()
                let systemTranscript = try await transcriptionWorker.transcribe(
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
                    let micTranscript = try await transcriptionWorker.transcribe(
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
                    try store.appendLog(sessionID: sessionID, line: "Diarization started.")
                    do {
                        var combinedTurns: [DiarizationTurn] = []
                        var embeddingsByCluster: [String: SpeakerEmbeddingResult] = [:]

                        let systemDiarizationStart = Date()
                        let systemDiarization = try diarizationWorker.diarize(
                            audioURL: systemNormalizedURL,
                            sessionID: sessionID,
                            sourceTrack: .system,
                            config: config,
                            huggingFaceToken: huggingFaceToken
                        )
                        try store.appendLog(
                            sessionID: sessionID,
                            line: String(format: "System diarization completed in %.2fs using %@ (%@).", Date().timeIntervalSince(systemDiarizationStart), systemDiarization.runtime, systemDiarization.backend)
                        )
                        combinedTurns.append(contentsOf: systemDiarization.turns)
                        systemDiarization.embeddings.forEach { embeddingsByCluster[$0.clusterID] = $0 }

                        if let micNormalizedURL {
                            let micDiarizationStart = Date()
                            let micDiarization = try diarizationWorker.diarize(
                                audioURL: micNormalizedURL,
                                sessionID: sessionID,
                                sourceTrack: .mic,
                                config: config,
                                huggingFaceToken: huggingFaceToken
                            )
                            try store.appendLog(
                                sessionID: sessionID,
                                line: String(format: "Microphone diarization completed in %.2fs using %@ (%@).", Date().timeIntervalSince(micDiarizationStart), micDiarization.runtime, micDiarization.backend)
                            )
                            combinedTurns.append(contentsOf: micDiarization.turns)
                            micDiarization.embeddings.forEach { embeddingsByCluster[$0.clusterID] = $0 }
                        }

                        let alignedTurns = TranscriptAlignment.align(turns: combinedTurns, streamSync: validation.streamSync)
                        let profiles = try store.listSpeakerProfiles()
                        let profilesByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
                        let profileEmbeddings = try store.speakerProfileEmbeddings()

                        let sessionSpeakers = try buildSessionSpeakers(
                            sessionID: sessionID,
                            turns: alignedTurns,
                            embeddingsByCluster: embeddingsByCluster,
                            profilesByID: profilesByID,
                            profileEmbeddings: profileEmbeddings
                        )
                        try store.upsertSessionSpeakers(sessionID: sessionID, speakers: sessionSpeakers)
                        for (clusterID, embeddingResult) in embeddingsByCluster {
                            try store.saveSessionSpeakerEmbedding(sessionID: sessionID, clusterID: clusterID, vector: embeddingResult.embedding)
                        }

                        let speakerByCluster = Dictionary(uniqueKeysWithValues: sessionSpeakers.map { ($0.clusterID, $0) })
                        mergedSegments = applySpeakers(to: mergedSegments, turns: alignedTurns, speakersByCluster: speakerByCluster)
                        diarizationArtifact = DiarizationArtifact(
                            sessionID: sessionID,
                            runtime: "pyannote.audio",
                            backend: alignedTurns.first?.sourceTrack == .mic ? "mixed" : (systemDiarization.backend),
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
        profileEmbeddings: [String: [[Double]]]
    ) throws -> [SessionSpeaker] {
        let groupedTurns = Dictionary(grouping: turns, by: \.clusterID)
        let sortedClusters = groupedTurns.keys.sorted()
        var anonymousIndex = 1
        var speakers: [SessionSpeaker] = []

        for clusterID in sortedClusters {
            let clusterTurns = groupedTurns[clusterID] ?? []
            let duration = clusterTurns.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
            let sourceTrack = clusterTurns.first?.sourceTrack ?? .unknown
            let match = embeddingsByCluster[clusterID].map {
                SpeakerMatching.bestMatch(
                    embedding: $0.embedding,
                    profileEmbeddings: profileEmbeddings,
                    profilesByID: profilesByID,
                    threshold: config.speakerAutoMatchThreshold
                )
            } ?? SpeakerMatchDecision(profileID: nil, profileName: nil, confidence: nil, assignmentState: .anonymous)

            let label = match.profileName ?? "Speaker \(anonymousIndex)"
            if match.profileName == nil {
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

    private func applySpeakers(
        to segments: [TranscriptSegment],
        turns: [DiarizationTurn],
        speakersByCluster: [String: SessionSpeaker]
    ) -> [TranscriptSegment] {
        segments.map { segment in
            let matchingTurn = turns
                .filter { turn in
                    if let source = segment.speakerSource, source != turn.sourceTrack {
                        return false
                    }
                    return overlapDuration(startA: segment.start, endA: segment.end, startB: turn.start, endB: turn.end) > 0
                }
                .max { left, right in
                    overlapDuration(startA: segment.start, endA: segment.end, startB: left.start, endB: left.end)
                    < overlapDuration(startA: segment.start, endA: segment.end, startB: right.start, endB: right.end)
                }

            guard let matchingTurn, let sessionSpeaker = speakersByCluster[matchingTurn.clusterID] else {
                return segment
            }

            return TranscriptSegment(
                id: segment.id,
                start: segment.start,
                end: segment.end,
                speaker: sessionSpeaker.displayLabel,
                speakerID: sessionSpeaker.matchedProfileID ?? matchingTurn.clusterID,
                speakerSource: matchingTurn.sourceTrack,
                speakerConfidence: sessionSpeaker.matchConfidence,
                text: segment.text
            )
        }
    }

    private func overlapDuration(startA: Double, endA: Double, startB: Double, endB: Double) -> Double {
        max(0, min(endA, endB) - max(startA, startB))
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
            transcriptionWorker: WhisperKitTranscriptionWorker(),
            diarizationWorker: PythonDiarizationWorker(scriptURL: resolveDiarizationScript()),
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

    static func resolveDiarizationScript() -> URL {
        let bundlePath = Bundle.main.resourceURL?.appendingPathComponent("worker/diarize.py")
        if let bundlePath, FileManager.default.fileExists(atPath: bundlePath.path) {
            return bundlePath
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("worker/diarize.py")
    }

    static func handle(request: HTTPRequest, config: AppConfig, store: SessionStore, queue: QueueCoordinator) async -> HTTPResponse {
        do {
            if request.method == "GET", request.path == "/health" {
                return SimpleHTTPServer.jsonResponse(status: 200, value: ["status": "ok", "service": "memoir-processor", "api_version": "1"])
            }

            try authorize(request: request, config: config)

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
