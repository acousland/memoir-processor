import Foundation
import MemoirProcessorCore
import WhisperKit

final class WhisperKitTranscriptionWorker: @unchecked Sendable {
    func ensureModelDownloaded(config: AppConfig, token: String?) async throws -> URL {
        let downloadBase = ProcessorPaths.runtimeDirectory(for: config)
        try FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)
        let modelURL = try await WhisperKit.download(
            variant: config.modelName,
            downloadBase: downloadBase,
            from: "argmaxinc/whisperkit-coreml",
            token: token
        )
        let markerDirectory = ProcessorPaths.whisperModelDirectory(for: config, model: config.modelName)
        try FileManager.default.createDirectory(at: markerDirectory, withIntermediateDirectories: true)
        try modelURL.path.write(to: markerDirectory.appendingPathComponent("resolved-model-path.txt"), atomically: true, encoding: .utf8)
        return modelURL
    }

    func transcribe(
        audioURL: URL,
        config: AppConfig,
        languageHint: String?,
        token: String?
    ) async throws -> WorkerTranscriptResult {
        let pipeline = try await buildPipeline(config: config, token: token)
        let options = DecodingOptions(
            verbose: false,
            language: languageHint,
            detectLanguage: languageHint == nil,
            skipSpecialTokens: true,
            wordTimestamps: true
        )
        let results: [TranscriptionResult] = try await pipeline.transcribe(audioPath: audioURL.path, decodeOptions: options)
        let rawSegments = results.flatMap { $0.segments }
        let flattenedSegments = rawSegments.compactMap { segment -> TranscriptSegment? in
            let text = segment.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard TranscriptText.containsSpeech(text) else { return nil }
            return TranscriptSegment(
                start: Double(segment.start),
                end: Double(segment.end),
                speaker: nil,
                speakerID: nil,
                speakerSource: nil,
                speakerConfidence: nil,
                text: text
            )
        }
        let language = results.first?.language ?? languageHint ?? "unknown"
        return WorkerTranscriptResult(
            engine: "whisperkit",
            model: config.modelName,
            language: language,
            runtime: "WhisperKit",
            backend: "CoreML",
            segments: flattenedSegments
        )
    }

    private func buildPipeline(config: AppConfig, token: String?) async throws -> WhisperKit {
        let downloadBase = ProcessorPaths.runtimeDirectory(for: config)
        try FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)
        let wkConfig = WhisperKitConfig(
            model: config.modelName,
            downloadBase: downloadBase,
            modelToken: token,
            computeOptions: ModelComputeOptions(),
            verbose: false,
            logLevel: .none,
            prewarm: true,
            load: true,
            download: true
        )
        let whisperKit = try await WhisperKit(wkConfig)

        let markerDirectory = ProcessorPaths.whisperModelDirectory(for: config, model: config.modelName)
        try FileManager.default.createDirectory(at: markerDirectory, withIntermediateDirectories: true)
        if let modelFolder = whisperKit.modelFolder {
            try modelFolder.path.write(to: markerDirectory.appendingPathComponent("resolved-model-path.txt"), atomically: true, encoding: .utf8)
        }

        return whisperKit
    }
}
