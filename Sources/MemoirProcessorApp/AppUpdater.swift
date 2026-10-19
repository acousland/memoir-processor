import AppKit
import Combine
import Sparkle
import SwiftUI

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published var canCheckForUpdates = false
    private var controller: SPUStandardUpdaterController!
    private let isBusy: () -> Bool
    private let prepareForInstall: () -> Bool
    private var delayedInstall: (() -> Void)?
    private var timer: Timer?

    init(isBusy: @escaping () -> Bool, prepareForInstall: @escaping () -> Bool = { true }) {
        self.isBusy = isBusy
        self.prepareForInstall = prepareForInstall
        super.init()
        // Swift package tests run outside a signed application bundle.
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        controller.startUpdater()
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard isBusy() || !prepareForInstall() else { return false }
        delayedInstall = installHandler
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isBusy(), self.prepareForInstall() else { return }
                self.timer?.invalidate()
                self.timer = nil
                let install = self.delayedInstall
                self.delayedInstall = nil
                install?()
            }
        }
        return true
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
