import Foundation
import Testing
@testable import MemoirProcessorCore

struct MemoirProcessorCoreTests {
    @Test
    func createSessionWritesStatus() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let config = AppConfig(
            bindHost: "127.0.0.1",
            port: 8765,
            tlsEnabled: false,
            authToken: "token",
            transcriptionEngine: "whisperkit",
            modelName: "base",
            maxRetries: 3,
            diarizationEnabled: false,
            speakerAutoMatchThreshold: 0.86,
            allowCPUFallbackForDiarization: true,
            outputFormats: ["json", "txt", "srt"],
            storageRoot: tempRoot.path,
            languageHint: nil
        )
        let store = try SessionStore(config: config)

        let request = CreateSessionRequest(
            sessionID: UUID().uuidString,
            sessionName: "Test Session",
            recordingStartedAt: "2026-04-08T00:00:00Z",
            recordingEndedAt: "2026-04-08T00:15:00Z",
            recorder: RecorderInfo(deviceID: "device", appVersion: "1.0", build: "1"),
            expectedFiles: ExpectedFiles(metadata: true, system: true, mic: false)
        )

        let (response, statusCode) = try store.createSession(request, idempotencyKey: "idem-key", baseURL: "http://localhost:8765")
        #expect(statusCode == 201)
        #expect(response.sessionID == request.sessionID)

        let status = try store.fetchStatus(sessionID: request.sessionID)
        #expect(status.sessionName == "Test Session")
        #expect(status.ingestionState == .created)
    }

    @Test
    func transcriptArtifactsAreGenerated() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let config = AppConfig(
            bindHost: "127.0.0.1",
            port: 8765,
            tlsEnabled: false,
            authToken: "token",
            transcriptionEngine: "whisperkit",
            modelName: "base",
            maxRetries: 3,
            diarizationEnabled: false,
            speakerAutoMatchThreshold: 0.86,
            allowCPUFallbackForDiarization: true,
            outputFormats: ["json", "txt", "srt"],
            storageRoot: tempRoot.path,
            languageHint: nil
        )
        let store = try SessionStore(config: config)
        let sessionID = UUID().uuidString
        _ = try store.createSession(
            CreateSessionRequest(
                sessionID: sessionID,
                sessionName: "Artifacts",
                recordingStartedAt: "2026-04-08T00:00:00Z",
                recordingEndedAt: "2026-04-08T00:15:00Z",
                recorder: RecorderInfo(deviceID: "device", appVersion: "1.0", build: "1"),
                expectedFiles: ExpectedFiles(metadata: true, system: true, mic: false)
            ),
            idempotencyKey: "idem-2",
            baseURL: "http://localhost:8765"
        )

        try store.writeTranscriptArtifacts(
            sessionID: sessionID,
            transcript: CanonicalTranscript(
                sessionID: sessionID,
                sourceFiles: ["system": "system.wav"],
                transcription: TranscriptionMetadata(engine: "whisperkit", model: "base", language: "en", runtime: "WhisperKit", backend: "CoreML"),
                segments: [
                    TranscriptSegment(start: 0, end: 2, speaker: nil, text: "Hello world")
                ]
            )
        )

        let processingDirectory = ProcessorPaths.processingDirectory(for: config, sessionID: sessionID)
        #expect(FileManager.default.fileExists(atPath: processingDirectory.appendingPathComponent("transcript.json").path))
        #expect(FileManager.default.fileExists(atPath: processingDirectory.appendingPathComponent("transcript.txt").path))
        #expect(FileManager.default.fileExists(atPath: processingDirectory.appendingPathComponent("transcript.srt").path))
    }
}
