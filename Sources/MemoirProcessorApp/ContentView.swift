import SwiftUI
import MemoirProcessorCore

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { viewModel.selectedSessionID },
                set: { newValue in Task { await viewModel.select(sessionID: newValue) } }
            )) {
                Section("Sessions") {
                    ForEach(viewModel.sessions) { session in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.sessionName)
                                .font(.headline)
                            Text("\(session.ingestionState.rawValue) • \(session.processingState?.rawValue ?? "not_started")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(Optional(session.id))
                    }
                }
            }
            .toolbar {
                Button("Refresh") {
                    Task { await viewModel.reload() }
                }
            }
        } detail: {
            VStack(alignment: .leading, spacing: 20) {
                configurationCard
                Divider()
                serviceCard
                Divider()
                sessionCard
            }
            .padding(24)
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
                    set: { newPort in
                        viewModel.config = viewModel.config.updating(port: newPort)
                    }
                ), format: .number)
            }
            Toggle("Use HTTPS", isOn: Binding(
                get: { viewModel.config.tlsEnabled },
                set: { newValue in
                    viewModel.config = viewModel.config.updating(tlsEnabled: newValue)
                }
            ))
            HStack {
                TextField("Model", text: Binding(
                    get: { viewModel.config.modelName },
                    set: { newValue in
                        viewModel.config = viewModel.config.updating(modelName: newValue)
                    }
                ))
                Stepper("Max retries: \(viewModel.config.maxRetries)", value: Binding(
                    get: { viewModel.config.maxRetries },
                    set: { newValue in
                        viewModel.config = viewModel.config.updating(maxRetries: newValue)
                    }
                ), in: 1...10)
            }
            Toggle("Enable diarization", isOn: Binding(
                get: { viewModel.config.diarizationEnabled },
                set: { newValue in
                    viewModel.config = viewModel.config.updating(diarizationEnabled: newValue)
                }
            ))
            Text("Token: \(viewModel.config.authToken)")
                .font(.caption.monospaced())
                .textSelection(.enabled)
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

    private var sessionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Session Detail")
                .font(.title2.bold())
            if let selected = viewModel.selectedStatus {
                Text(selected.sessionName)
                    .font(.headline)
                Text("Ingestion: \(selected.ingestionState.rawValue)")
                Text("Processing: \(selected.processingState?.rawValue ?? "not_started")")
                Text("Updated: \(selected.updatedAt)")
                if let error = selected.error {
                    Text("Error: \(error.code) – \(error.message)")
                        .foregroundStyle(.red)
                }
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
                ScrollView {
                    Text(viewModel.logsForSelectedSession())
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 220)
            } else {
                Text("Select a session to inspect artifacts, logs, and retry state.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
