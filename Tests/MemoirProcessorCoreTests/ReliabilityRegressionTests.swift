import Foundation
import Testing
@testable import MemoirProcessorCore

struct ReliabilityRegressionTests {
    func fixture() throws -> (SessionStore, AppConfig, String) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("memoir-probe-" + UUID().uuidString)
        let config = AppConfig.default().updating(storageRoot: root.path)
        let store = try SessionStore(config: config)
        let id = UUID().uuidString
        _ = try store.createSession(CreateSessionRequest(sessionID: id, sessionName: "Probe", recordingStartedAt: "2026-04-08T00:00:00Z", recordingEndedAt: "2026-04-08T00:15:00Z", recorder: RecorderInfo(deviceID: "test", appVersion: "1", build: "1"), expectedFiles: ExpectedFiles()), idempotencyKey: UUID().uuidString, baseURL: "")
        return (store, config, id)
    }

    @Test func pythonDiarizationOutputDecodesWithoutIDs() throws {
        let data = Data(#"{"runtime":"pyannote.audio","backend":"cpu","turns":[{"cluster_id":"system:SPEAKER_00","start":0.0,"end":2.0,"source_track":"system"}],"embeddings":[]}"#.utf8)
        let result = try JSONDecoder.memoir.decode(WorkerDiarizationResult.self, from: data)
        #expect(result.turns.first?.clusterID == "system:SPEAKER_00")
    }

    @Test func alignedExportIsNotShiftedAgain() throws {
        let json = #"{"schema_version":1,"timeline":"host_time_ns","session_zero_host_time_ns":"1000000000","reference_stream":"system","aligned_wav_export":true,"drift_corrected":false,"estimated_drift_ppm":0,"relative_offset_to_system_seconds":0.25,"sync_confidence":"high","echo_cancellation":{"applied":false,"mode":"none"},"streams":{"system":{"first_sample_host_time_ns":"1000000000","start_offset_seconds":0,"sample_rate_hz":16000,"duration_frames":160000,"latency_frames":0},"mic":{"first_sample_host_time_ns":"1250000000","start_offset_seconds":0.25,"sample_rate_hz":16000,"duration_frames":160000,"latency_frames":0}}}"#
        let sync = try JSONDecoder.memoir.decode(StreamSyncMetadata.self, from: Data(json.utf8))
        let worker = WorkerTranscriptResult(engine: "whisperkit", model: "base", language: "en", runtime: nil, backend: nil, segments: [TranscriptSegment(start: 5, end: 6, speaker: nil, text: "hello")])
        let aligned = TranscriptAlignment.align(sourceTranscripts: [SourceTranscript(kind: .mic, transcript: worker)], streamSync: sync)
        #expect(aligned[0].segments[0].start == 5)
    }

    @Test func restartRecoversArtifactWriting() throws {
        let (store, config, id) = try fixture()
        defer { try? FileManager.default.removeItem(atPath: config.storageRoot) }
        try store.setProcessingState(sessionID: id, state: .writingArtifacts)
        try store.recoverIncompleteSessions()
        #expect(try store.fetchStatus(sessionID: id).processingState == .retryPending)
    }

    @Test func permanentErrorDoesNotRetry() throws {
        let (store, config, id) = try fixture()
        defer { try? FileManager.default.removeItem(atPath: config.storageRoot) }
        try store.markRetryPending(sessionID: id, error: ProcessorError(code: "invalid_metadata", message: "bad", retryable: false))
        #expect(try store.fetchStatus(sessionID: id).processingState == .failed)
    }

    @Test func invalidSessionIDCannotEscapeStorage() throws {
        let (store, config, _) = try fixture()
        defer { try? FileManager.default.removeItem(atPath: config.storageRoot) }
        #expect(throws: ProcessorError.self) {
            _ = try store.createSession(CreateSessionRequest(sessionID: "../escaped", sessionName: "Probe", recordingStartedAt: "2026-04-08T00:00:00Z", recordingEndedAt: "2026-04-08T00:15:00Z", recorder: RecorderInfo(deviceID: "test", appVersion: "1", build: "1"), expectedFiles: ExpectedFiles()), idempotencyKey: UUID().uuidString, baseURL: "")
        }
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: config.storageRoot).appendingPathComponent("escaped").path))
    }

    @Test func systemTrackWinsEvenWhenMicStartsFirst() throws {
        let mic = TranscriptSegment(start: 0, end: 2, speaker: nil, speakerSource: .mic, text: "hello everyone")
        let system = TranscriptSegment(start: 0.1, end: 2.1, speaker: nil, speakerSource: .system, text: "hello everyone")
        let merged = TranscriptAlignment.mergeAndDedupe([TrackAlignedTranscript(kind: .mic, segments: [mic]), TrackAlignedTranscript(kind: .system, segments: [system])])
        #expect(merged.count == 1)
    }
}

struct SpeakerRelabelingTests {
    @Test func reassignmentAndRenameUpdateAllArtifacts() throws {
        let (store, config, id) = try ReliabilityRegressionTests().fixture()
        defer { try? FileManager.default.removeItem(atPath: config.storageRoot) }
        let cluster = "system:SPEAKER_00"
        let transcript = CanonicalTranscript(sessionID: id, sourceFiles: ["system":"system.wav"], transcription: TranscriptionMetadata(engine: "whisperkit", model: "base", language: "en", runtime: nil, backend: nil), segments: [TranscriptSegment(start: 0, end: 1, speaker: "Speaker 1", speakerID: cluster, clusterID: cluster, text: "Hello")])
        try store.writeTranscriptArtifacts(sessionID: id, transcript: transcript)
        try store.upsertSessionSpeakers(sessionID: id, speakers: [SessionSpeaker(sessionID: id, clusterID: cluster, displayLabel: "Speaker 1", sourceTrack: .system, speakingDurationSeconds: 1, matchedProfileID: nil, matchedProfileName: nil, matchConfidence: nil, assignmentState: .anonymous, representativeText: nil)])
        let first = try store.createSpeakerProfile(name: "Alex")
        let second = try store.createSpeakerProfile(name: "Sam")
        try store.assignSessionSpeaker(sessionID: id, clusterID: cluster, profileID: first.id, profileName: first.name)
        try store.assignSessionSpeaker(sessionID: id, clusterID: cluster, profileID: second.id, profileName: second.name)
        try store.renameSpeakerProfile(profileID: second.id, name: "Samuel")
        let json = try Data(contentsOf: store.artifactPath(sessionID: id, name: "transcript.json"))
        let result = try JSONDecoder.memoir.decode(CanonicalTranscript.self, from: json)
        #expect(result.segments.first?.speaker == "Samuel")
        #expect(result.segments.first?.clusterID == cluster)
        #expect(try String(contentsOf: store.artifactPath(sessionID: id, name: "transcript.txt"), encoding: .utf8).contains("[Samuel]"))
        #expect(try String(contentsOf: store.artifactPath(sessionID: id, name: "transcript.srt"), encoding: .utf8).contains("[Samuel]"))
    }
}
