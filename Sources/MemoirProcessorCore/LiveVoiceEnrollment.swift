@preconcurrency import AVFoundation
import Foundation

/// Creates a live-compatible voice sample from a person explicitly named in a
/// finished transcript. Raw excerpts are temporary; only embeddings are stored.
public enum LiveVoiceEnrollment {
    private static let lock = NSLock()

    static func sourceStart(turnStart: Double, source: SpeakerSource, streamSync: StreamSyncMetadata?) -> Double {
        let offset = streamSync?.alignedWavExport == true ? 0 : (streamSync?.relativeOffsetToSystemSeconds ?? 0)
        let shift = source == .mic ? max(0, offset) : source == .system ? max(0, -offset) : 0
        return max(0, turnStart - shift)
    }

    public static func enrol(store: SessionStore, config: AppConfig, sessionID: String, clusterID: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard UUID(uuidString: sessionID) != nil,
              let speaker = try store.listSessionSpeakers(sessionID: sessionID).first(where: { $0.clusterID == clusterID }),
              let profileID = speaker.matchedProfileID else { return }
        let artifactURL = ProcessorPaths.processingDirectory(for: config, sessionID: sessionID).appendingPathComponent("diarization.json")
        guard FileManager.default.fileExists(atPath: artifactURL.path) else { return }
        let artifact = try JSONDecoder.memoir.decode(DiarizationArtifact.self, from: Data(contentsOf: artifactURL))
        let candidates = artifact.turns.filter { $0.clusterID == clusterID && $0.end - $0.start >= 2.5 && [.system, .mic].contains($0.sourceTrack) }
            .sorted { $0.end - $0.start > $1.end - $1.start }
        guard let turn = candidates.first(where: { candidate in
            !artifact.turns.contains { other in
                other.clusterID != clusterID && other.sourceTrack == candidate.sourceTrack &&
                min(other.end, candidate.end) - max(other.start, candidate.start) > 0.1
            }
        }) else { return }
        let sourceURL = ProcessorPaths.audioURL(for: config, sessionID: sessionID, kind: turn.sourceTrack == .mic ? .mic : .system)
        let source = try AVAudioFile(forReading: sourceURL)
        let rate = source.processingFormat.sampleRate
        let metadata = try JSONDecoder.memoir.decode(MetadataFile.self, from: Data(contentsOf: ProcessorPaths.metadataURL(for: config, sessionID: sessionID)))
        let sourceTime = sourceStart(turnStart: turn.start, source: turn.sourceTrack, streamSync: metadata.streamSync)
        let start = AVAudioFramePosition(sourceTime * rate)
        let count = AVAudioFrameCount(max(0, min(Double(source.length - start), min(10, turn.end - turn.start) * rate)))
        guard Double(count) / rate >= 2.5,
              let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: count) else { return }
        source.framePosition = start
        try source.read(into: buffer, frameCount: count)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("memoir-enrol-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let wav = temporary.appendingPathComponent("voice.wav")
        do {
            let output = try AVAudioFile(forWriting: wav, settings: source.fileFormat.settings)
            try output.write(from: buffer)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: wav.path)
        let result = try SubprocessRunner.run(executable: RuntimeDependencyManager().fluidWorkerURL(),
            arguments: ["--voice-sample", "--models", ProcessorPaths.runtimeDirectory(for: config).appendingPathComponent("fluidaudio-live/models").path,
                        "--audio", wav.path], timeout: 90)
        guard result.status == 0 else {
            throw ProcessorError(code: "voice_enrolment_failed", message: "Live voice enrolment could not finish. The transcript name is saved.", retryable: true)
        }
        struct Reply: Decodable { let embedding: [Double] }
        let reply = try JSONDecoder.memoir.decode(Reply.self, from: result.output)
        guard reply.embedding.count == 256 else { return }
        try store.saveVoiceSample(profileID: profileID, sessionID: sessionID, clusterID: clusterID,
            vector: reply.embedding, quality: Double(buffer.frameLength) / rate, space: LiveSpeakerConstants.embeddingSpace)
    }
}
