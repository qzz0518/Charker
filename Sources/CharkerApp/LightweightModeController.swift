import Darwin
import Foundation

/// Drops the main window's interface after it has stayed closed for a minute.
///
/// A closed SwiftUI `Window` keeps its hosting view, and with it the whole
/// overview: text layout caches, charts and the retained SceneKit stages. The
/// status item and the charger session do not need any of that, so the window
/// content is replaced with a clear view and the native caches are released.
/// Reopening rebuilds the page; the one-off model load is the price of the much
/// smaller background footprint.
@MainActor
final class LightweightModeController {
    private let model: AppModel
    private let delay: TimeInterval
    private var pendingEntry: DispatchWorkItem?

    init(model: AppModel, delay: TimeInterval = 60) {
        self.model = model
        self.delay = delay
        // Every path that shows or loses the window goes through this flag, and
        // it turns true before the window is ordered in, so the page is back
        // by the time it is on screen.
        model.mainWindowIsOpenDidChange = { [weak self] isOpen in
            if isOpen { self?.leave() } else { self?.scheduleEntry() }
        }
    }

    private func leave() {
        pendingEntry?.cancel()
        pendingEntry = nil
        model.exitLightweightMode()
    }

    private func scheduleEntry() {
        pendingEntry?.cancel()
        let entry = DispatchWorkItem { [weak self] in self?.enter() }
        pendingEntry = entry
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: entry)
    }

    private func enter() {
        pendingEntry = nil
        guard !model.mainWindowIsOpen,
              model.preferences.lightweightModeEnabled else { return }

        model.enterLightweightMode()
        // SwiftUI commits the content swap on the next main runloop. Release
        // the native caches after that commit, then ask malloc to return the
        // freed pages. Doing either earlier would only free what the outgoing
        // view still retains.
        DispatchQueue.main.async {
            // A reopen can land before this pass. Never tear the caches out
            // from under a window that is on its way back.
            guard self.model.isLightweightMode else { return }
            autoreleasepool {
                NativeChargerSceneView.releaseCachedResources()
                A2345ModelStage.releaseCachedResources()
            }
            _ = malloc_zone_pressure_relief(nil, 0)
            self.model.recordDiagnostic("UI", "lightweight mode: released the main window")
        }
    }
}
