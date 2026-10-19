import AVFoundation
import Foundation

public struct ValidationResult: Sendable {
    public let metadata: MetadataFile
    public let systemAudioURL: URL
    public let micAudioURL: URL?
    public let streamSync: StreamSyncMetadata?
}

public enum PreferredTranscriptSource: String, Sendable {
    case system
    case mic
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
        try validateAudio(url: systemURL, metadata: metadata.systemAudio, timing: metadata.streamSync?.streams.system)

        let micURL = ProcessorPaths.audioURL(for: config, sessionID: sessionID, kind: .mic)
        let resolvedMicURL: URL? = fileManager.fileExists(atPath: micURL.path) ? micURL : nil
        if let resolvedMicURL {
            guard let mic = metadata.micAudio else { throw ProcessorError(code: "invalid_metadata", message: "mic.wav has no matching metadata.", retryable: false) }
            try validateAudio(url: resolvedMicURL, metadata: mic, timing: metadata.streamSync?.streams.mic)
        }

        if config.diarizationEnabled, resolvedMicURL != nil, metadata.streamSync == nil {
            throw ProcessorError(
                code: "invalid_metadata",
                message: "stream_sync is required for dual-track diarization sessions.",
                retryable: false
            )
        }

        if metadata.micAudio != nil, resolvedMicURL == nil { throw ProcessorError(code: "missing_required_file", message: "mic.wav is missing.", retryable: false) }
        if let sync = metadata.streamSync {
            guard sync.schemaVersion == 1, sync.timeline == "host_time_ns", UInt64(sync.sessionZeroHostTimeNS) != nil,
                  ["system", "mic"].contains(sync.referenceStream), sync.streams.system != nil,
                  resolvedMicURL == nil || sync.streams.mic != nil else {
                throw ProcessorError(code: "invalid_metadata", message: "Unsupported or incomplete stream_sync metadata.", retryable: false)
            }
            if let mic = sync.streams.mic, let system = sync.streams.system, let offset = sync.relativeOffsetToSystemSeconds,
               abs(mic.startOffsetSeconds - system.startOffsetSeconds - offset) > 0.001 {
                throw ProcessorError(code: "invalid_metadata", message: "Stream offsets disagree.", retryable: false)
            }
        }
        return ValidationResult(metadata: metadata, systemAudioURL: systemURL, micAudioURL: resolvedMicURL, streamSync: metadata.streamSync)
    }

    private func validateAudio(url: URL, metadata: AudioMetadata, timing: StreamTimingMetadata?) throws {
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw ProcessorError(code: "audio_decode_failed", message: "\(url.lastPathComponent) could not be decoded as audio.", retryable: false)
        }

        let rate = audioFile.processingFormat.sampleRate
        guard abs(rate - metadata.sampleRateHz) < 1, Int(audioFile.processingFormat.channelCount) == metadata.channels,
              abs(Double(audioFile.length) / rate - metadata.durationSeconds) < 0.1 else {
            throw ProcessorError(code: "invalid_metadata", message: "Audio properties disagree with metadata for \(url.lastPathComponent).", retryable: false)
        }
        if let timing {
            guard timing.durationFrames == audioFile.length, abs(Double(timing.sampleRateHz) - rate) < 1,
                  UInt64(timing.firstSampleHostTimeNS) != nil, timing.startOffsetSeconds >= 0, timing.latencyFrames >= 0 else {
                throw ProcessorError(code: "invalid_metadata", message: "Stream timing disagrees with \(url.lastPathComponent).", retryable: false)
            }
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

public final class AudioSignalInspector {
    public init() {}

    public func peakLevel(for audioURL: URL) throws -> Float {
        let file = try AVAudioFile(forReading: audioURL)
        let processingFormat = file.processingFormat
        guard let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: processingFormat.sampleRate, channels: processingFormat.channelCount, interleaved: false) else {
            throw ProcessorError(code: "audio_analysis_failed", message: "Unable to analyze \(audioURL.lastPathComponent).", retryable: false)
        }

        let originalPosition = file.framePosition
        defer { file.framePosition = originalPosition }
        file.framePosition = 0

        let chunkSize: AVAudioFrameCount = 4096
        var peak: Float = 0

        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: chunkSize) else {
                throw ProcessorError(code: "audio_analysis_failed", message: "Unable to allocate audio analysis buffer.", retryable: false)
            }
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(chunkSize), file.length - file.framePosition)))
            let frameLength = Int(buffer.frameLength)
            if frameLength == 0 { break }

            let channelCount = Int(buffer.format.channelCount)
            guard let channels = buffer.floatChannelData else { continue }
            for channelIndex in 0..<channelCount {
                let channel = channels[channelIndex]
                for frameIndex in 0..<frameLength {
                    let value = abs(channel[frameIndex])
                    if value > peak { peak = value }
                }
            }
        }

        return peak
    }

    public func preferredTranscriptSource(systemURL: URL, micURL: URL?) throws -> PreferredTranscriptSource {
        let systemPeak = try peakLevel(for: systemURL)
        guard let micURL else {
            return .system
        }

        let micPeak = try peakLevel(for: micURL)
        if systemPeak < 0.001, micPeak >= 0.001 {
            return .mic
        }

        return .system
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
        var environment = ProcessInfo.processInfo.environment
        let pathComponents = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        environment["PATH"] = pathComponents.joined(separator: ":")
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/ffmpeg") {
            environment["FFMPEG_BINARY"] = "/opt/homebrew/bin/ffmpeg"
        } else if FileManager.default.fileExists(atPath: "/usr/local/bin/ffmpeg") {
            environment["FFMPEG_BINARY"] = "/usr/local/bin/ffmpeg"
        }
        process.environment = environment

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

        do {
            return try JSONDecoder.memoir.decode(WorkerTranscriptResult.self, from: output)
        } catch {
            if
                let rawOutput = String(data: output, encoding: .utf8),
                let jsonStart = rawOutput.firstIndex(of: "{")
            {
                let jsonCandidate = String(rawOutput[jsonStart...])
                if let jsonData = jsonCandidate.data(using: .utf8),
                   let recovered = try? JSONDecoder.memoir.decode(WorkerTranscriptResult.self, from: jsonData) {
                    return recovered
                }

                let message = jsonCandidate.trimmingCharacters(in: .whitespacesAndNewlines)
                throw ProcessorError(
                    code: "invalid_worker_output",
                    message: message.isEmpty ? "The transcription worker returned unreadable output." : "The transcription worker returned unreadable output: \(message.prefix(400))",
                    retryable: true
                )
            }

            throw ProcessorError(
                code: "invalid_worker_output",
                message: "The transcription worker returned unreadable output.",
                retryable: true
            )
        }
    }
}
