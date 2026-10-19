import Foundation
import MemoirProcessorCore

actor LiveSpeakerCoordinator {
    private let store: SessionStore
    private var config: AppConfig
    private let selectionConfigURL: URL?
    private var busy = false

    init(store: SessionStore, config: AppConfig, selectionConfigURL: URL?) {
        self.store = store
        self.config = config
        self.selectionConfigURL = selectionConfigURL
    }

    func begin(_ sessionID: String) throws -> LiveSpeakerSnapshot {
        if let selectionConfigURL {
            let saved = try JSONDecoder.memoir.decode(AppConfig.self, from: Data(contentsOf: selectionConfigURL))
            config = config.updating(diarizationEnabled: saved.diarizationEnabled, speakerAutoMatchThreshold: saved.speakerAutoMatchThreshold)
        }
        // Live processing is independent of the selected final-pass engine.
        guard config.diarizationEnabled else {
            throw ProcessorError(code: "live_disabled", message: "Enable diarization on the processor to see live speakers.", retryable: false)
        }
        return try store.beginLiveSession(sessionID)
    }

    func process(_ sessionID: String, chunk: LiveAudioChunk) async throws -> LiveSpeakerSnapshot {
        let pcm = try chunk.validatedPCM()
        let snapshot = try store.liveSnapshot(sessionID)
        guard !snapshot.closed else { return snapshot }
        if try store.hasLiveChunk(sessionID, chunk: chunk) { return snapshot }
        guard !busy else { throw ProcessorError(code: "live_busy", message: "Live speaker detection is catching up.", retryable: true) }
        busy = true
        defer { busy = false }
        let seeds = try store.liveSeeds(sessionID)
        let configuration = config
        let output = try await Task.detached(priority: .userInitiated) {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("memoir-live-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: temporary) }
            let wav = temporary.appendingPathComponent("chunk.wav")
            try LiveWaveEncoder.encode(pcm, sampleRate: chunk.sampleRateHz).write(to: wav, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: wav.path)
            let seedFile = temporary.appendingPathComponent("seeds.json")
            try JSONEncoder.memoir.encode(seeds).write(to: seedFile)
            let models = ProcessorPaths.runtimeDirectory(for: configuration).appendingPathComponent("fluidaudio-live/models", isDirectory: true)
            let result = try SubprocessRunner.run(executable: RuntimeDependencyManager().fluidWorkerURL(),
                arguments: ["--live-chunk", "--models", models.path, "--audio", wav.path, "--seeds", seedFile.path], timeout: 60)
            guard result.status == 0 else {
                throw ProcessorError(code: "live_unavailable", message: String(data: result.error.suffix(2000), encoding: .utf8) ?? "Live speaker models could not run.", retryable: true)
            }
            return try JSONDecoder.memoir.decode(LiveWorkerOutput.self, from: result.output)
        }.value
        return try store.applyLiveChunk(sessionID, chunk: chunk, output: output, threshold: config.speakerAutoMatchThreshold)
    }
}

public enum LiveWaveEncoder {
    static func encode(_ pcm: Data, sampleRate: Int) -> Data {
        var result = Data()
        func text(_ value: String) { result.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var number = value.littleEndian; withUnsafeBytes(of: &number) { result.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var number = value.littleEndian; withUnsafeBytes(of: &number) { result.append(contentsOf: $0) } }
        text("RIFF"); u32(UInt32(36 + pcm.count)); text("WAVEfmt "); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16); text("data"); u32(UInt32(pcm.count)); result.append(pcm)
        return result
    }
}
