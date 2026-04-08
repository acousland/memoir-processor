import AppKit
import Foundation
import MemoirProcessorCore

@MainActor
final class AppViewModel: ObservableObject {
    @Published var config: AppConfig = .default()
    @Published var sessions: [SessionListItem] = []
    @Published var selectedSessionID: String?
    @Published var selectedStatus: SessionStatusResponse?
    @Published var serviceStatus: String = "Unknown"
    @Published var serviceInstalled = false
    @Published var serviceCurrentVersion = false
    @Published var serviceRunning = false
    @Published var message: String?

    private let configStore = ConfigStore()
    private var store: SessionStore?
    private let serviceManager = ServiceManager()

    init() {
        Task { await reload() }
    }

    func reload() async {
        do {
            config = try configStore.load()
            store = try SessionStore(config: config)
            sessions = try store?.listSessions() ?? []
            if let selectedSessionID {
                selectedStatus = try store?.fetchStatus(sessionID: selectedSessionID)
            }
            apply(serviceState: serviceManager.serviceState())
        } catch {
            message = error.localizedDescription
        }
    }

    func saveConfig() async {
        do {
            try configStore.save(config)
            store = try SessionStore(config: config)
            apply(serviceState: serviceManager.serviceState())
        } catch {
            message = error.localizedDescription
        }
    }

    func select(sessionID: String?) async {
        selectedSessionID = sessionID
        guard let sessionID, let store else {
            selectedStatus = nil
            return
        }
        do {
            selectedStatus = try store.fetchStatus(sessionID: sessionID)
        } catch {
            message = error.localizedDescription
        }
    }

    func installService() async {
        do {
            try configStore.save(config)
            try serviceManager.install(config: config)
            apply(serviceState: serviceManager.serviceState())
        } catch {
            message = error.localizedDescription
        }
    }

    func startService() async {
        do {
            try serviceManager.start()
            apply(serviceState: serviceManager.serviceState())
        } catch {
            message = error.localizedDescription
        }
    }

    func stopService() async {
        do {
            try serviceManager.stop()
            apply(serviceState: serviceManager.serviceState())
        } catch {
            message = error.localizedDescription
        }
    }

    func retrySelectedSession() async {
        guard let selectedSessionID, let store else { return }
        do {
            try store.retrySession(sessionID: selectedSessionID)
            await reload()
        } catch {
            message = error.localizedDescription
        }
    }

    func stopSelectedSession() async {
        guard let selectedSessionID, let store else { return }
        do {
            try store.requestStopSession(sessionID: selectedSessionID)
            await reload()
        } catch {
            message = error.localizedDescription
        }
    }

    func removeSelectedSession() async {
        guard let selectedSessionID, let store else { return }
        do {
            try store.removeSession(sessionID: selectedSessionID)
            self.selectedSessionID = nil
            self.selectedStatus = nil
            await reload()
        } catch {
            message = error.localizedDescription
        }
    }

    func revealSelectedSession() {
        guard let selectedSessionID else { return }
        NSWorkspace.shared.activateFileViewerSelecting([ProcessorPaths.sessionDirectory(for: config, sessionID: selectedSessionID)])
    }

    func logsForSelectedSession() -> String {
        guard let selectedSessionID else { return "" }
        let url = ProcessorPaths.logsURL(for: config, sessionID: selectedSessionID)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func apply(serviceState: ServiceState) {
        serviceStatus = serviceState.statusText
        serviceInstalled = serviceState.isInstalled
        serviceCurrentVersion = serviceState.isCurrentVersion
        serviceRunning = serviceState.isRunning
    }
}
