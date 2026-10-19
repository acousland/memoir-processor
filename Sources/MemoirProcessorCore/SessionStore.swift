import Foundation
import Darwin

public final class SessionStore: @unchecked Sendable {
    private let config: AppConfig
    private let fileManager = FileManager.default
    let database: SQLiteDatabase

    public init(config: AppConfig) throws {
        self.config = config
        let root = ProcessorPaths.root(for: config)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: ProcessorPaths.sessionsDirectory(for: config), withIntermediateDirectories: true)
        database = try SQLiteDatabase(path: ProcessorPaths.databaseURL(for: config).path)
        try migrate()
        try migrateMeetingLibrary()
    }

    private func migrate() throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS sessions (
                session_id TEXT PRIMARY KEY,
                session_name TEXT NOT NULL,
                recording_started_at TEXT NOT NULL,
                recording_ended_at TEXT NOT NULL,
                recorder_device_id TEXT NOT NULL,
                recorder_app_version TEXT NOT NULL,
                recorder_build TEXT NOT NULL,
                metadata_expected INTEGER NOT NULL,
                system_expected INTEGER NOT NULL,
                mic_expected INTEGER NOT NULL,
                metadata_received INTEGER NOT NULL DEFAULT 0,
                system_received INTEGER NOT NULL DEFAULT 0,
                mic_received INTEGER NOT NULL DEFAULT 0,
                metadata_size INTEGER,
                system_size INTEGER,
                mic_size INTEGER,
                metadata_sha256 TEXT,
                system_sha256 TEXT,
                mic_sha256 TEXT,
                ingestion_state TEXT NOT NULL,
                processing_state TEXT,
                attempt INTEGER NOT NULL DEFAULT 0,
                error_code TEXT,
                error_message TEXT,
                retryable INTEGER NOT NULL DEFAULT 0,
                stop_requested INTEGER NOT NULL DEFAULT 0,
                worker_pid INTEGER,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                create_request_hash TEXT NOT NULL
            );
        """)
        if try !hasColumn("stop_requested", in: "sessions") {
            try database.execute("ALTER TABLE sessions ADD COLUMN stop_requested INTEGER NOT NULL DEFAULT 0;")
        }
        if try !hasColumn("worker_pid", in: "sessions") {
            try database.execute("ALTER TABLE sessions ADD COLUMN worker_pid INTEGER;")
        }
        if try !hasColumn("next_attempt_at", in: "sessions") {
            try database.execute("ALTER TABLE sessions ADD COLUMN next_attempt_at TEXT;")
        }
        try database.execute("""
            CREATE TABLE IF NOT EXISTS idempotency_records (
                endpoint TEXT NOT NULL,
                idempotency_key TEXT NOT NULL,
                request_hash TEXT NOT NULL,
                response_json TEXT NOT NULL,
                created_at TEXT NOT NULL,
                PRIMARY KEY(endpoint, idempotency_key)
            );
        """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS session_warnings (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                code TEXT NOT NULL,
                message TEXT NOT NULL,
                created_at TEXT NOT NULL
            );
        """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS speaker_profiles (
                speaker_profile_id TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                archived INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                last_seen_at TEXT
            );
        """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS speaker_profile_embeddings (
                embedding_id TEXT PRIMARY KEY,
                speaker_profile_id TEXT NOT NULL,
                source_session_id TEXT NOT NULL,
                cluster_id TEXT NOT NULL,
                vector_json TEXT NOT NULL,
                quality_score REAL NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL
            );
        """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS session_speakers (
                session_id TEXT NOT NULL,
                cluster_id TEXT NOT NULL,
                display_label TEXT NOT NULL,
                source_track TEXT NOT NULL,
                speaking_duration_seconds REAL NOT NULL DEFAULT 0,
                matched_profile_id TEXT,
                matched_profile_name TEXT,
                match_confidence REAL,
                assignment_state TEXT NOT NULL DEFAULT 'anonymous',
                representative_text TEXT,
                embedding_vector_json TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                PRIMARY KEY(session_id, cluster_id)
            );
        """)
        for table in ["session_speakers", "speaker_profile_embeddings"] {
            if try !hasColumn("embedding_space", in: table) {
                try database.execute("ALTER TABLE \(table) ADD COLUMN embedding_space TEXT NOT NULL DEFAULT 'legacy-pyannote-embedding';")
            }
        }
    }

    private func hasColumn(_ columnName: String, in tableName: String) throws -> Bool {
        try database.fetchAll("PRAGMA table_info(\(tableName));").contains { row in
            row["name"]?.stringValue == columnName
        }
    }

    public func listSessions() throws -> [SessionListItem] {
        try database.fetchAll("""
            SELECT session_id, session_name, ingestion_state, processing_state, attempt, created_at, updated_at, error_message,
                   (SELECT COUNT(*) FROM session_warnings WHERE session_warnings.session_id = sessions.session_id) AS warning_count
            FROM sessions
            ORDER BY created_at DESC
        """).map { row in
            SessionListItem(
                id: row["session_id"]?.stringValue ?? "",
                sessionName: row["session_name"]?.stringValue ?? "",
                ingestionState: IngestionState(rawValue: row["ingestion_state"]?.stringValue ?? "") ?? .created,
                processingState: row["processing_state"]?.stringValue.flatMap(ProcessingState.init(rawValue:)),
                attempt: row["attempt"]?.intValue ?? 0,
                createdAt: row["created_at"]?.stringValue ?? "",
                updatedAt: row["updated_at"]?.stringValue ?? "",
                errorMessage: row["error_message"]?.stringValue,
                warningCount: row["warning_count"]?.intValue ?? 0
            )
        }
    }

    public func fetchStatus(sessionID: String) throws -> SessionStatusResponse {
        try validateSessionID(sessionID)
        guard let row = try database.fetchOne("SELECT * FROM sessions WHERE session_id = ?", bindings: [.text(sessionID)]) else {
            throw ProcessorError(code: "session_not_found", message: "Session does not exist.", retryable: false)
        }

        return SessionStatusResponse(
            sessionID: sessionID,
            sessionName: row["session_name"]?.stringValue ?? "",
            ingestionState: IngestionState(rawValue: row["ingestion_state"]?.stringValue ?? "") ?? .created,
            processingState: row["processing_state"]?.stringValue.flatMap(ProcessingState.init(rawValue:)),
            createdAt: row["created_at"]?.stringValue ?? "",
            updatedAt: row["updated_at"]?.stringValue ?? "",
            expectedFiles: ExpectedFiles(
                metadata: row["metadata_expected"]?.boolValue ?? true,
                system: row["system_expected"]?.boolValue ?? true,
                mic: row["mic_expected"]?.boolValue ?? false
            ),
            receivedFiles: ReceivedFiles(
                metadata: row["metadata_received"]?.boolValue ?? false,
                system: row["system_received"]?.boolValue ?? false,
                mic: row["mic_received"]?.boolValue ?? false
            ),
            error: row["error_code"]?.stringValue.map {
                ProcessorError(code: $0, message: row["error_message"]?.stringValue ?? "Unknown error", retryable: row["retryable"]?.boolValue ?? false)
            },
            warnings: try warnings(for: sessionID)
        )
    }

    public func createSession(_ request: CreateSessionRequest, idempotencyKey: String, baseURL: String) throws -> (CreateSessionResponse, Int) {
        let result = try database.transaction { try createSessionWithinTransaction(request, idempotencyKey: idempotencyKey, baseURL: baseURL) }
        if try database.fetchOne("SELECT session_id FROM meeting_search WHERE session_id=?", bindings: [.text(request.sessionID)]) == nil {
            try indexMeetingTranscript(sessionID: request.sessionID, transcript: nil)
        }
        return result
    }

    public func completeSession(sessionID: String, request: CompleteSessionRequest, idempotencyKey: String) throws -> (CompleteSessionResponse, Int) {
        try database.transaction { try completeSessionWithinTransaction(sessionID: sessionID, request: request, idempotencyKey: idempotencyKey) }
    }

    private func createSessionWithinTransaction(_ request: CreateSessionRequest, idempotencyKey: String, baseURL: String) throws -> (CreateSessionResponse, Int) {
        try validateSessionID(request.sessionID)
        guard request.expectedFiles.metadata, request.expectedFiles.system,
              ISO8601DateFormatter().date(from: request.recordingStartedAt.replacingOccurrences(of: #"\.\d+(?=Z|[+-]\d\d:\d\d$)"#, with: "", options: .regularExpression)) != nil else {
            throw ProcessorError(code: "invalid_request", message: "Required files or recording dates are invalid.", retryable: false)
        }
        let requestHash = try jsonHash(request)
        if let existing = try idempotentResponse(for: .create, key: idempotencyKey, requestHash: requestHash, type: CreateSessionResponse.self) {
            return (existing, 200)
        }

        if let row = try database.fetchOne("SELECT create_request_hash FROM sessions WHERE session_id = ?", bindings: [.text(request.sessionID)]) {
            guard row["create_request_hash"]?.stringValue == requestHash else {
                throw ProcessorError(code: "session_conflict", message: "Session already exists with different payload.", retryable: false)
            }

            let response = buildCreateResponse(sessionID: request.sessionID, baseURL: baseURL)
            try saveIdempotency(endpoint: .create, key: idempotencyKey, requestHash: requestHash, response: response)
            return (response, 200)
        }

        let now = Time.nowString()
        try createSessionDirectories(sessionID: request.sessionID)
        try database.execute("""
            INSERT INTO sessions (
                session_id, session_name, recording_started_at, recording_ended_at,
                recorder_device_id, recorder_app_version, recorder_build,
                metadata_expected, system_expected, mic_expected,
                ingestion_state, processing_state, attempt,
                created_at, updated_at, create_request_hash
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, bindings: [
            .text(request.sessionID),
            .text(request.sessionName),
            .text(request.recordingStartedAt),
            .text(request.recordingEndedAt),
            .text(request.recorder.deviceID),
            .text(request.recorder.appVersion),
            .text(request.recorder.build),
            .integer(request.expectedFiles.metadata ? 1 : 0),
            .integer(request.expectedFiles.system ? 1 : 0),
            .integer(request.expectedFiles.mic ? 1 : 0),
            .text(IngestionState.created.rawValue),
            .null,
            .integer(0),
            .text(now),
            .text(now),
            .text(requestHash)
        ])

        let response = buildCreateResponse(sessionID: request.sessionID, baseURL: baseURL)
        try saveIdempotency(endpoint: .create, key: idempotencyKey, requestHash: requestHash, response: response)
        try writeJobArtifact(sessionID: request.sessionID)
        return (response, 201)
    }

    public func saveUpload(sessionID: String, kind: UploadFileKind, body: Data, headerChecksum: String) throws -> FileUploadResponse {
        let temporary = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try body.write(to: temporary)
        defer { try? fileManager.removeItem(at: temporary) }
        return try saveUpload(sessionID: sessionID, kind: kind, fileURL: temporary, headerChecksum: headerChecksum)
    }

    public func saveUpload(sessionID: String, kind: UploadFileKind, fileURL: URL, headerChecksum: String) throws -> FileUploadResponse {
        try database.transaction { try saveUploadWithinTransaction(sessionID: sessionID, kind: kind, fileURL: fileURL, headerChecksum: headerChecksum) }
    }

    private func saveUploadWithinTransaction(sessionID: String, kind: UploadFileKind, fileURL: URL, headerChecksum: String) throws -> FileUploadResponse {
        try validateSessionID(sessionID)
        guard let row = try database.fetchOne("SELECT * FROM sessions WHERE session_id = ?", bindings: [.text(sessionID)]) else {
            throw ProcessorError(code: "session_not_found", message: "Session does not exist.", retryable: false)
        }

        let expected = switch kind {
        case .metadata: row["metadata_expected"]?.boolValue ?? true
        case .system: row["system_expected"]?.boolValue ?? true
        case .mic: row["mic_expected"]?.boolValue ?? false
        }
        guard expected else {
            throw ProcessorError(code: "unexpected_file", message: "Upload is not expected for this session.", retryable: false)
        }

        let actualChecksum = try Hashing.sha256Hex(for: fileURL)
        guard actualChecksum == headerChecksum else {
            throw ProcessorError(code: "checksum_mismatch", message: "Uploaded file hash does not match X-Content-SHA256 header.", retryable: false)
        }

        let size = try fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? Int ?? 0
        let existingHashColumn = "\(kind.rawValue)_sha256"
        if let existingHash = row[existingHashColumn]?.stringValue, !existingHash.isEmpty, existingHash != actualChecksum {
            throw ProcessorError(code: "file_conflict", message: "File slot already contains different bytes.", retryable: false)
        }

        let targetURL: URL = kind == .metadata ? ProcessorPaths.metadataURL(for: config, sessionID: sessionID) : ProcessorPaths.audioURL(for: config, sessionID: sessionID, kind: kind)
        let staged = targetURL.appendingPathExtension("incoming")
        try? fileManager.removeItem(at: staged)
        try fileManager.copyItem(at: fileURL, to: staged)
        if fileManager.fileExists(atPath: targetURL.path) { try fileManager.removeItem(at: staged) }
        else { try fileManager.moveItem(at: staged, to: targetURL) }
        let receivedColumn = "\(kind.rawValue)_received"
        let sizeColumn = "\(kind.rawValue)_size"
        let hashColumn = "\(kind.rawValue)_sha256"
        let now = Time.nowString()
        try database.execute("""
            UPDATE sessions
            SET \(receivedColumn) = 1,
                \(sizeColumn) = ?,
                \(hashColumn) = ?,
                ingestion_state = ?,
                updated_at = ?,
                error_code = NULL,
                error_message = NULL,
                retryable = 0
            WHERE session_id = ?
        """, bindings: [
            .integer(Int64(size)),
            .text(actualChecksum),
            .text(IngestionState.uploading.rawValue),
            .text(now),
            .text(sessionID)
        ])

        try appendLog(sessionID: sessionID, line: "Accepted \(kind.rawValue) upload (\(size) bytes).")
        try writeJobArtifact(sessionID: sessionID)
        return FileUploadResponse(sessionID: sessionID, file: kind.rawValue, sizeBytes: size, sha256: actualChecksum, accepted: true)
    }

    private func completeSessionWithinTransaction(sessionID: String, request: CompleteSessionRequest, idempotencyKey: String) throws -> (CompleteSessionResponse, Int) {
        try validateSessionID(sessionID)
        let requestHash = try jsonHash(request)
        if let existing = try idempotentResponse(for: .complete, key: idempotencyKey, requestHash: requestHash, type: CompleteSessionResponse.self) {
            return (existing, 200)
        }

        let status = try fetchStatus(sessionID: sessionID)
        guard status.receivedFiles.metadata, status.receivedFiles.system else {
            throw ProcessorError(code: "missing_required_file", message: "Required uploads are missing.", retryable: false)
        }
        if status.expectedFiles.mic && !status.receivedFiles.mic {
            throw ProcessorError(code: "missing_required_file", message: "mic.wav was declared but not uploaded.", retryable: false)
        }

        try verifyUploadDescriptor(sessionID: sessionID, kind: .metadata, descriptor: request.uploadedFiles["metadata"])
        try verifyUploadDescriptor(sessionID: sessionID, kind: .system, descriptor: request.uploadedFiles["system"])
        if status.expectedFiles.mic {
            try verifyUploadDescriptor(sessionID: sessionID, kind: .mic, descriptor: request.uploadedFiles["mic"])
        }
        try clearWarnings(sessionID: sessionID)

        let acceptedAt = Time.nowString()
        try database.execute("""
            UPDATE sessions
            SET ingestion_state = ?,
                processing_state = ?,
                updated_at = ?,
                error_code = NULL,
                error_message = NULL,
                retryable = 0
            WHERE session_id = ?
        """, bindings: [
            .text(IngestionState.readyForProcessing.rawValue),
            .text(ProcessingState.queued.rawValue),
            .text(acceptedAt),
            .text(sessionID)
        ])

        let response = CompleteSessionResponse(
            sessionID: sessionID,
            ingestionState: .readyForProcessing,
            processingState: .queued,
            acceptedAt: acceptedAt
        )
        try saveIdempotency(endpoint: .complete, key: idempotencyKey, requestHash: requestHash, response: response)
        try appendLog(sessionID: sessionID, line: "Session marked complete and queued.")
        try writeJobArtifact(sessionID: sessionID)
        return (response, 200)
    }

    public func claimNextRunnableSession() throws -> String? {
        try database.transaction {
            guard let sessionID = try nextRunnableSession() else { return nil }
            try setProcessingState(sessionID: sessionID, state: .validating)
            return sessionID
        }
    }

    public func nextRunnableSession() throws -> String? {
        try database.fetchOne("""
            SELECT session_id
            FROM sessions
            WHERE processing_state IN (?, ?) AND (next_attempt_at IS NULL OR next_attempt_at <= ?)
            ORDER BY updated_at ASC
            LIMIT 1
        """, bindings: [.text(ProcessingState.queued.rawValue), .text(ProcessingState.retryPending.rawValue), .text(Time.nowString())])?["session_id"]?.stringValue
    }

    public func markRetryPending(sessionID: String, error: ProcessorError) throws {
        try validateSessionID(sessionID)
        guard let row = try database.fetchOne("SELECT attempt FROM sessions WHERE session_id = ?", bindings: [.text(sessionID)]) else { return }
        let attempt = row["attempt"]?.intValue ?? 0
        let nextAttempt = attempt + 1
        let nextState: ProcessingState = error.retryable && nextAttempt < config.maxRetries ? .retryPending : .failed
        try setProcessingState(sessionID: sessionID, state: nextState, attempt: nextAttempt, error: error)
        if nextState == .retryPending {
            let due = ISO8601DateFormatter.memoirTimestamp(Date().addingTimeInterval(min(300, pow(2, Double(nextAttempt)))))
            try database.execute("UPDATE sessions SET next_attempt_at = ? WHERE session_id = ?", bindings: [.text(due), .text(sessionID)])
        }
    }

    public func setProcessingState(sessionID: String, state: ProcessingState, attempt: Int? = nil, error: ProcessorError? = nil) throws {
        try validateSessionID(sessionID)
        let currentAttempt: Int
        if let attempt {
            currentAttempt = attempt
        } else {
            currentAttempt = try database.fetchOne("SELECT attempt FROM sessions WHERE session_id = ?", bindings: [.text(sessionID)])?["attempt"]?.intValue ?? 0
        }
        let now = Time.nowString()
        try database.execute("""
            UPDATE sessions
            SET processing_state = ?,
                attempt = ?,
                updated_at = ?,
                error_code = ?,
                error_message = ?,
                retryable = ?,
                next_attempt_at = NULL,
                worker_pid = NULL
            WHERE session_id = ?
        """, bindings: [
            .text(state.rawValue),
            .integer(Int64(currentAttempt)),
            .text(now),
            error.map { .text($0.code) } ?? .null,
            error.map { .text($0.message) } ?? .null,
            .integer((error?.retryable ?? false) ? 1 : 0),
            .text(sessionID)
        ])
        try writeJobArtifact(sessionID: sessionID)
    }

    public func retrySession(sessionID: String) throws {
        try validateSessionID(sessionID)
        let state = try fetchStatus(sessionID: sessionID).processingState
        guard ![ProcessingState.validating, .transcribing, .diarizing, .writingArtifacts].contains(where: { $0 == state }) else {
            throw ProcessorError(code: "session_busy", message: "Wait for the active job to stop before retrying.", retryable: false)
        }
        try database.execute("UPDATE sessions SET stop_requested = 0, attempt = 0 WHERE session_id = ?", bindings: [.text(sessionID)])
        try setProcessingState(sessionID: sessionID, state: .retryPending, error: nil)
        try appendLog(sessionID: sessionID, line: "Manual retry requested.")
    }

    public func requestStopSession(sessionID: String) throws {
        try validateSessionID(sessionID)
        guard let row = try database.fetchOne("SELECT processing_state, worker_pid FROM sessions WHERE session_id = ?", bindings: [.text(sessionID)]) else {
            throw ProcessorError(code: "session_not_found", message: "Session does not exist.", retryable: false)
        }

        let processingState = row["processing_state"]?.stringValue.flatMap(ProcessingState.init(rawValue:))
        let workerPID = row["worker_pid"]?.intValue
        try database.execute("""
            UPDATE sessions
            SET stop_requested = 1,
                updated_at = ?
            WHERE session_id = ?
        """, bindings: [.text(Time.nowString()), .text(sessionID)])

        if let workerPID, workerPID > 0 {
            _ = kill(Int32(workerPID), SIGTERM)
        }

        if processingState == .queued || processingState == .retryPending {
            try markStopped(sessionID: sessionID)
        } else {
            try appendLog(sessionID: sessionID, line: "Stop requested.")
            try writeJobArtifact(sessionID: sessionID)
        }
    }

    public func removeSession(sessionID: String) throws {
        try database.transaction { try removeSessionWithinTransaction(sessionID: sessionID) }
    }

    private func removeSessionWithinTransaction(sessionID: String) throws {
        try validateSessionID(sessionID)
        guard try database.fetchOne("SELECT session_id FROM sessions WHERE session_id = ?", bindings: [.text(sessionID)]) != nil else {
            throw ProcessorError(code: "session_not_found", message: "Session does not exist.", retryable: false)
        }

        let active = try fetchStatus(sessionID: sessionID).processingState
        guard ![ProcessingState.validating, .transcribing, .diarizing, .writingArtifacts].contains(where: { $0 == active }) else {
            throw ProcessorError(code: "session_busy", message: "Stop the session and wait for processing to finish before removing it.", retryable: true)
        }
        try database.execute("DELETE FROM session_warnings WHERE session_id = ?", bindings: [.text(sessionID)])
        try database.execute("DELETE FROM session_speakers WHERE session_id = ?", bindings: [.text(sessionID)])
        try database.execute("DELETE FROM speaker_profile_embeddings WHERE source_session_id = ?", bindings: [.text(sessionID)])
        try database.execute("DELETE FROM idempotency_records WHERE response_json LIKE ?", bindings: [.text("%" + sessionID + "%")])
        try database.execute("DELETE FROM sessions WHERE session_id = ?", bindings: [.text(sessionID)])
        try database.execute("DELETE FROM meeting_search WHERE session_id = ?", bindings: [.text(sessionID)])
        try database.execute("DELETE FROM meeting_documents WHERE session_id = ?", bindings: [.text(sessionID)])
        let sessionDirectory = ProcessorPaths.sessionDirectory(for: config, sessionID: sessionID)
        if fileManager.fileExists(atPath: sessionDirectory.path) {
            try fileManager.removeItem(at: sessionDirectory)
        }
    }

    public func recoverIncompleteSessions() throws {
        let rows = try database.fetchAll("""
            SELECT session_id, processing_state
            FROM sessions
            WHERE processing_state IN (?, ?, ?, ?)
        """, bindings: [
            .text(ProcessingState.validating.rawValue),
            .text(ProcessingState.transcribing.rawValue),
            .text(ProcessingState.diarizing.rawValue),
            .text(ProcessingState.writingArtifacts.rawValue)
        ])

        for row in rows {
            guard let sessionID = row["session_id"]?.stringValue else { continue }
            try setProcessingState(
                sessionID: sessionID,
                state: .retryPending,
                error: ProcessorError(code: "recovered_after_restart", message: "Session moved back to retry queue after restart.", retryable: true)
            )
        }
    }

    public func metadataFile(for sessionID: String) throws -> MetadataFile {
        let url = ProcessorPaths.metadataURL(for: config, sessionID: sessionID)
        let data = try Data(contentsOf: url)
        return try JSONDecoder.memoir.decode(MetadataFile.self, from: data)
    }

    public func appendLog(sessionID: String, line: String) throws {
        try validateSessionID(sessionID)
        let logURL = ProcessorPaths.logsURL(for: config, sessionID: sessionID)
        let entry = "[\(Time.nowString())] \(line)\n"
        if fileManager.fileExists(atPath: logURL.path) {
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            handle.write(Data(entry.utf8))
        } else {
            try entry.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

    public func writeTranscriptArtifacts(sessionID: String, transcript: CanonicalTranscript) throws {
        try database.synchronized {
            try validateSessionID(sessionID)
            let processingDirectory = ProcessorPaths.processingDirectory(for: config, sessionID: sessionID)
            try fileManager.createDirectory(at: processingDirectory, withIntermediateDirectories: true)

            let transcriptURL = processingDirectory.appendingPathComponent("transcript.json")
            try JSONEncoder.memoir.encode(transcript).write(to: transcriptURL, options: .atomic)

            let plainText = transcript.segments.map { segment in
                let prefix = segment.speaker.map { "[\($0)] " } ?? ""
                return "\(prefix)\(segment.text)"
            }.joined(separator: "\n")
            try plainText.write(to: processingDirectory.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)

            let srt = transcript.segments.enumerated().map { index, segment in
                let prefix = segment.speaker.map { "[\($0)] " } ?? ""
                return "\(index + 1)\n\(Self.srtTimestamp(segment.start)) --> \(Self.srtTimestamp(segment.end))\n\(prefix)\(segment.text)\n"
            }.joined(separator: "\n")
            try srt.write(to: processingDirectory.appendingPathComponent("transcript.srt"), atomically: true, encoding: .utf8)
            try indexMeetingTranscript(sessionID: sessionID, transcript: transcript)
        }
    }

    public func writeDiarizationArtifact(sessionID: String, artifact: DiarizationArtifact) throws {
        try validateSessionID(sessionID)
        let processingDirectory = ProcessorPaths.processingDirectory(for: config, sessionID: sessionID)
        try fileManager.createDirectory(at: processingDirectory, withIntermediateDirectories: true)
        let diarizationURL = processingDirectory.appendingPathComponent("diarization.json")
        try JSONEncoder.memoir.encode(artifact).write(to: diarizationURL, options: .atomic)
    }

    public func artifactPath(sessionID: String, name: String) -> URL {
        ProcessorPaths.processingDirectory(for: config, sessionID: sessionID).appendingPathComponent(name)
    }

    public func setWorkerPID(sessionID: String, pid: Int32?) throws {
        try validateSessionID(sessionID)
        try database.execute("""
            UPDATE sessions
            SET worker_pid = ?,
                updated_at = ?
            WHERE session_id = ?
        """, bindings: [
            pid.map { .integer(Int64($0)) } ?? .null,
            .text(Time.nowString()),
            .text(sessionID)
        ])
    }

    public func isStopRequested(sessionID: String) throws -> Bool {
        try validateSessionID(sessionID)
        guard let row = try database.fetchOne("SELECT stop_requested FROM sessions WHERE session_id = ?", bindings: [.text(sessionID)]) else {
            return true
        }
        return row["stop_requested"]?.boolValue ?? false
    }

    public func markStopped(sessionID: String) throws {
        try validateSessionID(sessionID)
        try database.execute("""
            UPDATE sessions
            SET processing_state = ?,
                error_code = ?,
                error_message = ?,
                retryable = 0,
                stop_requested = 0,
                worker_pid = NULL,
                updated_at = ?
            WHERE session_id = ?
        """, bindings: [
            .text(ProcessingState.failed.rawValue),
            .text("session_stopped"),
            .text("Processing was stopped by the operator."),
            .text(Time.nowString()),
            .text(sessionID)
        ])
        try appendLog(sessionID: sessionID, line: "Processing stopped.")
        try writeJobArtifact(sessionID: sessionID)
    }

    public func configValue() -> AppConfig {
        config
    }

    public func warnings(for sessionID: String) throws -> [SessionWarning] {
        try database.fetchAll("""
            SELECT id, code, message, created_at
            FROM session_warnings
            WHERE session_id = ?
            ORDER BY created_at ASC
        """, bindings: [.text(sessionID)]).map { row in
            SessionWarning(
                id: UUID(uuidString: row["id"]?.stringValue ?? "") ?? UUID(),
                code: row["code"]?.stringValue ?? "warning",
                message: row["message"]?.stringValue ?? "",
                createdAt: row["created_at"]?.stringValue ?? Time.nowString()
            )
        }
    }

    public func addWarning(sessionID: String, code: String, message: String) throws {
        try validateSessionID(sessionID)
        let warning = SessionWarning(code: code, message: message, createdAt: Time.nowString())
        try database.execute("""
            INSERT INTO session_warnings (id, session_id, code, message, created_at)
            VALUES (?, ?, ?, ?, ?)
        """, bindings: [
            .text(warning.id.uuidString),
            .text(sessionID),
            .text(code),
            .text(message),
            .text(warning.createdAt)
        ])
    }

    public func clearWarnings(sessionID: String) throws {
        try validateSessionID(sessionID)
        try database.execute("DELETE FROM session_warnings WHERE session_id = ?", bindings: [.text(sessionID)])
    }

    public func listSessionSpeakers(sessionID: String) throws -> [SessionSpeaker] {
        try validateSessionID(sessionID)
        return try database.fetchAll("""
            SELECT session_id, cluster_id, display_label, source_track, speaking_duration_seconds, matched_profile_id,
                   matched_profile_name, match_confidence, assignment_state, representative_text
            FROM session_speakers
            WHERE session_id = ?
            ORDER BY speaking_duration_seconds DESC, cluster_id ASC
        """, bindings: [.text(sessionID)]).map { row in
            SessionSpeaker(
                sessionID: row["session_id"]?.stringValue ?? sessionID,
                clusterID: row["cluster_id"]?.stringValue ?? "",
                displayLabel: row["display_label"]?.stringValue ?? "Speaker",
                sourceTrack: SpeakerSource(rawValue: row["source_track"]?.stringValue ?? "") ?? .unknown,
                speakingDurationSeconds: row["speaking_duration_seconds"]?.doubleValue ?? 0,
                matchedProfileID: row["matched_profile_id"]?.stringValue,
                matchedProfileName: row["matched_profile_name"]?.stringValue,
                matchConfidence: row["match_confidence"]?.doubleValue,
                assignmentState: SpeakerAssignmentState(rawValue: row["assignment_state"]?.stringValue ?? "") ?? .anonymous,
                representativeText: row["representative_text"]?.stringValue
            )
        }
    }

    public func replaceSessionSpeakers(sessionID: String, speakers: [SessionSpeaker]) throws {
        try validateSessionID(sessionID)
        try database.transaction {
            try database.execute("DELETE FROM session_speakers WHERE session_id = ?", bindings: [.text(sessionID)])
            try upsertSessionSpeakers(sessionID: sessionID, speakers: speakers)
        }
    }

    public func upsertSessionSpeakers(sessionID: String, speakers: [SessionSpeaker]) throws {
        try validateSessionID(sessionID)
        let now = Time.nowString()
        for speaker in speakers {
            try database.execute("""
                INSERT INTO session_speakers (
                    session_id, cluster_id, display_label, source_track, speaking_duration_seconds,
                    matched_profile_id, matched_profile_name, match_confidence, assignment_state,
                    representative_text, embedding_vector_json, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(session_id, cluster_id) DO UPDATE SET
                    display_label = excluded.display_label,
                    source_track = excluded.source_track,
                    speaking_duration_seconds = excluded.speaking_duration_seconds,
                    matched_profile_id = excluded.matched_profile_id,
                    matched_profile_name = excluded.matched_profile_name,
                    match_confidence = excluded.match_confidence,
                    assignment_state = excluded.assignment_state,
                    representative_text = excluded.representative_text,
                    updated_at = excluded.updated_at
            """, bindings: [
                .text(sessionID),
                .text(speaker.clusterID),
                .text(speaker.displayLabel),
                .text(speaker.sourceTrack.rawValue),
                .double(speaker.speakingDurationSeconds),
                speaker.matchedProfileID.map(SQLiteValue.text) ?? .null,
                speaker.matchedProfileName.map(SQLiteValue.text) ?? .null,
                speaker.matchConfidence.map(SQLiteValue.double) ?? .null,
                .text(speaker.assignmentState.rawValue),
                speaker.representativeText.map(SQLiteValue.text) ?? .null,
                .null,
                .text(now),
                .text(now)
            ])
        }
    }

    public func saveSessionSpeakerEmbedding(sessionID: String, clusterID: String, vector: [Double], embeddingSpace: String = "legacy-pyannote-embedding") throws {
        try validateSessionID(sessionID)
        let vectorJSON = String(data: try JSONEncoder.memoir.encode(vector), encoding: .utf8) ?? "[]"
        try database.execute("""
            UPDATE session_speakers
            SET embedding_vector_json = ?, embedding_space = ?, updated_at = ?
            WHERE session_id = ? AND cluster_id = ?
        """, bindings: [
            .text(vectorJSON),
            .text(embeddingSpace),
            .text(Time.nowString()),
            .text(sessionID),
            .text(clusterID)
        ])
    }

    public func sessionSpeakerEmbedding(sessionID: String, clusterID: String) throws -> [Double]? {
        try validateSessionID(sessionID)
        guard
            let row = try database.fetchOne("""
                SELECT embedding_vector_json
                FROM session_speakers
                WHERE session_id = ? AND cluster_id = ?
            """, bindings: [.text(sessionID), .text(clusterID)]),
            let vectorJSON = row["embedding_vector_json"]?.stringValue,
            let data = vectorJSON.data(using: .utf8)
        else {
            return nil
        }
        return try JSONDecoder.memoir.decode([Double].self, from: data)
    }

    public func listSpeakerProfiles(includeArchived: Bool = false) throws -> [SpeakerProfile] {
        let query = includeArchived
            ? """
              SELECT p.speaker_profile_id, p.display_name, p.archived, p.last_seen_at,
                     COUNT(e.embedding_id) AS sample_count
              FROM speaker_profiles p
              LEFT JOIN speaker_profile_embeddings e ON e.speaker_profile_id = p.speaker_profile_id
              GROUP BY p.speaker_profile_id
              ORDER BY p.archived ASC, p.display_name COLLATE NOCASE ASC
              """
            : """
              SELECT p.speaker_profile_id, p.display_name, p.archived, p.last_seen_at,
                     COUNT(e.embedding_id) AS sample_count
              FROM speaker_profiles p
              LEFT JOIN speaker_profile_embeddings e ON e.speaker_profile_id = p.speaker_profile_id
              WHERE p.archived = 0
              GROUP BY p.speaker_profile_id
              ORDER BY p.display_name COLLATE NOCASE ASC
              """
        return try database.fetchAll(query).map { row in
            SpeakerProfile(
                id: row["speaker_profile_id"]?.stringValue ?? "",
                name: row["display_name"]?.stringValue ?? "Speaker",
                sampleCount: row["sample_count"]?.intValue ?? 0,
                lastSeenAt: row["last_seen_at"]?.stringValue,
                archived: row["archived"]?.boolValue ?? false
            )
        }
    }

    public func speakerProfileEmbeddings(embeddingSpace: String = "legacy-pyannote-embedding") throws -> [String: [[Double]]] {
        let rows = try database.fetchAll("""
            SELECT speaker_profile_id, vector_json
            FROM speaker_profile_embeddings WHERE embedding_space = ?
        """, bindings: [.text(embeddingSpace)])
        var results: [String: [[Double]]] = [:]
        for row in rows {
            guard
                let profileID = row["speaker_profile_id"]?.stringValue,
                let vectorJSON = row["vector_json"]?.stringValue,
                let data = vectorJSON.data(using: .utf8),
                let vector = try? JSONDecoder.memoir.decode([Double].self, from: data)
            else {
                continue
            }
            results[profileID, default: []].append(vector)
        }
        return results
    }

    public func createSpeakerProfile(name: String) throws -> SpeakerProfile {
        let profile = SpeakerProfile(id: UUID().uuidString, name: name, sampleCount: 0, lastSeenAt: nil, archived: false)
        let now = Time.nowString()
        try database.execute("""
            INSERT INTO speaker_profiles (speaker_profile_id, display_name, archived, created_at, updated_at, last_seen_at)
            VALUES (?, ?, 0, ?, ?, NULL)
        """, bindings: [
            .text(profile.id),
            .text(profile.name),
            .text(now),
            .text(now)
        ])
        return profile
    }

    public func renameSpeakerProfile(profileID: String, name: String) throws {
        let assignments = try database.fetchAll("SELECT session_id, cluster_id FROM session_speakers WHERE matched_profile_id = ?", bindings: [.text(profileID)])
        try database.execute("""
            UPDATE speaker_profiles
            SET display_name = ?, updated_at = ?
            WHERE speaker_profile_id = ?
        """, bindings: [.text(name), .text(Time.nowString()), .text(profileID)])
        try database.execute("""
            UPDATE session_speakers
            SET matched_profile_name = ?, display_label = ?, updated_at = ?
            WHERE matched_profile_id = ?
        """, bindings: [.text(name), .text(name), .text(Time.nowString()), .text(profileID)])
        for row in assignments {
            if let sessionID = row["session_id"]?.stringValue, let clusterID = row["cluster_id"]?.stringValue {
                try relabelArtifacts(sessionID: sessionID, clusterID: clusterID, profileID: profileID, profileName: name)
            }
        }
    }

    public func archiveSpeakerProfile(profileID: String) throws {
        try database.execute("""
            UPDATE speaker_profiles
            SET archived = 1, updated_at = ?
            WHERE speaker_profile_id = ?
        """, bindings: [.text(Time.nowString()), .text(profileID)])
    }

    public func saveEmbedding(profileID: String, sessionID: String, clusterID: String, vector: [Double], qualityScore: Double) throws {
        let now = Time.nowString()
        let space = try database.fetchOne("SELECT embedding_space FROM session_speakers WHERE session_id = ? AND cluster_id = ?", bindings: [.text(sessionID), .text(clusterID)])?["embedding_space"]?.stringValue ?? "legacy-pyannote-embedding"
        let vectorJSON = String(data: try JSONEncoder.memoir.encode(vector), encoding: .utf8) ?? "[]"
        try database.execute("""
            INSERT INTO speaker_profile_embeddings (
                embedding_id, speaker_profile_id, source_session_id, cluster_id, vector_json, quality_score, created_at, embedding_space
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, bindings: [
            .text(UUID().uuidString),
            .text(profileID),
            .text(sessionID),
            .text(clusterID),
            .text(vectorJSON),
            .double(qualityScore),
            .text(now),
            .text(space)
        ])
        try database.execute("""
            UPDATE speaker_profiles
            SET updated_at = ?, last_seen_at = ?
            WHERE speaker_profile_id = ?
        """, bindings: [.text(now), .text(now), .text(profileID)])
    }

    public func assignSessionSpeaker(sessionID: String, clusterID: String, profileID: String, profileName: String) throws {
        try validateSessionID(sessionID)
        try database.execute("""
            UPDATE session_speakers
            SET matched_profile_id = ?,
                matched_profile_name = ?,
                display_label = ?,
                assignment_state = ?,
                match_confidence = 1.0,
                updated_at = ?
            WHERE session_id = ? AND cluster_id = ?
        """, bindings: [
            .text(profileID),
            .text(profileName),
            .text(profileName),
            .text(SpeakerAssignmentState.confirmed.rawValue),
            .text(Time.nowString()),
            .text(sessionID),
            .text(clusterID)
        ])

        try relabelArtifacts(sessionID: sessionID, clusterID: clusterID, profileID: profileID, profileName: profileName)
    }

    private func buildCreateResponse(sessionID: String, baseURL: String) -> CreateSessionResponse {
        let path = baseURL.isEmpty
            ? "/v1/sessions/\(sessionID)/files"
            : "\(baseURL)/v1/sessions/\(sessionID)/files"
        return CreateSessionResponse(
            sessionID: sessionID,
            ingestionState: .created,
            uploadURLs: [
                "metadata": "\(path)/metadata",
                "system": "\(path)/system",
                "mic": "\(path)/mic"
            ]
        )
    }

    private func verifyUploadDescriptor(sessionID: String, kind: UploadFileKind, descriptor: UploadedFileDescriptor?) throws {
        guard let descriptor else {
            throw ProcessorError(code: "missing_required_file", message: "Missing \(kind.rawValue) upload descriptor.", retryable: false)
        }

        guard let row = try database.fetchOne("SELECT \(kind.rawValue)_size AS size, \(kind.rawValue)_sha256 AS sha256 FROM sessions WHERE session_id = ?", bindings: [.text(sessionID)]) else {
            throw ProcessorError(code: "session_not_found", message: "Session does not exist.", retryable: false)
        }

        guard row["size"]?.intValue == descriptor.sizeBytes, row["sha256"]?.stringValue == descriptor.sha256 else {
            throw ProcessorError(code: "checksum_mismatch", message: "Uploaded file metadata does not match stored file.", retryable: false)
        }
    }

    func validateSessionID(_ value: String) throws {
        guard UUID(uuidString: value) != nil else {
            throw ProcessorError(code: "invalid_request", message: "session_id must be a UUID.", retryable: false)
        }
        let root = ProcessorPaths.sessionsDirectory(for: config).resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let path = ProcessorPaths.sessionDirectory(for: config, sessionID: value).resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(root) else {
            throw ProcessorError(code: "invalid_request", message: "Session path escapes storage.", retryable: false)
        }
    }

    private func createSessionDirectories(sessionID: String) throws {
        try fileManager.createDirectory(at: ProcessorPaths.sessionDirectory(for: config, sessionID: sessionID), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: ProcessorPaths.processingDirectory(for: config, sessionID: sessionID), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: ProcessorPaths.workDirectory(for: config, sessionID: sessionID), withIntermediateDirectories: true)
    }

    private func saveIdempotency<T: Encodable>(endpoint: APIRequestContext, key: String, requestHash: String, response: T) throws {
        let json = String(data: try JSONEncoder.memoir.encode(response), encoding: .utf8) ?? "{}"
        try database.execute("""
            INSERT OR REPLACE INTO idempotency_records (endpoint, idempotency_key, request_hash, response_json, created_at)
            VALUES (?, ?, ?, ?, ?)
        """, bindings: [
            .text(endpoint.rawValue),
            .text(key),
            .text(requestHash),
            .text(json),
            .text(Time.nowString())
        ])
    }

    private func idempotentResponse<T: Decodable>(for endpoint: APIRequestContext, key: String, requestHash: String, type: T.Type) throws -> T? {
        guard let row = try database.fetchOne("""
            SELECT request_hash, response_json
            FROM idempotency_records
            WHERE endpoint = ? AND idempotency_key = ?
        """, bindings: [.text(endpoint.rawValue), .text(key)]) else {
            return nil
        }

        guard row["request_hash"]?.stringValue == requestHash else {
            throw ProcessorError(code: "invalid_request", message: "Idempotency key was reused with a different payload.", retryable: false)
        }

        guard let json = row["response_json"]?.stringValue?.data(using: .utf8) else {
            throw ProcessorError(code: "internal_error", message: "Stored idempotency response is invalid.", retryable: false)
        }
        return try JSONDecoder.memoir.decode(T.self, from: json)
    }

    private func jsonHash<T: Encodable>(_ value: T) throws -> String {
        Hashing.sha256Hex(for: try JSONEncoder.memoir.encode(value))
    }

    private func writeJobArtifact(sessionID: String) throws {
        guard let row = try database.fetchOne("SELECT * FROM sessions WHERE session_id = ?", bindings: [.text(sessionID)]) else { return }
        let job = JobArtifact(
            jobID: sessionID,
            sessionID: sessionID,
            status: row["processing_state"]?.stringValue ?? row["ingestion_state"]?.stringValue ?? IngestionState.created.rawValue,
            attempt: row["attempt"]?.intValue ?? 0,
            createdAt: row["created_at"]?.stringValue ?? Time.nowString(),
            updatedAt: row["updated_at"]?.stringValue ?? Time.nowString(),
            engine: config.transcriptionEngine,
            model: config.modelName,
            error: row["error_code"]?.stringValue.map {
                ProcessorError(code: $0, message: row["error_message"]?.stringValue ?? "Unknown error", retryable: row["retryable"]?.boolValue ?? false)
            }
        )
        let url = ProcessorPaths.processingDirectory(for: config, sessionID: sessionID).appendingPathComponent("job.json")
        try JSONEncoder.memoir.encode(job).write(to: url, options: .atomic)
    }

    private func relabelArtifacts(sessionID: String, clusterID: String, profileID: String, profileName: String) throws {
        let transcriptURL = artifactPath(sessionID: sessionID, name: "transcript.json")
        if fileManager.fileExists(atPath: transcriptURL.path) {
            var transcript = try JSONDecoder.memoir.decode(CanonicalTranscript.self, from: Data(contentsOf: transcriptURL))
            transcript = CanonicalTranscript(
                sessionID: transcript.sessionID,
                sourceFiles: transcript.sourceFiles,
                transcription: transcript.transcription,
                segments: transcript.segments.map { segment in
                    guard (segment.clusterID ?? segment.speakerID) == clusterID else { return segment }
                    return TranscriptSegment(
                        id: segment.id,
                        start: segment.start,
                        end: segment.end,
                        speaker: profileName,
                        speakerID: profileID,
                        clusterID: clusterID,
                        speakerSource: .manual,
                        speakerConfidence: 1.0,
                        text: segment.text
                    )
                }
            )
            try writeTranscriptArtifacts(sessionID: sessionID, transcript: transcript)
        }

        let diarizationURL = artifactPath(sessionID: sessionID, name: "diarization.json")
        if fileManager.fileExists(atPath: diarizationURL.path) {
            var artifact = try JSONDecoder.memoir.decode(DiarizationArtifact.self, from: Data(contentsOf: diarizationURL))
            artifact = DiarizationArtifact(
                sessionID: artifact.sessionID,
                runtime: artifact.runtime,
                backend: artifact.backend,
                turns: artifact.turns.map { turn in
                    guard turn.clusterID == clusterID else { return turn }
                    return DiarizationTurn(
                        id: turn.id,
                        clusterID: turn.clusterID,
                        start: turn.start,
                        end: turn.end,
                        sourceTrack: turn.sourceTrack,
                        matchedProfileID: profileID,
                        matchedProfileName: profileName,
                        matchConfidence: 1.0,
                        representativeText: turn.representativeText
                    )
                }
            )
            try writeDiarizationArtifact(sessionID: sessionID, artifact: artifact)
        }
    }

    private static func srtTimestamp(_ seconds: Double) -> String {
        let totalMilliseconds = Int((seconds * 1000.0).rounded())
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds % 3_600_000) / 60_000
        let secs = (totalMilliseconds % 60_000) / 1000
        let millis = totalMilliseconds % 1000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
    }
}
