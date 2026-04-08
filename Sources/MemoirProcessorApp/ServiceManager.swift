import Foundation
import MemoirProcessorCore

struct ServiceState {
    let statusText: String
    let isInstalled: Bool
    let isCurrentVersion: Bool
    let isRunning: Bool
}

final class ServiceManager {
    private let label = "com.memoir.processor.agent"

    func install(config: AppConfig) throws {
        let plistURL = try launchAgentPlistURL()
        try FileManager.default.createDirectory(at: ProcessorPaths.root(for: config), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try launchAgentPlist(config: config).write(to: plistURL, atomically: true, encoding: .utf8)
        _ = try runLaunchctl(arguments: ["bootout", "gui/\(getuid())", plistURL.path], allowFailure: true)
        _ = try runLaunchctl(arguments: ["bootstrap", "gui/\(getuid())", plistURL.path], allowFailure: false)
    }

    func start() throws {
        guard try isInstalled() else {
            throw ProcessorError(
                code: "service_not_installed",
                message: "The Memoir Processor launch agent is not installed yet. Click 'Install Launch Agent' first.",
                retryable: false
            )
        }
        let loaded = runLaunchctlUnchecked(arguments: ["print", "gui/\(getuid())/\(label)"]).terminationStatus == 0
        if loaded {
            _ = try runLaunchctl(arguments: ["kickstart", "-k", "gui/\(getuid())/\(label)"], allowFailure: false)
        } else {
            let plistURL = try launchAgentPlistURL()
            _ = try runLaunchctl(arguments: ["bootstrap", "gui/\(getuid())", plistURL.path], allowFailure: false)
        }
    }

    func stop() throws {
        guard try isInstalled() else {
            throw ProcessorError(
                code: "service_not_installed",
                message: "The Memoir Processor launch agent is not installed yet.",
                retryable: false
            )
        }
        _ = try runLaunchctl(arguments: ["bootout", "gui/\(getuid())/\(label)"], allowFailure: false)
    }

    func serviceState() -> ServiceState {
        let installed = (try? isInstalled()) == true
        guard installed else {
            return ServiceState(statusText: "Not installed", isInstalled: false, isCurrentVersion: false, isRunning: false)
        }

        let printResult = runLaunchctlUnchecked(arguments: ["print", "gui/\(getuid())/\(label)"])
        let output = printResult.output.lowercased()
        let running = printResult.terminationStatus == 0 && output.contains("state = running")
        let currentVersion = (try? isInstalledCurrentVersion()) ?? false

        if running {
            return ServiceState(statusText: "Running", isInstalled: true, isCurrentVersion: currentVersion, isRunning: true)
        }
        if printResult.terminationStatus != 0 || output.contains("state = waiting") || output.contains("active count = 0") {
            return ServiceState(statusText: "Stopped", isInstalled: true, isCurrentVersion: currentVersion, isRunning: false)
        }
        return ServiceState(statusText: "Installed", isInstalled: true, isCurrentVersion: currentVersion, isRunning: false)
    }

    private func launchAgentPlist(config: AppConfig) throws -> String {
        guard let executableURL = agentExecutableURL() else {
            throw ProcessorError(code: "configuration_invalid", message: "MemoirProcessorAgent executable could not be located.", retryable: false)
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(executableURL.path)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>WorkingDirectory</key>
            <string>\(ProcessorPaths.root(for: config).path)</string>
            <key>StandardOutPath</key>
            <string>\(ProcessorPaths.root(for: config).appendingPathComponent("agent.stdout.log").path)</string>
            <key>StandardErrorPath</key>
            <string>\(ProcessorPaths.root(for: config).appendingPathComponent("agent.stderr.log").path)</string>
        </dict>
        </plist>
        """
    }

    private func launchAgentPlistURL() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private func isInstalled() throws -> Bool {
        FileManager.default.fileExists(atPath: try launchAgentPlistURL().path)
    }

    private func isInstalledCurrentVersion() throws -> Bool {
        let plistURL = try launchAgentPlistURL()
        guard
            let plistData = NSDictionary(contentsOf: plistURL),
            let arguments = plistData["ProgramArguments"] as? [String],
            let installedPath = arguments.first,
            let currentPath = agentExecutableURL()?.path
        else {
            return false
        }

        return installedPath == currentPath
    }

    private func agentExecutableURL() -> URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MemoirProcessorAgent")
        if FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        let productsSibling = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("MemoirProcessorAgent")
        if FileManager.default.fileExists(atPath: productsSibling.path) {
            return productsSibling
        }
        return nil
    }

    private func runLaunchctl(arguments: [String], allowFailure: Bool) throws -> String {
        let result = runLaunchctlUnchecked(arguments: arguments)
        if !allowFailure && result.terminationStatus != 0 {
            throw ProcessorError(code: "service_command_failed", message: result.output, retryable: true)
        }
        return result.output.isEmpty ? "Running" : result.output
    }

    private func runLaunchctlUnchecked(arguments: [String]) -> (terminationStatus: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return (1, error.localizedDescription)
        }
        process.waitUntilExit()
        let data = stdout.fileHandleForReading.readDataToEndOfFile() + stderr.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }
}
