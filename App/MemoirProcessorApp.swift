import SwiftUI
import MemoirProcessorCore

@main
struct MemoirProcessorApp: App {
    @StateObject private var viewModel = AppViewModel()

    @StateObject private var updater = AppUpdater(isBusy: {
        guard let config = try? ConfigStore().load(), let store = try? SessionStore(config: config), let sessions = try? store.listSessions() else { return true }
        return sessions.contains { [.validating, .transcribing, .diarizing, .writingArtifacts].contains($0.processingState) }
    }, prepareForInstall: { UpdateServiceLifecycle.prepareForInstall() })

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel, updater: updater)
                .frame(minWidth: 760, minHeight: 440)
                .containerBackground(ThreadTheme.paper, for: .window)
        }
        .defaultSize(width: 1080, height: 680)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .appInfo) { CheckForUpdatesView(updater: updater) }
        }
    }
}

