import SwiftUI
import MemoirProcessorCore

struct ContentView: View {
    private enum WorkspaceSection: String, CaseIterable, Identifiable {
        case sessions = "Sessions"
        case people = "People"
        case settings = "Settings"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .sessions:
                return "waveform.and.mic"
            case .people:
                return "person.2"
            case .settings:
                return "gearshape"
            }
        }
    }

    @ObservedObject var viewModel: AppViewModel
    @State private var selectedSection: WorkspaceSection = .sessions

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                Section("Workspace") {
                    ForEach(WorkspaceSection.allCases) { section in
                        Label(section.rawValue, systemImage: section.systemImage)
                            .tag(section)
                    }
                }
            }
            .toolbar {
                Button("Refresh") {
                    Task { await viewModel.reload() }
                }
            }
        } detail: {
            Group {
                switch selectedSection {
                case .sessions:
                    sessionsWorkspace
                case .people:
                    peopleWorkspace
                case .settings:
                    settingsWorkspace
                }
            }
            .padding(24)
        }
        .task {
            while !Task.isCancelled {
                await viewModel.refreshSessionStatuses()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .alert("Memoir Processor", isPresented: Binding(
            get: { viewModel.message != nil },
            set: { if !$0 { viewModel.message = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.message ?? "")
        }
    }

    private var settingsWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                configurationCard
                Divider()
                serviceCard
                Divider()
                runtimeCard
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var peopleWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("People")
                    .font(.title2.bold())
                Text("Recurring speakers live here after you confirm diarized speakers from a session. Manual naming stays in control, and future matches only auto-apply when confidence is high.")
                    .foregroundStyle(.secondary)

                if viewModel.speakerProfiles.isEmpty {
                    emptyStateCard(
                        title: "No named speakers yet",
                        detail: "Assign a diarized speaker from a completed session to create the first person profile."
                    )
                } else {
                    ForEach(viewModel.speakerProfiles) { profile in
                        SpeakerProfileCard(
                            profile: profile,
                            onRename: { newName in
                                Task { await viewModel.renameSpeakerProfile(profileID: profile.id, newName: newName) }
                            },
                            onArchive: {
                                Task { await viewModel.archiveSpeakerProfile(profileID: profile.id) }
                            }
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sessionsWorkspace: some View {
        HSplitView {
            sessionsList
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 380)

            sessionCard
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var sessionsList: some View {
        List(selection: Binding(
            get: { viewModel.selectedSessionID },
            set: { newValue in Task { await viewModel.select(sessionID: newValue) } }
        )) {
            Section("Recording Sessions") {
                ForEach(viewModel.sessions) { session in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(session.sessionName)
                                .font(.headline)
                            if session.warningCount > 0 {
                                Label("\(session.warningCount)", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption.bold())
                                    .foregroundStyle(.orange)
                            }
                        }
                        Text("\(session.ingestionState.rawValue) • \(session.processingState?.rawValue ?? "not_started")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let errorMessage = session.errorMessage, !errorMessage.isEmpty {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 4)
                    .tag(Optional(session.id))
                }
            }
        }
        .listStyle(.inset)
    }

    private var configurationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configuration")
                .font(.title2.bold())

            HStack {
                TextField("Bind host", text: Binding(
                    get: { viewModel.config.bindHost },
                    set: { viewModel.config = viewModel.config.updating(bindHost: $0) }
                ))
                TextField("Port", value: Binding(
                    get: { viewModel.config.port },
                    set: { viewModel.config = viewModel.config.updating(port: $0) }
                ), format: .number)
                .frame(maxWidth: 120)
            }

            Toggle("Use HTTPS", isOn: Binding(
                get: { viewModel.config.tlsEnabled },
                set: { viewModel.config = viewModel.config.updating(tlsEnabled: $0) }
            ))

            HStack {
                TextField("Model", text: Binding(
                    get: { viewModel.config.modelName },
                    set: { viewModel.config = viewModel.config.updating(modelName: $0) }
                ))
                Stepper("Max retries: \(viewModel.config.maxRetries)", value: Binding(
                    get: { viewModel.config.maxRetries },
                    set: { viewModel.config = viewModel.config.updating(maxRetries: $0) }
                ), in: 1...10)
            }

            Toggle("Enable diarization", isOn: Binding(
                get: { viewModel.config.diarizationEnabled },
                set: { viewModel.config = viewModel.config.updating(diarizationEnabled: $0) }
            ))

            Toggle("Allow CPU fallback for diarization", isOn: Binding(
                get: { viewModel.config.allowCPUFallbackForDiarization },
                set: { viewModel.config = viewModel.config.updating(allowCPUFallbackForDiarization: $0) }
            ))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Auto-match threshold")
                    Spacer()
                    Text(viewModel.config.speakerAutoMatchThreshold, format: .number.precision(.fractionLength(2)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(
                    get: { viewModel.config.speakerAutoMatchThreshold },
                    set: { viewModel.config = viewModel.config.updating(speakerAutoMatchThreshold: $0) }
                ), in: 0.55...0.99, step: 0.01)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Storage")
                    .font(.subheadline.weight(.semibold))
                Text(viewModel.config.storageRoot)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("API Token")
                    .font(.subheadline.weight(.semibold))
                Text(viewModel.config.authToken)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }

            Button("Save Configuration") {
                Task { await viewModel.saveConfig() }
            }
        }
    }

    private var serviceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Service")
                .font(.title2.bold())
            Text("Status: \(viewModel.serviceStatus)")
            if viewModel.serviceInstalled && !viewModel.serviceCurrentVersion {
                Text("Installed agent does not match this app build. Reinstall to refresh it.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("Install Launch Agent") {
                    Task { await viewModel.installService() }
                }
                .disabled(viewModel.serviceInstalled && viewModel.serviceCurrentVersion)

                Button("Start") {
                    Task { await viewModel.startService() }
                }
                .disabled(!viewModel.serviceInstalled || viewModel.serviceRunning)

                Button("Stop") {
                    Task { await viewModel.stopService() }
                }
                .disabled(!viewModel.serviceInstalled || !viewModel.serviceRunning)
            }
        }
    }

    private var runtimeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Runtime")
                .font(.title2.bold())

            Group {
                Text("Apple Silicon: \(viewModel.runtimeStatus.appleSiliconAvailable ? "Available" : "Missing")")
                Text("WhisperKit model: \(viewModel.runtimeStatus.whisperKitConfigured ? "Ready" : "Download required")")
                Text("Python: \(viewModel.runtimeStatus.pythonAvailable ? "Installed" : "Missing")")
                Text("Diarization runtime: \(viewModel.runtimeStatus.diarizationRuntimeLabel)")
                Text("ffmpeg: \(viewModel.runtimeStatus.ffmpegAvailable ? "Installed" : "Missing")")
                Text("GPU/MPS: \(viewModel.runtimeStatus.mpsAvailable ? "Available" : "Unavailable")")
            }
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Hugging Face Token")
                    .font(.subheadline.weight(.semibold))
                SecureField("Required for pyannote model access", text: $viewModel.huggingFaceToken)
                HStack {
                    Button("Save Token") {
                        Task { await viewModel.saveHuggingFaceToken() }
                    }
                    Text(viewModel.runtimeStatus.huggingFaceTokenConfigured ? "Stored in Keychain" : "Not configured")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Prepare WhisperKit Model") {
                    Task { await viewModel.prepareWhisperModel() }
                }
                .disabled(!viewModel.serviceRunning)

                Button("Install Diarization Runtime") {
                    Task { await viewModel.installDiarizationRuntime() }
                }
                .disabled(!viewModel.runtimeStatus.pythonAvailable || viewModel.runtimeStatus.diarizationInstalled)

                Button("Install ffmpeg") {
                    Task { await viewModel.installFFmpeg() }
                }
                .disabled(viewModel.runtimeStatus.ffmpegAvailable)
            }

            Text(viewModel.serviceRunning
                 ? "The running agent can pre-download the WhisperKit model and use it for GPU/Core ML transcription."
                 : "Start the service before preparing the WhisperKit model.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var sessionCard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Session Detail")
                    .font(.title2.bold())

                if let selected = viewModel.selectedStatus {
                    sessionOverviewCard(selected)
                    sessionWarningCard(selected.warnings)
                    sessionActions
                    transcriptActions
                    speakersCard
                    logsCard
                } else {
                    emptyStateCard(
                        title: "No session selected",
                        detail: "Choose a session on the left to inspect progress, logs, transcript artifacts, and speaker assignments."
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func sessionOverviewCard(_ selected: SessionStatusResponse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(selected.sessionName)
                .font(.headline)
            Text("Ingestion: \(selected.ingestionState.rawValue)")
            Text("Processing: \(selected.processingState?.rawValue ?? "not_started")")
            Text("Updated: \(selected.updatedAt)")
            if let error = selected.error {
                Text("Error: \(error.code) – \(error.message)")
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func sessionWarningCard(_ warnings: [SessionWarning]) -> some View {
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Warnings")
                    .font(.headline)
                ForEach(warnings) { warning in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(warning.code)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                        Text(warning.message)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.orange.opacity(0.08))
                    )
                }
            }
        }
    }

    private var sessionActions: some View {
        HStack {
            Button("Retry") {
                Task { await viewModel.retrySelectedSession() }
            }
            Button("Stop") {
                Task { await viewModel.stopSelectedSession() }
            }
            .foregroundStyle(.orange)
            Button("Remove") {
                Task { await viewModel.removeSelectedSession() }
            }
            .foregroundStyle(.red)
            Button("Reveal in Finder") {
                viewModel.revealSelectedSession()
            }
        }
    }

    private var transcriptActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Artifacts")
                .font(.headline)

            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 160), alignment: .leading)
            ], alignment: .leading, spacing: 10) {
                Button("Open Transcript") {
                    viewModel.openSelectedTranscriptTXT()
                }
                .disabled(!viewModel.selectedArtifactExists(named: "transcript.txt"))

                Button("Open JSON") {
                    viewModel.openSelectedTranscriptJSON()
                }
                .disabled(!viewModel.selectedArtifactExists(named: "transcript.json"))

                Button("Open SRT") {
                    viewModel.openSelectedTranscriptSRT()
                }
                .disabled(!viewModel.selectedArtifactExists(named: "transcript.srt"))

                Button("Open Diarization") {
                    viewModel.openSelectedDiarizationJSON()
                }
                .disabled(!viewModel.selectedArtifactExists(named: "diarization.json"))
            }
        }
    }

    private var speakersCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Speakers")
                .font(.headline)

            if viewModel.sessionSpeakers.isEmpty {
                Text("No speaker clusters yet. Enable diarization and process a session to populate this area.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.sessionSpeakers) { speaker in
                    SessionSpeakerCard(
                        speaker: speaker,
                        profiles: viewModel.speakerProfiles,
                        representativeText: viewModel.transcriptPreviewForSpeaker(speaker),
                        onAssignExisting: { profileID in
                            Task { await viewModel.assignSelectedSpeaker(clusterID: speaker.clusterID, to: profileID) }
                        },
                        onCreateAndAssign: { name in
                            Task { await viewModel.createProfileAndAssignSelectedSpeaker(clusterID: speaker.clusterID, name: name) }
                        }
                    )
                }
            }
        }
    }

    private var logsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Processing Log")
                .font(.headline)
            ScrollView {
                Text(viewModel.logsForSelectedSession())
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 20)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 28)
            }
            .frame(minHeight: 360)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            )
        }
    }

    private func emptyStateCard(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(detail)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}

private struct SessionSpeakerCard: View {
    let speaker: SessionSpeaker
    let profiles: [SpeakerProfile]
    let representativeText: String
    let onAssignExisting: (String) -> Void
    let onCreateAndAssign: (String) -> Void

    @State private var newProfileName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(speaker.displayLabel)
                    .font(.headline)
                Text(speaker.assignmentState.rawValue)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }

            HStack(spacing: 14) {
                Text("Source: \(speaker.sourceTrack.rawValue)")
                Text("Duration: \(speaker.speakingDurationSeconds, format: .number.precision(.fractionLength(1)))s")
                if let confidence = speaker.matchConfidence {
                    Text("Confidence: \(confidence, format: .percent.precision(.fractionLength(0)))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(representativeText)
                .foregroundStyle(.secondary)

            HStack {
                Menu("Assign to Existing Person") {
                    ForEach(profiles) { profile in
                        Button(profile.name) {
                            onAssignExisting(profile.id)
                        }
                    }
                }
                .disabled(profiles.isEmpty)

                if speaker.assignmentState == .suggested, let suggestedProfileID = speaker.matchedProfileID, let suggestedName = speaker.matchedProfileName {
                    Button("Confirm \(suggestedName)") {
                        onAssignExisting(suggestedProfileID)
                    }
                }
            }

            HStack {
                TextField("New person name", text: $newProfileName)
                Button("Create & Assign") {
                    let name = newProfileName
                    newProfileName = ""
                    onCreateAndAssign(name)
                }
                .disabled(newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}

private struct SpeakerProfileCard: View {
    let profile: SpeakerProfile
    let onRename: (String) -> Void
    let onArchive: () -> Void

    @State private var renameDraft: String

    init(profile: SpeakerProfile, onRename: @escaping (String) -> Void, onArchive: @escaping () -> Void) {
        self.profile = profile
        self.onRename = onRename
        self.onArchive = onArchive
        _renameDraft = State(initialValue: profile.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(profile.name)
                    .font(.headline)
                Spacer()
                Text("\(profile.sampleCount) sample\(profile.sampleCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Last seen: \(profile.lastSeenAt ?? "Never")")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField("Rename person", text: $renameDraft)
                Button("Rename") {
                    onRename(renameDraft)
                }
                .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || renameDraft == profile.name)

                Button("Archive") {
                    onArchive()
                }
                .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}
