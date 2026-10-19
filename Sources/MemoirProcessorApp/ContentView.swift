import AppKit
import SwiftUI
import MemoirProcessorCore

struct ContentView: View {
    private enum WorkspaceSection: String, CaseIterable, Identifiable {
        case sessions = "Conversations", people = "People", settings = "Settings"
        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .sessions: "waveform"
            case .people: "person.2"
            case .settings: "slider.horizontal.3"
            }
        }
    }
    private enum DetailTab: String, CaseIterable, Identifiable {
        case overview = "Overview", speakers = "Speakers", logs = "Processing log"
        var id: String { rawValue }
    }
    private struct QueueMonth: Identifiable {
        let id: String
        let title: String
        var sessions: [SessionListItem]
    }

    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var updater: AppUpdater
    @State private var selectedSection: WorkspaceSection = .sessions
    @State private var selectedTab: DetailTab = .overview
    @State private var query = ""
    @State private var tokenVisible = false
    @State private var confirmRemoval = false

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 255, idealWidth: 290, maxWidth: 340)
            VStack(spacing: 0) {
                workspaceToolbar
                Group {
                    switch selectedSection {
                    case .sessions: sessionCard
                    case .people: peopleWorkspace
                    case .settings: settingsWorkspace
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(minWidth: 430).background(ThreadTheme.canvas)
        }
        .background(ThreadTheme.paper).foregroundStyle(ThreadTheme.ink).tint(ThreadTheme.accent)
        .task {
            while !Task.isCancelled {
                await viewModel.refreshSessionStatuses()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .onChange(of: viewModel.selectedSessionID) { _, _ in selectedTab = .overview }
        .alert("Memoir Processor", isPresented: Binding(get: { viewModel.message != nil }, set: { if !$0 { viewModel.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(viewModel.message ?? "") }
        .confirmationDialog("Remove this conversation and its local files?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Remove conversation", role: .destructive) { Task { await viewModel.removeSelectedSession() } }
        } message: { Text("This removes the recording, transcript and processing history from this processor.") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Label("MEMOIR PROCESSOR", systemImage: "waveform").font(.system(size: 10, weight: .medium)).tracking(1.2).foregroundStyle(ThreadTheme.accent)
                Text("Behind the words.").font(.system(size: 25, design: .serif)).italic().tracking(-0.7).lineLimit(1)
                Text("A private home for every word.").font(.system(size: 11)).foregroundStyle(ThreadTheme.muted)
            }.padding(.horizontal, 23).padding(.top, 22).padding(.bottom, 18)
            VStack(spacing: 4) {
                ForEach(WorkspaceSection.allCases) { section in
                    Button { selectedSection = section } label: {
                        HStack(spacing: 10) {
                            Image(systemName: section.systemImage).frame(width: 19)
                            Text(section.rawValue)
                            Spacer()
                            if section == .sessions { Text("\(viewModel.sessions.count)").font(.system(size: 10)).foregroundStyle(ThreadTheme.muted) }
                        }.font(.system(size: 12, weight: selectedSection == section ? .medium : .regular))
                            .padding(.horizontal, 13).padding(.vertical, 9)
                            .background(selectedSection == section ? ThreadTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).accessibilityAddTraits(selectedSection == section ? .isSelected : [])
                }
            }.padding(.horizontal, 17).padding(.bottom, 16)
            if selectedSection == .sessions {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(ThreadTheme.muted)
                    TextField("Find a conversation…", text: $query).textFieldStyle(.plain).font(.system(size: 12)).accessibilityLabel("Find a conversation")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }.padding(11).background(ThreadTheme.canvas, in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 19).padding(.bottom, 12)
                sessionsList
            } else { Spacer(minLength: 10) }
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Circle().fill(viewModel.serviceRunning ? ThreadTheme.accent : Color.orange).frame(width: 6, height: 6)
                    Text(viewModel.serviceRunning ? "Processor running" : viewModel.serviceStatus).font(.system(size: 11, weight: .medium))
                }
                Text("\(viewModel.config.modelName) · On this Mac").font(.system(size: 10)).foregroundStyle(ThreadTheme.muted).lineLimit(1)
            }.padding(.horizontal, 23).padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(ThreadTheme.line).frame(height: 1) }
        }.background(ThreadTheme.paper)
    }

    private var workspaceToolbar: some View {
        HStack {
            Text(selectedSection == .sessions ? "The processing archive" : selectedSection == .people ? "The people behind the words" : "Your private processor")
                .font(.system(size: 11)).foregroundStyle(ThreadTheme.muted)
            Spacer()
            Button { Task { await viewModel.reload() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(ThreadTheme.muted)
            Menu {
                CheckForUpdatesView(updater: updater)
                Divider()
                Button("Settings") { selectedSection = .settings }
            } label: { Image(systemName: "ellipsis.circle").font(.system(size: 17)).foregroundStyle(ThreadTheme.muted) }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Processor options")
        }.padding(.horizontal, 25).padding(.vertical, 17).background(ThreadTheme.paper)
            .overlay(alignment: .bottom) { Rectangle().fill(ThreadTheme.line).frame(height: 1) }
    }

    private var queueMonths: [QueueMonth] {
        let found = viewModel.sessions.filter { query.isEmpty || $0.sessionName.localizedStandardContains(query) }
        let formatter = DateFormatter(); formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        var groups: [QueueMonth] = []
        for session in found {
            let date = Self.date(session.createdAt)
            let components = date.map { Calendar.current.dateComponents([.era, .year, .month], from: $0) }
            let key = components.map { "\($0.era ?? 0)-\($0.year ?? 0)-\($0.month ?? 0)" } ?? "earlier"
            if groups.last?.id == key { groups[groups.count - 1].sessions.append(session) }
            else { groups.append(QueueMonth(id: key, title: date.map(formatter.string) ?? "Earlier conversations", sessions: [session])) }
        }
        return groups
    }

    private var sessionsList: some View {
        List(selection: Binding(get: { viewModel.selectedSessionID }, set: { value in Task { await viewModel.select(sessionID: value) } })) {
            ForEach(queueMonths) { month in
                Section {
                    ForEach(month.sessions) { session in
                        HStack(alignment: .top, spacing: 7) {
                            Rectangle().fill(ThreadTheme.line).frame(width: 1, height: 66).overlay(alignment: .top) {
                                Circle().fill(viewModel.selectedSessionID == session.id ? ThreadTheme.accent : ThreadTheme.line).frame(width: 6, height: 6).padding(.top, 6)
                            }.frame(width: 13)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(session.sessionName).font(.system(size: 13, weight: .medium)).lineLimit(2)
                                Text(Self.dateLabel(session.createdAt)).font(.system(size: 10)).foregroundStyle(ThreadTheme.muted)
                                HStack(spacing: 6) {
                                    Text(Self.stateLabel(session.processingState, ingestion: session.ingestionState))
                                    if session.warningCount > 0 { Label("\(session.warningCount)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                                }.font(.system(size: 10)).foregroundStyle(session.processingState == .failed ? Color.red : ThreadTheme.muted)
                            }.padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
                        }.tag(Optional(session.id)).accessibilityElement(children: .combine)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 2, leading: 15, bottom: 2, trailing: 15))
                            .listRowBackground(RoundedRectangle(cornerRadius: 8).fill(viewModel.selectedSessionID == session.id ? ThreadTheme.selection : ThreadTheme.paper))
                    }
                } header: {
                    Text(month.title.uppercased()).font(.system(size: 10, weight: .medium)).tracking(1.2).foregroundStyle(ThreadTheme.muted).padding(.vertical, 9)
                }
            }
            if queueMonths.isEmpty { Text(query.isEmpty ? "Conversations arrive here from your recorder." : "No matching conversations.").font(.callout).foregroundStyle(ThreadTheme.muted).padding(.vertical, 20) }
        }.listStyle(.plain).scrollContentBackground(.hidden)
    }

    private var settingsWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeading("A place for the details.", subtitle: "Connection, service and local transcription.")
                ThreadPanel { configurationCard }
                ThreadPanel { serviceCard }
                ThreadPanel { runtimeCard }
            }.padding(26).frame(maxWidth: 900).frame(maxWidth: .infinity)
        }
    }

    private var peopleWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeading("Familiar voices.", subtitle: "Name recurring speakers and confirm suggested matches. You stay in control.")
                if viewModel.speakerProfiles.isEmpty {
                    ThreadPanel { emptyStateCard(title: "No named speakers yet", detail: "Assign a diarized speaker from a completed conversation to create a person profile.") }
                } else {
                    ForEach(viewModel.speakerProfiles) { profile in
                        SpeakerProfileCard(profile: profile, onRename: { name in Task { await viewModel.renameSpeakerProfile(profileID: profile.id, newName: name) } }, onArchive: { Task { await viewModel.archiveSpeakerProfile(profileID: profile.id) } })
                    }
                }
            }.padding(26).frame(maxWidth: 900).frame(maxWidth: .infinity)
        }
    }

    private var sessionCard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let selected = viewModel.selectedStatus {
                    ThreadPanel {
                        sessionOverviewCard(selected)
                        sessionWarningCard(selected.warnings)
                        sessionActions
                    }
                    Picker("Session detail", selection: $selectedTab) {
                        ForEach(DetailTab.allCases) { tab in Text(tab.rawValue).tag(tab) }
                    }.pickerStyle(.segmented).labelsHidden()
                    ThreadPanel {
                        switch selectedTab {
                        case .overview: transcriptActions
                        case .speakers: speakersCard
                        case .logs: logsCard
                        }
                    }
                } else {
                    ThreadPanel { emptyStateCard(title: "Every word, looked after.", detail: "Choose a conversation to see its processing progress, transcript files and speaker assignments. Your recorder sends captures here automatically.") }
                }
            }.padding(26).frame(maxWidth: 950).frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private func pageHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 31, design: .serif)).tracking(-0.8)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(ThreadTheme.muted).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 8)
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    private static func dateLabel(_ value: String) -> String {
        date(value)?.formatted(.dateTime.day().month(.abbreviated).hour().minute()) ?? value
    }
    private static func stateLabel(_ state: ProcessingState?, ingestion: IngestionState) -> String {
        switch state {
        case .queued: "Queued for transcription"
        case .validating: "Preparing audio"
        case .transcribing: "Transcribing"
        case .diarizing: "Identifying speakers"
        case .writingArtifacts: "Finishing transcript"
        case .completed: "Transcript ready"
        case .failed: "Needs attention"
        case .retryPending: "Waiting to retry"
        case nil:
            switch ingestion {
            case .created, .uploading: "Receiving recording"
            case .uploaded, .readyForProcessing: "Ready to process"
            case .rejected: "Recording rejected"
            }
        }
    }
    private var configurationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configuration")
                .font(.system(size: 24, design: .serif))

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

            VStack(alignment: .leading, spacing: 12) {
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
                        .foregroundStyle(ThreadTheme.muted)
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
                    .foregroundStyle(ThreadTheme.muted)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("API Token")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 12) {
                    Text(tokenVisible ? viewModel.config.authToken : "••••••••••••••••••••••••")
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Spacer(minLength: 5)
                    Button(tokenVisible ? "Hide" : "Reveal") { tokenVisible.toggle() }
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(viewModel.config.authToken, forType: .string)
                    }
                }.font(.caption)
            }

            Button("Save Configuration") {
                Task { await viewModel.saveConfig() }
            }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        }
    }

    private var serviceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Service")
                .font(.system(size: 24, design: .serif))
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
                .font(.system(size: 24, design: .serif))

            Group {
                Text("Apple Silicon: \(viewModel.runtimeStatus.appleSiliconAvailable ? "Available" : "Missing")")
                Text("WhisperKit model: \(viewModel.runtimeStatus.whisperKitConfigured ? "Ready" : "Download required")")
                Text("Python: \(viewModel.runtimeStatus.pythonAvailable ? "Installed" : "Missing")")
                Text("Diarization runtime: \(viewModel.runtimeStatus.diarizationRuntimeLabel)")
                Text("ffmpeg: \(viewModel.runtimeStatus.ffmpegAvailable ? "Installed" : "Missing")")
                Text("GPU/MPS: \(viewModel.runtimeStatus.mpsAvailable ? "Available" : "Unavailable")")
            }
            .foregroundStyle(ThreadTheme.muted)

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
                        .foregroundStyle(ThreadTheme.muted)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
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
                .foregroundStyle(ThreadTheme.muted)
        }
    }

    private func sessionOverviewCard(_ selected: SessionStatusResponse) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("THE CONVERSATION").font(.system(size: 9, weight: .medium)).tracking(1.7).foregroundStyle(ThreadTheme.accent)
            Text(selected.sessionName).font(.system(size: 31, design: .serif)).tracking(-0.8).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text("Received \(Self.dateLabel(selected.createdAt))").font(.system(size: 11)).foregroundStyle(ThreadTheme.muted)
            Label(Self.stateLabel(selected.processingState, ingestion: selected.ingestionState), systemImage: selected.processingState == .completed ? "checkmark.circle" : selected.processingState == .failed ? "exclamationmark.circle" : "waveform")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(selected.processingState == .failed ? Color.red : ThreadTheme.accent)
                .padding(.horizontal, 11).padding(.vertical, 7).background(ThreadTheme.canvas, in: Capsule())
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) { fileReceipts(selected) }
                VStack(alignment: .leading, spacing: 9) { fileReceipts(selected) }
            }.font(.system(size: 11)).foregroundStyle(ThreadTheme.muted)
            if let error = selected.error {
                Text(error.message).font(.callout).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.bottom, 4)
    }

    @ViewBuilder private func fileReceipts(_ selected: SessionStatusResponse) -> some View {
        Label("Metadata", systemImage: selected.receivedFiles.metadata ? "checkmark.circle" : "circle.dashed")
        Label("Meeting audio", systemImage: selected.receivedFiles.system ? "checkmark.circle" : "circle.dashed")
        if selected.expectedFiles.mic { Label("Microphone", systemImage: selected.receivedFiles.mic ? "checkmark.circle" : "circle.dashed") }
    }

    @ViewBuilder
    private func sessionWarningCard(_ warnings: [SessionWarning]) -> some View {
        if !warnings.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(warnings) { warning in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(warning.code.replacingOccurrences(of: "_", with: " ").capitalized).font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
                            Text(warning.message).font(.system(size: 12)).foregroundStyle(ThreadTheme.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    }
                }.padding(.top, 10)
            } label: {
                Label("\(warnings.count) processing warning\(warnings.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
            }.tint(ThreadTheme.muted)
        }
    }

    private var sessionActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { sessionActionButtons }
            VStack(alignment: .leading, spacing: 12) { sessionActionButtons }
        }.font(.system(size: 11)).padding(.top, 8)
    }

    @ViewBuilder private var sessionActionButtons: some View {
        Button("Retry") { Task { await viewModel.retrySelectedSession() } }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        Button("Stop processing") { Task { await viewModel.stopSelectedSession() } }
        Menu {
            Button("Reveal in Finder") { viewModel.revealSelectedSession() }
            Divider()
            Button("Remove conversation…", role: .destructive) { confirmRemoval = true }
        } label: { Label("More", systemImage: "ellipsis") }.fixedSize()
    }

    private var transcriptActions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("The words, kept here.").font(.system(size: 23, design: .serif)).tracking(-0.4)
            Text("Finished transcripts are also available in your recorder’s conversation library.")
                .font(.system(size: 12)).foregroundStyle(ThreadTheme.muted).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), alignment: .leading)], alignment: .leading, spacing: 10) {
                artifactButton("Plain text", subtitle: "Transcript · TXT", symbol: "doc.text", file: "transcript.txt", action: viewModel.openSelectedTranscriptTXT)
                artifactButton("Subtitles", subtitle: "Timestamped · SRT", symbol: "captions.bubble", file: "transcript.srt", action: viewModel.openSelectedTranscriptSRT)
                artifactButton("Transcript data", subtitle: "Structured · JSON", symbol: "curlybraces", file: "transcript.json", action: viewModel.openSelectedTranscriptJSON)
                artifactButton("Speaker data", subtitle: "Diarization · JSON", symbol: "person.wave.2", file: "diarization.json", action: viewModel.openSelectedDiarizationJSON)
            }
        }
    }

    private func artifactButton(_ title: String, subtitle: String, symbol: String, file: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol).font(.system(size: 21, weight: .light)).foregroundStyle(ThreadTheme.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(ThreadTheme.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(ThreadTheme.muted)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(ThreadTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).disabled(!viewModel.selectedArtifactExists(named: file))
    }

    private var speakersCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The people behind the words.")
                .font(.system(size: 23, design: .serif)).tracking(-0.4)

            if viewModel.sessionSpeakers.isEmpty {
                Text("No speaker clusters yet. Enable diarization and process a session to populate this area.")
                    .foregroundStyle(ThreadTheme.muted)
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
        let log = viewModel.logsForSelectedSession()
        return VStack(alignment: .leading, spacing: 16) {
            Text("Behind the scenes.").font(.system(size: 23, design: .serif)).tracking(-0.4)
            Text("Processing log").font(.system(size: 11)).foregroundStyle(ThreadTheme.muted)
            if log.count > 60_000 { Text("Showing the most recent log entries. Reveal the conversation in Finder for the complete log.").font(.caption).foregroundStyle(ThreadTheme.muted) }
            Text(log.isEmpty ? "No processing messages yet." : String(log.suffix(60_000)))
                .font(.system(size: 11, design: .monospaced)).lineSpacing(5).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .background(ThreadTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func emptyStateCard(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 27, design: .serif)).tracking(-0.6)
            Text(detail)
                .foregroundStyle(ThreadTheme.muted)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(ThreadTheme.paper)
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
                    .background(Capsule().fill(ThreadTheme.selection))
            }

            HStack(spacing: 14) {
                Text("Source: \(speaker.sourceTrack.rawValue)")
                Text("Duration: \(speaker.speakingDurationSeconds, format: .number.precision(.fractionLength(1)))s")
                if let confidence = speaker.matchConfidence {
                    Text("Confidence: \(confidence, format: .percent.precision(.fractionLength(0)))")
                }
            }
            .font(.caption)
            .foregroundStyle(ThreadTheme.muted)

            Text(representativeText)
                .foregroundStyle(ThreadTheme.muted)

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
                .fill(ThreadTheme.paper)
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
                    .foregroundStyle(ThreadTheme.muted)
            }

            Text("Last seen: \(profile.lastSeenAt ?? "Never")")
                .font(.caption)
                .foregroundStyle(ThreadTheme.muted)

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
                .fill(ThreadTheme.paper)
        )
    }
}
