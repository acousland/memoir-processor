import Foundation

public enum IngestionState: String, Codable, CaseIterable, Sendable {
    case created
    case uploading
    case uploaded
    case readyForProcessing = "ready_for_processing"
    case rejected
}

public enum ProcessingState: String, Codable, CaseIterable, Sendable {
    case queued
    case validating
    case transcribing
    case diarizing
    case writingArtifacts = "writing_artifacts"
    case completed
    case failed
    case retryPending = "retry_pending"
}

public enum UploadFileKind: String, Codable, CaseIterable, Sendable {
    case metadata
    case system
    case mic

    public var fileName: String {
        switch self {
        case .metadata: return "metadata.json"
        case .system: return "system.wav"
        case .mic: return "mic.wav"
        }
    }
}

public struct ProcessorError: Codable, Sendable, Error {
    public let code: String
    public let message: String
    public let retryable: Bool

    public init(code: String, message: String, retryable: Bool) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }
}

extension ProcessorError: LocalizedError {
    public var errorDescription: String? {
        message
    }
}

public struct ErrorEnvelope: Codable, Sendable {
    public let error: ProcessorError

    public init(error: ProcessorError) {
        self.error = error
    }
}

public struct RecorderInfo: Codable, Sendable {
    public let deviceID: String
    public let appVersion: String
    public let build: String

    public init(deviceID: String, appVersion: String, build: String) {
        self.deviceID = deviceID
        self.appVersion = appVersion
        self.build = build
    }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case appVersion = "app_version"
        case build
    }
}

public struct ExpectedFiles: Codable, Sendable {
    public let metadata: Bool
    public let system: Bool
    public let mic: Bool

    public init(metadata: Bool = true, system: Bool = true, mic: Bool = false) {
        self.metadata = metadata
        self.system = system
        self.mic = mic
    }
}

public struct CreateSessionRequest: Codable, Sendable {
    public let sessionID: String
    public let sessionName: String
    public let recordingStartedAt: String
    public let recordingEndedAt: String
    public let recorder: RecorderInfo
    public let expectedFiles: ExpectedFiles

    public init(
        sessionID: String,
        sessionName: String,
        recordingStartedAt: String,
        recordingEndedAt: String,
        recorder: RecorderInfo,
        expectedFiles: ExpectedFiles
    ) {
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.recordingStartedAt = recordingStartedAt
        self.recordingEndedAt = recordingEndedAt
        self.recorder = recorder
        self.expectedFiles = expectedFiles
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case sessionName = "session_name"
        case recordingStartedAt = "recording_started_at"
        case recordingEndedAt = "recording_ended_at"
        case recorder
        case expectedFiles = "expected_files"
    }
}

public struct CreateSessionResponse: Codable, Sendable {
    public let sessionID: String
    public let ingestionState: IngestionState
    public let uploadURLs: [String: String]

    public init(sessionID: String, ingestionState: IngestionState, uploadURLs: [String: String]) {
        self.sessionID = sessionID
        self.ingestionState = ingestionState
        self.uploadURLs = uploadURLs
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case ingestionState = "ingestion_state"
        case uploadURLs = "upload_urls"
    }
}

public struct UploadedFileDescriptor: Codable, Sendable {
    public let sizeBytes: Int
    public let sha256: String

    public init(sizeBytes: Int, sha256: String) {
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }

    enum CodingKeys: String, CodingKey {
        case sizeBytes = "size_bytes"
        case sha256
    }
}

public struct CompleteSessionRequest: Codable, Sendable {
    public let uploadedFiles: [String: UploadedFileDescriptor]

    public init(uploadedFiles: [String: UploadedFileDescriptor]) {
        self.uploadedFiles = uploadedFiles
    }

    enum CodingKeys: String, CodingKey {
        case uploadedFiles = "uploaded_files"
    }
}

public struct CompleteSessionResponse: Codable, Sendable {
    public let sessionID: String
    public let ingestionState: IngestionState
    public let processingState: ProcessingState
    public let acceptedAt: String

    public init(sessionID: String, ingestionState: IngestionState, processingState: ProcessingState, acceptedAt: String) {
        self.sessionID = sessionID
        self.ingestionState = ingestionState
        self.processingState = processingState
        self.acceptedAt = acceptedAt
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case ingestionState = "ingestion_state"
        case processingState = "processing_state"
        case acceptedAt = "accepted_at"
    }
}

public struct FileUploadResponse: Codable, Sendable {
    public let sessionID: String
    public let file: String
    public let sizeBytes: Int
    public let sha256: String
    public let accepted: Bool

    public init(sessionID: String, file: String, sizeBytes: Int, sha256: String, accepted: Bool) {
        self.sessionID = sessionID
        self.file = file
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.accepted = accepted
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case file
        case sizeBytes = "size_bytes"
        case sha256
        case accepted
    }
}

public struct ReceivedFiles: Codable, Sendable {
    public let metadata: Bool
    public let system: Bool
    public let mic: Bool
}

public struct SessionStatusResponse: Codable, Sendable {
    public let sessionID: String
    public let sessionName: String
    public let ingestionState: IngestionState
    public let processingState: ProcessingState?
    public let createdAt: String
    public let updatedAt: String
    public let expectedFiles: ExpectedFiles
    public let receivedFiles: ReceivedFiles
    public let error: ProcessorError?

    public init(
        sessionID: String,
        sessionName: String,
        ingestionState: IngestionState,
        processingState: ProcessingState?,
        createdAt: String,
        updatedAt: String,
        expectedFiles: ExpectedFiles,
        receivedFiles: ReceivedFiles,
        error: ProcessorError?
    ) {
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.ingestionState = ingestionState
        self.processingState = processingState
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expectedFiles = expectedFiles
        self.receivedFiles = receivedFiles
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case sessionName = "session_name"
        case ingestionState = "ingestion_state"
        case processingState = "processing_state"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case expectedFiles = "expected_files"
        case receivedFiles = "received_files"
        case error
    }
}

public struct AppConfig: Codable, Sendable {
    public let bindHost: String
    public let port: Int
    public let tlsEnabled: Bool
    public let authToken: String
    public let transcriptionEngine: String
    public let modelName: String
    public let maxRetries: Int
    public let diarizationEnabled: Bool
    public let outputFormats: [String]
    public let storageRoot: String
    public let languageHint: String?

    public init(
        bindHost: String,
        port: Int,
        tlsEnabled: Bool,
        authToken: String,
        transcriptionEngine: String,
        modelName: String,
        maxRetries: Int,
        diarizationEnabled: Bool,
        outputFormats: [String],
        storageRoot: String,
        languageHint: String?
    ) {
        self.bindHost = bindHost
        self.port = port
        self.tlsEnabled = tlsEnabled
        self.authToken = authToken
        self.transcriptionEngine = transcriptionEngine
        self.modelName = modelName
        self.maxRetries = maxRetries
        self.diarizationEnabled = diarizationEnabled
        self.outputFormats = outputFormats
        self.storageRoot = storageRoot
        self.languageHint = languageHint
    }

    public static func `default`() -> AppConfig {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let root = appSupport.appendingPathComponent("Memoir Processor", isDirectory: true).path
        return AppConfig(
            bindHost: "0.0.0.0",
            port: 8765,
            tlsEnabled: true,
            authToken: UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            transcriptionEngine: "whisper",
            modelName: "base",
            maxRetries: 3,
            diarizationEnabled: false,
            outputFormats: ["json", "txt", "srt"],
            storageRoot: root,
            languageHint: nil
        )
    }

    enum CodingKeys: String, CodingKey {
        case bindHost
        case port
        case tlsEnabled
        case authToken
        case transcriptionEngine
        case modelName
        case maxRetries
        case diarizationEnabled
        case outputFormats
        case storageRoot
        case languageHint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bindHost = try container.decode(String.self, forKey: .bindHost)
        port = try container.decode(Int.self, forKey: .port)
        tlsEnabled = try container.decodeIfPresent(Bool.self, forKey: .tlsEnabled) ?? true
        authToken = try container.decode(String.self, forKey: .authToken)
        transcriptionEngine = try container.decode(String.self, forKey: .transcriptionEngine)
        modelName = try container.decode(String.self, forKey: .modelName)
        maxRetries = try container.decode(Int.self, forKey: .maxRetries)
        diarizationEnabled = try container.decode(Bool.self, forKey: .diarizationEnabled)
        outputFormats = try container.decode([String].self, forKey: .outputFormats)
        storageRoot = try container.decode(String.self, forKey: .storageRoot)
        languageHint = try container.decodeIfPresent(String.self, forKey: .languageHint)
    }

    public func updating(
        bindHost: String? = nil,
        port: Int? = nil,
        tlsEnabled: Bool? = nil,
        authToken: String? = nil,
        transcriptionEngine: String? = nil,
        modelName: String? = nil,
        maxRetries: Int? = nil,
        diarizationEnabled: Bool? = nil,
        outputFormats: [String]? = nil,
        storageRoot: String? = nil,
        languageHint: String?? = nil
    ) -> AppConfig {
        AppConfig(
            bindHost: bindHost ?? self.bindHost,
            port: port ?? self.port,
            tlsEnabled: tlsEnabled ?? self.tlsEnabled,
            authToken: authToken ?? self.authToken,
            transcriptionEngine: transcriptionEngine ?? self.transcriptionEngine,
            modelName: modelName ?? self.modelName,
            maxRetries: maxRetries ?? self.maxRetries,
            diarizationEnabled: diarizationEnabled ?? self.diarizationEnabled,
            outputFormats: outputFormats ?? self.outputFormats,
            storageRoot: storageRoot ?? self.storageRoot,
            languageHint: languageHint ?? self.languageHint
        )
    }
}

public struct AudioMetadata: Codable, Sendable {
    public let filename: String
    public let sampleRateHz: Double
    public let channels: Int
    public let durationSeconds: Double

    enum CodingKeys: String, CodingKey {
        case filename
        case sampleRateHz = "sample_rate_hz"
        case channels
        case durationSeconds = "duration_seconds"
    }
}

public struct MetadataFile: Codable, Sendable {
    public let sessionID: String
    public let sessionName: String
    public let recordingStartedAt: String
    public let recordingEndedAt: String
    public let timezone: String
    public let systemAudio: AudioMetadata
    public let micAudio: AudioMetadata?
    public let languageHint: String?
    public let notes: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case sessionName = "session_name"
        case recordingStartedAt = "recording_started_at"
        case recordingEndedAt = "recording_ended_at"
        case timezone
        case systemAudio = "system_audio"
        case micAudio = "mic_audio"
        case languageHint = "language_hint"
        case notes
    }
}

public struct TranscriptSegment: Codable, Sendable, Identifiable {
    public let id: UUID
    public let start: Double
    public let end: Double
    public let speaker: String?
    public let text: String

    public init(id: UUID = UUID(), start: Double, end: Double, speaker: String?, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
    }
}

public struct CanonicalTranscript: Codable, Sendable {
    public let sessionID: String
    public let sourceFiles: [String: String]
    public let transcription: TranscriptionMetadata
    public let segments: [TranscriptSegment]

    public init(sessionID: String, sourceFiles: [String: String], transcription: TranscriptionMetadata, segments: [TranscriptSegment]) {
        self.sessionID = sessionID
        self.sourceFiles = sourceFiles
        self.transcription = transcription
        self.segments = segments
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case sourceFiles = "source_files"
        case transcription
        case segments
    }
}

public struct TranscriptionMetadata: Codable, Sendable {
    public let engine: String
    public let model: String
    public let language: String

    public init(engine: String, model: String, language: String) {
        self.engine = engine
        self.model = model
        self.language = language
    }
}

public struct JobArtifact: Codable, Sendable {
    public let jobID: String
    public let sessionID: String
    public let status: String
    public let attempt: Int
    public let createdAt: String
    public let updatedAt: String
    public let engine: String
    public let model: String
    public let error: ProcessorError?

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case sessionID = "session_id"
        case status
        case attempt
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case engine
        case model
        case error
    }
}

public struct SessionListItem: Identifiable, Sendable {
    public let id: String
    public let sessionName: String
    public let ingestionState: IngestionState
    public let processingState: ProcessingState?
    public let attempt: Int
    public let createdAt: String
    public let updatedAt: String
    public let errorMessage: String?
}

public struct WorkerTranscriptResult: Codable, Sendable {
    public let engine: String
    public let model: String
    public let language: String
    public let segments: [TranscriptSegment]
}

public enum APIRequestContext: String {
    case create
    case complete
}
