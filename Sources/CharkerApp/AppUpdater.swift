import Combine
import Foundation
import Sparkle

/// Owns Sparkle for both the app menu and About page.
///
/// `swift run Charker` has no assembled Info.plist or app bundle, so starting
/// Sparkle there would create a misleading updater error during simulator-only
/// development. The release bundle carries `SUFeedURL` and starts normally.
@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController
    private let isConfigured: Bool
    private var canCheckObserver: AnyCancellable?

    init(bundle: Bundle = .main) {
        isConfigured = bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil
        controller = SPUStandardUpdaterController(
            startingUpdater: isConfigured,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        guard isConfigured else { return }
        canCheckForUpdates = controller.updater.canCheckForUpdates
        canCheckObserver = controller.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] canCheck in
                self?.canCheckForUpdates = canCheck
            }
    }

    func checkForUpdates() {
        guard isConfigured else { return }
        controller.checkForUpdates(nil)
    }
}
