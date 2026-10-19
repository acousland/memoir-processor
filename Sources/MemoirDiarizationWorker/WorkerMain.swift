import CoreML
import Darwin
import FluidAudio
import Foundation

@main
enum DiarizationWorkerMain {
    static func main() async {
        // Reserve stdout for the single JSON response, including library prints.
        let outputFD = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
        do {
            let arguments = CommandLine.arguments
            func value(_ name: String) throws -> String {
                guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
                    throw NSError(domain: "MemoirDiarization", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing \(name)"])
                }
                return arguments[index + 1]
            }
            let directory = URL(fileURLWithPath: try value("--models"), isDirectory: true)
            let configuration = MLModelConfiguration()
            // Core ML may use CPU for unsupported operations; Apple chooses the
            // placement of neural-network operations across CPU and Neural Engine.
            configuration.computeUnits = .cpuAndNeuralEngine
            let models = try await OfflineDiarizerModels.load(from: directory, configuration: configuration)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("{\"version\":\"0.17.7\"}".utf8).write(to: directory.appendingPathComponent("ready.json"), options: .atomic)
            if arguments.contains("--prepare") {
                output.write(try JSONSerialization.data(withJSONObject: ["status": "ready"]))
                return
            }
            let audio = URL(fileURLWithPath: try value("--audio"))
            let track = try value("--source-track")
            let manager = OfflineDiarizerManager()
            manager.initialize(models: models)
            let result: DiarizationResult
            do { result = try await manager.process(audio) }
            catch OfflineDiarizationError.noSpeechDetected {
                output.write(try JSONSerialization.data(withJSONObject: ["runtime": "FluidAudio offline VBx", "backend": "coreml-cpu+ane", "turns": [], "embeddings": []]))
                return
            }
            let turns: [[String: Any]] = result.segments.map { segment in
                ["cluster_id": "\(track):\(segment.speakerId)", "start": Double(segment.startTimeSeconds),
                 "end": Double(segment.endTimeSeconds), "source_track": track]
            }
            let durations = Dictionary(grouping: result.segments, by: \.speakerId).mapValues {
                $0.reduce(0.0) { $0 + Double($1.durationSeconds) }
            }
            let embeddings: [[String: Any]] = (result.speakerDatabase ?? [:]).sorted { $0.key < $1.key }.compactMap { speaker, vector in
                guard !vector.isEmpty, vector.allSatisfy({ $0.isFinite }) else { return nil }
                return ["clusterID": "\(track):\(speaker)", "durationSeconds": durations[speaker] ?? 0,
                        "embedding": vector.map(Double.init), "sourceTrack": track]
            }
            let payload: [String: Any] = ["runtime": "FluidAudio offline VBx", "backend": "coreml-cpu+ane", "turns": turns, "embeddings": embeddings]
            output.write(try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        } catch {
            fputs("FluidAudio diarization failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
