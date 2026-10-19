import Foundation

public struct SubprocessResult: Sendable {
    public let status: Int32
    public let output: Data
    public let error: Data
}

private final class PipeReader: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ data: Data) { lock.lock(); defer { lock.unlock() }; self.data = data }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

public enum SubprocessRunner {
    /// Drain both pipes while the child is running, so large transcripts and model logs cannot block it.
    public static func run(executable: URL, arguments: [String], environment: [String: String]? = nil, timeout: TimeInterval = 3600, onStart: ((Int32) -> Void)? = nil) throws -> SubprocessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let out = PipeReader(), err = PipeReader()
        let readers = DispatchGroup()
        try process.run()
        onStart?(process.processIdentifier)
        readers.enter()
        DispatchQueue.global().async { out.set(stdout.fileHandleForReading.readDataToEndOfFile()); readers.leave() }
        readers.enter()
        DispatchQueue.global().async { err.set(stderr.fileHandleForReading.readDataToEndOfFile()); readers.leave() }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { process.waitUntilExit(); finished.signal() }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 5) == .timedOut { kill(process.processIdentifier, SIGKILL); finished.wait() }
            readers.wait()
            throw ProcessorError(code: "worker_timeout", message: "Worker exceeded its time limit.", retryable: true)
        }
        readers.wait()
        return SubprocessResult(status: process.terminationStatus, output: out.get(), error: err.get())
    }
}
