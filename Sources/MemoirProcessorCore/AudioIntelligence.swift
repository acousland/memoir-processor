import AVFoundation
import Foundation
import Darwin

public struct SourceTranscript: Sendable {
    public let kind: UploadFileKind
    public let transcript: WorkerTranscriptResult

    public init(kind: UploadFileKind, transcript: WorkerTranscriptResult) {
        self.kind = kind
        self.transcript = transcript
    }
}

public struct TrackAlignedTranscript: Sendable {
    public let kind: UploadFileKind
    public let segments: [TranscriptSegment]

    public init(kind: UploadFileKind, segments: [TranscriptSegment]) {
        self.kind = kind
        self.segments = segments
    }
}

public struct SpeakerMatchDecision: Sendable {
    public let profileID: String?
    public let profileName: String?
    public let confidence: Double?
    public let assignmentState: SpeakerAssignmentState

    public init(profileID: String?, profileName: String?, confidence: Double?, assignmentState: SpeakerAssignmentState) {
        self.profileID = profileID
        self.profileName = profileName
        self.confidence = confidence
        self.assignmentState = assignmentState
    }
}

public final class LocalDiarizationWorker: @unchecked Sendable {
    private let scriptURL: URL

    public init(scriptURL: URL) {
        self.scriptURL = scriptURL
    }

    public func diarize(
        audioURL: URL,
        sessionID: String,
        sourceTrack: SpeakerSource,
        config: AppConfig,
        huggingFaceToken: String?,
        onStart: ((Int32) -> Void)? = nil
    ) throws -> WorkerDiarizationResult {
        let runtime = RuntimeDependencyManager()
        let result: SubprocessResult
        switch config.diarizationEngine {
        case .fluidAudio:
            result = try SubprocessRunner.run(
                executable: runtime.fluidWorkerURL(),
                arguments: ["--audio", audioURL.path, "--source-track", sourceTrack.rawValue,
                            "--models", ProcessorPaths.fluidModelsDirectory(for: config).path],
                onStart: onStart
            )
        case .pyannote:
            let python = runtime.diarizationPythonURL(config: config)
            guard FileManager.default.fileExists(atPath: python.path) else {
                throw ProcessorError(code: "diarization_runtime_missing", message: "Prepare the Pyannote Community-1 runtime in Processor Settings.", retryable: false)
            }
            var arguments = [scriptURL.path, "--audio", audioURL.path, "--session-id", sessionID, "--source-track", sourceTrack.rawValue]
            if config.allowCPUFallbackForDiarization { arguments.append("--allow-cpu-fallback") }
            arguments.append("--prefer-mps")
            var environment = ProcessInfo.processInfo.environment
            if let huggingFaceToken { environment["HF_TOKEN"] = huggingFaceToken }
            environment["PYANNOTE_METRICS_ENABLED"] = "0"
            environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
            result = try SubprocessRunner.run(executable: python, arguments: arguments, environment: environment, onStart: onStart)
        }
        guard result.status == 0 else {
            throw ProcessorError(code: "diarization_failed", message: String(data: result.error, encoding: .utf8) ?? "Diarization failed.", retryable: true)
        }
        let output = result.output
        do {
            return try JSONDecoder.memoir.decode(WorkerDiarizationResult.self, from: output)
        } catch {
            let rawOutput = String(data: output, encoding: .utf8) ?? ""
            throw ProcessorError(
                code: "invalid_diarization_output",
                message: rawOutput.isEmpty ? "The diarization worker returned unreadable output." : "The diarization worker returned unreadable output: \(rawOutput.prefix(400))",
                retryable: true
            )
        }
    }
}

public enum TranscriptAlignment {
    public static func align(sourceTranscripts: [SourceTranscript], streamSync: StreamSyncMetadata?) -> [TrackAlignedTranscript] {
        let relativeOffset = streamSync?.alignedWavExport == true ? 0 : (streamSync?.relativeOffsetToSystemSeconds ?? 0)
        return sourceTranscripts.map { source in
            let shift: Double
            switch source.kind {
            case .system:
                shift = relativeOffset < 0 ? abs(relativeOffset) : 0
            case .mic:
                shift = relativeOffset > 0 ? relativeOffset : 0
            case .metadata:
                shift = 0
            }
            return TrackAlignedTranscript(
                kind: source.kind,
                segments: source.transcript.segments.map {
                    TranscriptSegment(
                        id: $0.id,
                        start: max(0, $0.start + shift),
                        end: max(0, $0.end + shift),
                        speaker: $0.speaker,
                        speakerID: $0.speakerID,
                        clusterID: $0.clusterID,
                        speakerSource: source.kind == .system ? .system : .mic,
                        speakerConfidence: $0.speakerConfidence,
                        text: $0.text
                    )
                }
            )
        }
    }

    public static func mergeAndDedupe(_ alignedTracks: [TrackAlignedTranscript]) -> [TranscriptSegment] {
        let all = alignedTracks.flatMap(\.segments)
        let system = all.filter { $0.speakerSource == .system }
        return all.filter { candidate in
            candidate.speakerSource != .mic || !system.contains { shouldSuppress(candidate: candidate, existing: $0) }
        }.sorted {
            if $0.start == $1.start { return $0.end < $1.end }
            return $0.start < $1.start
        }
    }

    public static func align(turns: [DiarizationTurn], streamSync: StreamSyncMetadata?) -> [DiarizationTurn] {
        let relativeOffset = streamSync?.alignedWavExport == true ? 0 : (streamSync?.relativeOffsetToSystemSeconds ?? 0)
        return turns.map { turn in
            let shift: Double
            switch turn.sourceTrack {
            case .system:
                shift = relativeOffset < 0 ? abs(relativeOffset) : 0
            case .mic:
                shift = relativeOffset > 0 ? relativeOffset : 0
            default:
                shift = 0
            }
            return DiarizationTurn(
                id: turn.id,
                clusterID: turn.clusterID,
                start: max(0, turn.start + shift),
                end: max(0, turn.end + shift),
                sourceTrack: turn.sourceTrack,
                matchedProfileID: turn.matchedProfileID,
                matchedProfileName: turn.matchedProfileName,
                matchConfidence: turn.matchConfidence,
                representativeText: turn.representativeText
            )
        }
    }

    private static func shouldSuppress(candidate: TranscriptSegment, existing: TranscriptSegment) -> Bool {
        guard candidate.speakerSource != existing.speakerSource else { return false }
        let startsNear = abs(candidate.start - existing.start) <= 0.75
        let overlaps = candidate.start <= existing.end + 0.5 && existing.start <= candidate.end + 0.5
        guard startsNear || overlaps else { return false }
        let similarity = normalizedSimilarity(candidate.text, existing.text)
        if candidate.speakerSource == .mic, existing.speakerSource == .system {
            return similarity >= 0.78
        }
        return false
    }

    private static func normalizedSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let leftTokens = Set(normalizedText(lhs).split(separator: " ").map(String.init))
        let rightTokens = Set(normalizedText(rhs).split(separator: " ").map(String.init))
        guard !leftTokens.isEmpty, !rightTokens.isEmpty else { return 0 }
        let overlap = leftTokens.intersection(rightTokens).count
        let union = leftTokens.union(rightTokens).count
        return union == 0 ? 0 : Double(overlap) / Double(union)
    }

    private static func normalizedText(_ text: String) -> String {
        let lowered = text.lowercased()
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

public enum SpeakerMatching {
    public static func bestMatch(
        embedding: [Double],
        profileEmbeddings: [String: [[Double]]],
        profilesByID: [String: SpeakerProfile],
        threshold: Double
    ) -> SpeakerMatchDecision {
        var bestProfileID: String?
        var bestConfidence = -1.0

        for (profileID, vectors) in profileEmbeddings {
            let score = vectors.map { cosineSimilarity($0, embedding) }.max() ?? -1
            if score > bestConfidence {
                bestConfidence = score
                bestProfileID = profileID
            }
        }

        guard let bestProfileID, let profile = profilesByID[bestProfileID], bestConfidence > 0 else {
            return SpeakerMatchDecision(profileID: nil, profileName: nil, confidence: nil, assignmentState: .anonymous)
        }

        if bestConfidence >= threshold {
            return SpeakerMatchDecision(profileID: bestProfileID, profileName: profile.name, confidence: bestConfidence, assignmentState: .confirmed)
        }
        if bestConfidence >= max(0.5, threshold - 0.08) {
            return SpeakerMatchDecision(profileID: bestProfileID, profileName: profile.name, confidence: bestConfidence, assignmentState: .suggested)
        }
        return SpeakerMatchDecision(profileID: nil, profileName: nil, confidence: bestConfidence, assignmentState: .anonymous)
    }

    private static func cosineSimilarity(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -1 }
        let dot = zip(lhs, rhs).map(*).reduce(0, +)
        let lhsNorm = sqrt(lhs.map { $0 * $0 }.reduce(0, +))
        let rhsNorm = sqrt(rhs.map { $0 * $0 }.reduce(0, +))
        guard lhsNorm > 0, rhsNorm > 0 else { return -1 }
        return dot / (lhsNorm * rhsNorm)
    }
}

private extension ProcessInfo {
    var machineHardwareName: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(decoding: machine.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
