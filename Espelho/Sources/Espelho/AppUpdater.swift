import AppKit
import Combine
import Sparkle
import SwiftUI

/// In-app updates through Sparkle, like the other witchmymac apps. The feed (SUFeedURL), the EdDSA
/// public key (SUPublicEDKey) and the daily check are in the Info.plist written by the release script.
/// Copies built for this Mac only (scripts/make-espelho-app.sh) have no feed and don't check.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    /// False while a check or an install is already under way, or when updates are off.
    @Published private(set) var canCheckForUpdates = false

    private var controller: SPUStandardUpdaterController?
    private var canCheckObservation: NSKeyValueObservation?

    private init() {}

    var isAvailable: Bool { Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil }

    /// Starts Sparkle's scheduler (daily check). Call once at launch.
    func start() {
        guard controller == nil, isAvailable else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let canCheck = updater.canCheckForUpdates
            DispatchQueue.main.async { self?.canCheckForUpdates = canCheck }
        }
        controller.startUpdater()
    }

    /// "Procurar Atualizações…": always shows a result, even "you're up to date".
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        Button("Procurar Atualizações…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
