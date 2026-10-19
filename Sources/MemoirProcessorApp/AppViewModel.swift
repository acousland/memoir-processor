import AppKit
import Foundation
import MemoirProcessorCore

@MainActor
final class AppViewModel: ObservableObject {
    @Published var config: AppConfig = .default()
    @Published var sessions: [SessionListItem] = []
    @Published var speakerProfiles: [SpeakerProfile] = []
    @Published var sessionSpeakers: [SessionSpeaker] = []
    @Published var selectedSessionID: String?
    @Published var selectedStatus: SessionStatusResponse?
    @Published var serviceStatus: String = "Unknown"
    @Published var serviceInstalled = false
    @Published var serviceCurrentVersion = false
    @Published var serviceRunning = false
    @Published var runtimeStatus = RuntimeDependencyStatus(
        appleSiliconAvailable: false,
        pythonAvailable: false,
        whisperKitConfigured: false,
        diarizationInstalled: false,
        ffmpegAvailable: false,
        mpsAvailable: false,
        huggingFaceTokenConfigured: false
    )
    @Published var checkingDiarizationRuntime = false
    @Published var preparingDiarization = false
    @Published var huggingFaceToken: String = ""
    @Published var message: String?

    private let configStore = ConfigStore()
    private var store: SessionStore?
    private let serviceManager = ServiceManager()
    private let runtimeDependencyManager = RuntimeDependencyManager()

    init() {
        Task {
            await reload()
            do { try UpdateServiceLifecycle.restartAfterUpdateIfNeeded(config: config) }
            catch { message = "Unable to restart the updated service: " + error.localizedDescription }
        }
    }

    func refreshSessionStatuses() async {
        guard let store else { return }
        do {
            sessions = try store.listSessions()
            apply(serviceState: serviceManager.serviceState())
            try loadSelectedSessionContext()
        } catch { message = error.localizedDescription }
    }

    func reload() async {
        do {
            config = try configStore.load()
            store = try SessionStore(config: config)
            sessions = try store?.listSessions() ?? []
            if selectedSessionID == nil { selectedSessionID = sessions.first?.id }
            speakerProfiles = try store?.listSpeakerProfiles() ?? []
            huggingFaceToken = runtimeDependencyManager.huggingFaceToken() ?? ""
            let configurationForStatus = config
            runtimeStatus = await Task.detached { RuntimeDependencyManager().currentStatus(config: configurationForStatus) }.value
            apply(serviceState: serviceManager.serviceState())
            try loadSelectedSessionContext()
        } catch {
            message = error.localizedDescription
        }
    }

    func saveConfig() async {
        do {
            try configStore.save(config)
            store = try SessionStore(config: config)
            let configurationForStatus = config
            runtimeStatus = await Task.detached { RuntimeDependencyManager().currentStatus(config: configurationForStatus) }.value
            apply(serviceState: serviceManager.serviceState())
            sessions = try store?.listSessions() ?? []
            speakerProfiles = try store?.listSpeakerProfiles() ?? []
            try loadSelectedSessionContext()
            message = "Configuration saved. Speaker engine changes apply to the next meeting."
        } catch {
            message = error.localizedDescription
        }
    }

    func selectDiarizationEngine(_ engine: DiarizationEngine) {
        config = config.updating(diarizationEngine: engine)
        checkingDiarizationRuntime = true
        let snapshot = config
        Task {
            let status = await Task.detached { RuntimeDependencyManager().currentStatus(config: snapshot) }.value
            guard config.diarizationEngine == engine else { return }
            runtimeStatus = status
            checkingDiarizationRuntime = false
        }
    }

    func saveHuggingFaceToken() async {
        do {
            try runtimeDependencyManager.saveHuggingFaceToken(huggingFaceToken)
            let configurationForStatus = config
            runtimeStatus = await Task.detached { RuntimeDependencyManager().currentStatus(config: configurationForStatus) }.value
            message = huggingFaceToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Hugging Face token cleared."
                : "Hugging Face token saved to Keychain."
        } catch {
            message = error.localizedDescription
        }
    }

    func select(sessionID: String?) async {
        selectedSessionID = sessionID
        do {
            try loadSelectedSessionContext()
        } catch {
            message = error.localizedDescription
        }
    }

    func installService() async {
        do {
            try configStore.save(config)
            try serviceManager.install(config: config)
            apply(serviceState: serviceManager.serviceState())
            message = "Launch agent installed."
        } catch {
            message = error.localizedDescription
        }
    }

    func startService() async {
        do {
            try serviceManager.start()
            apply(serviceState: serviceManager.serviceState())
            message = "Service started."
        } catch {
            message = error.localizedDescription
        }
    }

    func stopService() async {
        do {
            try serviceManager.stop()
            apply(serviceState: serviceManager.serviceState())
            message = "Service stopped."
        } catch {
            message = error.localizedDescription
        }
    }

    func prepareWhisperModel() async {
        do {
            let configuration = config
            let response = try await Task.detached { try ServiceManager().prepareWhisperModel(config: configuration) }.value
            let configurationForStatus = config
            runtimeStatus = await Task.detached { RuntimeDependencyManager().currentStatus(config: configurationForStatus) }.value
            let model = response["model"] ?? config.modelName
            message = "WhisperKit model '\(model)' is ready."
        } catch {
            message = error.localizedDescription
        }
    }

    func installDiarizationRuntime() async {
        guard !preparingDiarization else { return }
        preparingDiarization = true
        defer { preparingDiarization = false }
        do {
            let configuration = config
            try await Task.detached { try RuntimeDependencyManager().installDiarizationRuntime(config: configuration) }.value
            let configurationForStatus = config
            runtimeStatus = await Task.detached { RuntimeDependencyManager().currentStatus(config: configurationForStatus) }.value
            message = "Diarization runtime installed."
        } catch {
            message = error.localizedDescription
        }
    }

    func installFFmpeg() async {
        do {
            try await Task.detached { try RuntimeDependencyManager().installFFmpeg() }.value
            let configurationForStatus = config
            runtimeStatus = await Task.detached { RuntimeDependencyManager().currentStatus(config: configurationForStatus) }.value
            message = "ffmpeg installed."
        } catch {
            message = error.localizedDescription
        }
    }

    func retrySelectedSession() async {
        guard let selectedSessionID, let store else { return }
        do {
            try store.retrySession(sessionID: selectedSessionID)
            do {
                try serviceManager.kickQueue(config: config)
            } catch {
                message = "Session moved to retry queue, but the agent could not be woken immediately: \(error.localizedDescription)"
            }
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
            self.sessionSpeakers = []
            await reload()
        } catch {
            message = error.localizedDescription
        }
    }

    func assignSelectedSpeaker(clusterID: String, to profileID: String) async {
        guard
            let selectedSessionID,
            let store,
            let profile = speakerProfiles.first(where: { $0.id == profileID }),
            let speaker = sessionSpeakers.first(where: { $0.clusterID == clusterID })
        else {
            return
        }

        do {
            if let embedding = try store.sessionSpeakerEmbedding(sessionID: selectedSessionID, clusterID: clusterID) {
                let quality = min(1.0, max(0.25, speaker.speakingDurationSeconds / 10.0))
                try store.saveEmbedding(profileID: profileID, sessionID: selectedSessionID, clusterID: clusterID, vector: embedding, qualityScore: quality)
            }
            try store.assignSessionSpeaker(sessionID: selectedSessionID, clusterID: clusterID, profileID: profileID, profileName: profile.name)
            try loadSelectedSessionContext()
            speakerProfiles = try store.listSpeakerProfiles()
            sessions = try store.listSessions()
            message = "Assigned \(speaker.displayLabel) to \(profile.name)."
        } catch {
            message = error.localizedDescription
        }
    }

    func createProfileAndAssignSelectedSpeaker(clusterID: String, name: String) async {
        guard let store else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            message = "Enter a name before creating a person."
            return
        }

        do {
            let profile = try store.createSpeakerProfile(name: trimmedName)
            speakerProfiles = try store.listSpeakerProfiles()
            await assignSelectedSpeaker(clusterID: clusterID, to: profile.id)
        } catch {
            message = error.localizedDescription
        }
    }

    func renameSpeakerProfile(profileID: String, newName: String) async {
        guard let store else { return }
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            message = "Speaker names cannot be empty."
            return
        }

        do {
            try store.renameSpeakerProfile(profileID: profileID, name: trimmedName)
            speakerProfiles = try store.listSpeakerProfiles()
            try loadSelectedSessionContext()
            message = "Updated speaker name."
        } catch {
            message = error.localizedDescription
        }
    }

    func archiveSpeakerProfile(profileID: String) async {
        guard let store else { return }
        do {
            try store.archiveSpeakerProfile(profileID: profileID)
            speakerProfiles = try store.listSpeakerProfiles()
            try loadSelectedSessionContext()
            message = "Speaker archived."
        } catch {
            message = error.localizedDescription
        }
    }

    func revealSelectedSession() {
        guard let selectedSessionID else { return }
        NSWorkspace.shared.activateFileViewerSelecting([ProcessorPaths.sessionDirectory(for: config, sessionID: selectedSessionID)])
    }

    func openSelectedTranscriptTXT() {
        openSelectedArtifact(named: "transcript.txt")
    }

    func openSelectedTranscriptJSON() {
        openSelectedArtifact(named: "transcript.json")
    }

    func openSelectedTranscriptSRT() {
        openSelectedArtifact(named: "transcript.srt")
    }

    func openSelectedDiarizationJSON() {
        openSelectedArtifact(named: "diarization.json")
    }

    func selectedArtifactExists(named name: String) -> Bool {
        guard let selectedSessionID, let store else { return false }
        let url = store.artifactPath(sessionID: selectedSessionID, name: name)
        return FileManager.default.fileExists(atPath: url.path)
    }

    func logsForSelectedSession() -> String {
        guard let selectedSessionID else { return "" }
        let url = ProcessorPaths.logsURL(for: config, sessionID: selectedSessionID)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func transcriptPreviewForSpeaker(_ speaker: SessionSpeaker) -> String {
        speaker.representativeText ?? "No representative transcript available yet."
    }

    private func apply(serviceState: ServiceState) {
        serviceStatus = serviceState.statusText
        serviceInstalled = serviceState.isInstalled
        serviceCurrentVersion = serviceState.isCurrentVersion
        serviceRunning = serviceState.isRunning
    }

    private func loadSelectedSessionContext() throws {
        guard let store else {
            selectedStatus = nil
            sessionSpeakers = []
            return
        }

        guard let selectedSessionID else {
            selectedStatus = nil
            sessionSpeakers = []
            return
        }

        selectedStatus = try store.fetchStatus(sessionID: selectedSessionID)
        sessionSpeakers = try store.listSessionSpeakers(sessionID: selectedSessionID)
    }

    private func openSelectedArtifact(named name: String) {
        guard let selectedSessionID, let store else { return }
        let url = store.artifactPath(sessionID: selectedSessionID, name: name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            message = "\(name) is not available for this session yet."
            return
        }
        NSWorkspace.shared.open(url)
    }
}
