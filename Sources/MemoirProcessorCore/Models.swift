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
    public let warnings: [SessionWarning]

    public init(
        sessionID: String,
        sessionName: String,
        ingestionState: IngestionState,
        processingState: ProcessingState?,
        createdAt: String,
        updatedAt: String,
        expectedFiles: ExpectedFiles,
        receivedFiles: ReceivedFiles,
        error: ProcessorError?,
        warnings: [SessionWarning] = []
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
        self.warnings = warnings
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
        case warnings
    }
}

public enum DiarizationEngine: String, Codable, CaseIterable, Sendable {
    case fluidAudio = "fluidaudio"
    case pyannote = "pyannote"

    public var title: String {
        switch self {
        case .fluidAudio: return "FluidAudio · Core ML"
        case .pyannote: return "Pyannote Community-1 · GPU"
        }
    }

    public var embeddingSpace: String {
        switch self {
        case .fluidAudio: return "fluidaudio-offline-vbx-0.17.7"
        case .pyannote: return "pyannote-community-1-resnet34"
        }
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
    public let diarizationEngine: DiarizationEngine
    public let speakerAutoMatchThreshold: Double
    public let allowCPUFallbackForDiarization: Bool
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
        diarizationEngine: DiarizationEngine = .fluidAudio,
        speakerAutoMatchThreshold: Double,
        allowCPUFallbackForDiarization: Bool,
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
        self.diarizationEngine = diarizationEngine
        self.speakerAutoMatchThreshold = speakerAutoMatchThreshold
        self.allowCPUFallbackForDiarization = allowCPUFallbackForDiarization
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
            transcriptionEngine: "whisperkit",
            modelName: "base",
            maxRetries: 3,
            diarizationEnabled: false,
            speakerAutoMatchThreshold: 0.86,
            allowCPUFallbackForDiarization: true,
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
        case diarizationEngine
        case speakerAutoMatchThreshold
        case allowCPUFallbackForDiarization
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
        diarizationEngine = try container.decodeIfPresent(DiarizationEngine.self, forKey: .diarizationEngine) ?? .fluidAudio
        speakerAutoMatchThreshold = try container.decodeIfPresent(Double.self, forKey: .speakerAutoMatchThreshold) ?? 0.86
        allowCPUFallbackForDiarization = try container.decodeIfPresent(Bool.self, forKey: .allowCPUFallbackForDiarization) ?? true
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
        diarizationEngine: DiarizationEngine? = nil,
        speakerAutoMatchThreshold: Double? = nil,
        allowCPUFallbackForDiarization: Bool? = nil,
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
            diarizationEngine: diarizationEngine ?? self.diarizationEngine,
            speakerAutoMatchThreshold: speakerAutoMatchThreshold ?? self.speakerAutoMatchThreshold,
            allowCPUFallbackForDiarization: allowCPUFallbackForDiarization ?? self.allowCPUFallbackForDiarization,
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

public struct EchoCancellationMetadata: Codable, Sendable {
    public let applied: Bool
    public let mode: String
}

public struct StreamTimingMetadata: Codable, Sendable {
    public let firstSampleHostTimeNS: String
    public let startOffsetSeconds: Double
    public let sampleRateHz: Int
    public let durationFrames: Int
    public let latencyFrames: Int

    enum CodingKeys: String, CodingKey {
        case firstSampleHostTimeNS = "first_sample_host_time_ns"
        case startOffsetSeconds = "start_offset_seconds"
        case sampleRateHz = "sample_rate_hz"
        case durationFrames = "duration_frames"
        case latencyFrames = "latency_frames"
    }
}

public struct StreamSyncStreamsMetadata: Codable, Sendable {
    public let system: StreamTimingMetadata?
    public let mic: StreamTimingMetadata?
}

public struct StreamSyncMetadata: Codable, Sendable {
    public let schemaVersion: Int
    public let timeline: String
    public let sessionZeroHostTimeNS: String
    public let referenceStream: String
    public let alignedWavExport: Bool
    public let driftCorrected: Bool
    public let estimatedDriftPPM: Double
    public let relativeOffsetToSystemSeconds: Double?
    public let syncConfidence: String
    public let echoCancellation: EchoCancellationMetadata
    public let streams: StreamSyncStreamsMetadata

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case timeline
        case sessionZeroHostTimeNS = "session_zero_host_time_ns"
        case referenceStream = "reference_stream"
        case alignedWavExport = "aligned_wav_export"
        case driftCorrected = "drift_corrected"
        case estimatedDriftPPM = "estimated_drift_ppm"
        case relativeOffsetToSystemSeconds = "relative_offset_to_system_seconds"
        case syncConfidence = "sync_confidence"
        case echoCancellation = "echo_cancellation"
        case streams
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
    public let streamSync: StreamSyncMetadata?

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
        case streamSync = "stream_sync"
    }
}

public enum SpeakerSource: String, Codable, CaseIterable, Sendable {
    case system
    case mic
    case diarization
    case manual
    case unknown
}

public struct TranscriptSegment: Codable, Sendable, Identifiable {
    public let id: UUID
    public let start: Double
    public let end: Double
    public let speaker: String?
    public let speakerID: String?
    public let clusterID: String?
    public let speakerSource: SpeakerSource?
    public let speakerConfidence: Double?
    public let text: String

    public init(
        id: UUID = UUID(),
        start: Double,
        end: Double,
        speaker: String?,
        speakerID: String? = nil,
        clusterID: String? = nil,
        speakerSource: SpeakerSource? = nil,
        speakerConfidence: Double? = nil,
        text: String
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.speaker = speaker
        self.speakerID = speakerID
        self.clusterID = clusterID
        self.speakerSource = speakerSource
        self.speakerConfidence = speakerConfidence
        self.text = text
    }

    enum CodingKeys: String, CodingKey {
        case id
        case start
        case end
        case speaker
        case speakerID = "speaker_id"
        case clusterID = "cluster_id"
        case speakerSource = "speaker_source"
        case speakerConfidence = "speaker_confidence"
        case text
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try container.decode(Double.self, forKey: .start)
        end = try container.decode(Double.self, forKey: .end)
        speaker = try container.decodeIfPresent(String.self, forKey: .speaker)
        speakerID = try container.decodeIfPresent(String.self, forKey: .speakerID)
        clusterID = try container.decodeIfPresent(String.self, forKey: .clusterID)
        speakerSource = try container.decodeIfPresent(SpeakerSource.self, forKey: .speakerSource)
        speakerConfidence = try container.decodeIfPresent(Double.self, forKey: .speakerConfidence)
        text = try container.decode(String.self, forKey: .text)
    }
}

public struct DiarizationTurn: Codable, Sendable, Identifiable {
    public let id: UUID
    public let clusterID: String
    public let start: Double
    public let end: Double
    public let sourceTrack: SpeakerSource
    public let matchedProfileID: String?
    public let matchedProfileName: String?
    public let matchConfidence: Double?
    public let representativeText: String?

    public init(
        id: UUID = UUID(),
        clusterID: String,
        start: Double,
        end: Double,
        sourceTrack: SpeakerSource,
        matchedProfileID: String? = nil,
        matchedProfileName: String? = nil,
        matchConfidence: Double? = nil,
        representativeText: String? = nil
    ) {
        self.id = id
        self.clusterID = clusterID
        self.start = start
        self.end = end
        self.sourceTrack = sourceTrack
        self.matchedProfileID = matchedProfileID
        self.matchedProfileName = matchedProfileName
        self.matchConfidence = matchConfidence
        self.representativeText = representativeText
    }

    enum CodingKeys: String, CodingKey {
        case id
        case clusterID = "cluster_id"
        case start
        case end
        case sourceTrack = "source_track"
        case matchedProfileID = "matched_profile_id"
        case matchedProfileName = "matched_profile_name"
        case matchConfidence = "match_confidence"
        case representativeText = "representative_text"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        clusterID = try c.decode(String.self, forKey: .clusterID)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        sourceTrack = try c.decode(SpeakerSource.self, forKey: .sourceTrack)
        matchedProfileID = try c.decodeIfPresent(String.self, forKey: .matchedProfileID)
        matchedProfileName = try c.decodeIfPresent(String.self, forKey: .matchedProfileName)
        matchConfidence = try c.decodeIfPresent(Double.self, forKey: .matchConfidence)
        representativeText = try c.decodeIfPresent(String.self, forKey: .representativeText)
    }

}

public struct DiarizationArtifact: Codable, Sendable {
    public let sessionID: String
    public let runtime: String
    public let backend: String
    public let turns: [DiarizationTurn]

    public init(sessionID: String, runtime: String, backend: String, turns: [DiarizationTurn]) {
        self.sessionID = sessionID
        self.runtime = runtime
        self.backend = backend
        self.turns = turns
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case runtime
        case backend
        case turns
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
    public let runtime: String?
    public let backend: String?

    public init(engine: String, model: String, language: String, runtime: String? = nil, backend: String? = nil) {
        self.engine = engine
        self.model = model
        self.language = language
        self.runtime = runtime
        self.backend = backend
    }
}

public struct SessionWarning: Codable, Sendable, Identifiable {
    public let id: UUID
    public let code: String
    public let message: String
    public let createdAt: String

    public init(id: UUID = UUID(), code: String, message: String, createdAt: String) {
        self.id = id
        self.code = code
        self.message = message
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case code
        case message
        case createdAt = "created_at"
    }
}

public enum SpeakerAssignmentState: String, Codable, CaseIterable, Sendable {
    case anonymous
    case suggested
    case confirmed
}

public struct SessionSpeaker: Codable, Sendable, Identifiable {
    public let id: String
    public let sessionID: String
    public let clusterID: String
    public let displayLabel: String
    public let sourceTrack: SpeakerSource
    public let speakingDurationSeconds: Double
    public let matchedProfileID: String?
    public let matchedProfileName: String?
    public let matchConfidence: Double?
    public let assignmentState: SpeakerAssignmentState
    public let representativeText: String?

    public init(
        sessionID: String,
        clusterID: String,
        displayLabel: String,
        sourceTrack: SpeakerSource,
        speakingDurationSeconds: Double,
        matchedProfileID: String? = nil,
        matchedProfileName: String? = nil,
        matchConfidence: Double? = nil,
        assignmentState: SpeakerAssignmentState,
        representativeText: String? = nil
    ) {
        self.id = "\(sessionID):\(clusterID)"
        self.sessionID = sessionID
        self.clusterID = clusterID
        self.displayLabel = displayLabel
        self.sourceTrack = sourceTrack
        self.speakingDurationSeconds = speakingDurationSeconds
        self.matchedProfileID = matchedProfileID
        self.matchedProfileName = matchedProfileName
        self.matchConfidence = matchConfidence
        self.assignmentState = assignmentState
        self.representativeText = representativeText
    }
}

public struct SpeakerProfile: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let sampleCount: Int
    public let lastSeenAt: String?
    public let archived: Bool

    public init(id: String, name: String, sampleCount: Int, lastSeenAt: String?, archived: Bool) {
        self.id = id
        self.name = name
        self.sampleCount = sampleCount
        self.lastSeenAt = lastSeenAt
        self.archived = archived
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
    public let warningCount: Int
}

public struct WorkerTranscriptResult: Codable, Sendable {
    public let engine: String
    public let model: String
    public let language: String
    public let runtime: String?
    public let backend: String?
    public let segments: [TranscriptSegment]

    public init(
        engine: String,
        model: String,
        language: String,
        runtime: String? = nil,
        backend: String? = nil,
        segments: [TranscriptSegment]
    ) {
        self.engine = engine
        self.model = model
        self.language = language
        self.runtime = runtime
        self.backend = backend
        self.segments = segments
    }
}

public struct SpeakerEmbeddingResult: Codable, Sendable {
    public let clusterID: String
    public let durationSeconds: Double
    public let representativeText: String?
    public let embedding: [Double]
    public let sourceTrack: SpeakerSource
}

public struct WorkerDiarizationResult: Codable, Sendable {
    public let runtime: String
    public let backend: String
    public let turns: [DiarizationTurn]
    public let embeddings: [SpeakerEmbeddingResult]
}

public enum APIRequestContext: String {
    case create
    case complete
}
