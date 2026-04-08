import AVFoundation
import Foundation

public struct ValidationResult: Sendable {
    public let metadata: MetadataFile
    public let systemAudioURL: URL
    public let micAudioURL: URL?
}

public final class SessionValidator {
    private let config: AppConfig
    private let fileManager = FileManager.default

    public init(config: AppConfig) {
        self.config = config
    }

    public func validate(sessionID: String) throws -> ValidationResult {
        let metadata = try JSONDecoder.memoir.decode(MetadataFile.self, from: Data(contentsOf: ProcessorPaths.metadataURL(for: config, sessionID: sessionID)))
        guard metadata.sessionID == sessionID else {
            throw ProcessorError(code: "invalid_metadata", message: "metadata.json session_id does not match the session path.", retryable: false)
        }
        guard metadata.systemAudio.filename == "system.wav" else {
            throw ProcessorError(code: "invalid_metadata", message: "system_audio.filename must be system.wav.", retryable: false)
        }
        if let mic = metadata.micAudio, mic.filename != "mic.wav" {
            throw ProcessorError(code: "invalid_metadata", message: "mic_audio.filename must be mic.wav.", retryable: false)
        }

        let systemURL = ProcessorPaths.audioURL(for: config, sessionID: sessionID, kind: .system)
        guard fileManager.fileExists(atPath: systemURL.path) else {
            throw ProcessorError(code: "missing_required_file", message: "system.wav is missing.", retryable: false)
        }
        try validateAudio(url: systemURL)

        let micURL = ProcessorPaths.audioURL(for: config, sessionID: sessionID, kind: .mic)
        let resolvedMicURL: URL? = fileManager.fileExists(atPath: micURL.path) ? micURL : nil
        if let resolvedMicURL {
            try validateAudio(url: resolvedMicURL)
        }

        return ValidationResult(metadata: metadata, systemAudioURL: systemURL, micAudioURL: resolvedMicURL)
    }

    private func validateAudio(url: URL) throws {
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw ProcessorError(code: "audio_decode_failed", message: "\(url.lastPathComponent) could not be decoded as audio.", retryable: false)
        }

        guard audioFile.length > 0 else {
            throw ProcessorError(code: "empty_audio", message: "\(url.lastPathComponent) has zero duration.", retryable: false)
        }
    }
}

public final class AudioNormalizer {
    private let config: AppConfig

    public init(config: AppConfig) {
        self.config = config
    }

    public func normalizedAudioURL(for sessionID: String, sourceURL: URL) throws -> URL {
        let input = try AVAudioFile(forReading: sourceURL)
        let format = input.processingFormat
        let alreadyNormalized = Int(format.sampleRate.rounded()) == 16_000 && format.channelCount == 1
        if alreadyNormalized {
            return sourceURL
        }

        let ffmpegURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        guard FileManager.default.fileExists(atPath: ffmpegURL.path) || FileManager.default.fileExists(atPath: "/usr/local/bin/ffmpeg") else {
            throw ProcessorError(code: "normalization_requires_ffmpeg", message: "ffmpeg is required to normalize non-16k mono WAV inputs.", retryable: false)
        }

        let destination = ProcessorPaths.workDirectory(for: config, sessionID: sessionID).appendingPathComponent(sourceURL.deletingPathExtension().lastPathComponent + ".normalized.wav")
        let process = Process()
        process.executableURL = FileManager.default.fileExists(atPath: ffmpegURL.path) ? ffmpegURL : URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
        process.arguments = ["-y", "-i", sourceURL.path, "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ProcessorError(code: "normalization_failed", message: "ffmpeg failed while normalizing \(sourceURL.lastPathComponent).", retryable: false)
        }
        return destination
    }
}

public final class PythonTranscriptionWorker {
    private let scriptURL: URL
    private let stateQueue = DispatchQueue(label: "MemoirProcessor.PythonWorker")
    private var currentProcess: Process?

    public init(scriptURL: URL) {
        self.scriptURL = scriptURL
    }

    public func stopCurrentProcess() {
        stateQueue.sync {
            currentProcess?.terminate()
        }
    }

    public func transcribe(
        audioURL: URL,
        sessionID: String,
        config: AppConfig,
        languageHint: String?,
        onStart: ((Int32) -> Void)? = nil
    ) throws -> WorkerTranscriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            scriptURL.path,
            "--audio", audioURL.path,
            "--session-id", sessionID,
            "--engine", config.transcriptionEngine,
            "--model", config.modelName
        ]
        if let languageHint, !languageHint.isEmpty {
            process.arguments?.append(contentsOf: ["--language", languageHint])
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        stateQueue.sync {
            currentProcess = process
        }
        try process.run()
        onStart?(process.processIdentifier)
        process.waitUntilExit()
        stateQueue.sync {
            currentProcess = nil
        }

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Transcription worker failed."
            throw ProcessorError(code: "model_execution_failed", message: errorOutput.trimmingCharacters(in: .whitespacesAndNewlines), retryable: true)
        }

        return try JSONDecoder.memoir.decode(WorkerTranscriptResult.self, from: output)
    }
}
