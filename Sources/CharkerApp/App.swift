import AppKit
import CharkerCore
import Combine
import SwiftUI

/// A normal Mac app: Dock icon, a real window, and a menu bar readout that is one
/// feature among several rather than the whole product.
///
/// The status item stays AppKit. `MenuBarExtra` cannot render the variable-width,
/// tabular-figure title that updates once a second without the menu bar visibly
/// reflowing, and that readout is the point of it.
@main
struct CharkerMainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var updater = AppUpdater()

    init() {
        // Earliest usable hook. `NSApp` really is nil here, but
        // `NSApplication.shared` instantiates it and the policy sticks; doing this
        // in applicationDidFinishLaunching instead lets a Dock tile flash first.
        NSApplication.shared.setActivationPolicy(
            PreferencesStore().load().showDockIcon ? .regular : .accessory
        )
    }

    /// Section switches from the menu bar animate like sidebar clicks do — the
    /// detail transition lives in the transaction, so a bare assignment snaps.
    @MainActor
    private static func select(_ section: AppModel.Section, in model: AppModel) {
        withAnimation(Motion.reduced(Motion.ui, Motion.systemReducesMotion)) {
            model.selectedSection = section
        }
    }

    var body: some Scene {
        Window("Charker", id: AppDelegate.mainWindowID) {
            RootView(model: appDelegate.model)
                .environmentObject(updater)
        }
        // Only the very first window uses this; AppDelegate then grows it to
        // the product's comfortable size, capped by the screen.
        .defaultSize(MainWindowSizing.comfortable(for: .a2687))
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("检查更新…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            // ⌘, is muscle memory; the app's settings live in the main window.
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    Self.select(.menuBar, in: appDelegate.model)
                    appDelegate.openMainWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            DeviceCommands(
                model: appDelegate.model,
                openMainWindow: { appDelegate.openMainWindow() }
            )
            // ⌘1–⌘6 jump between sidebar sections, macOS-tab style.
            CommandGroup(after: .sidebar) {
                Divider()
                ForEach(Array(AppModel.Section.allCases.enumerated()), id: \.element) { index, section in
                    Button(section.title) {
                        Self.select(section, in: appDelegate.model)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
            CommandGroup(after: .help) {
                Divider()
                Button("关注 @zerah_eth") {
                    guard let profileURL = URL(string: "https://x.com/zerah_eth") else { return }
                    NSWorkspace.shared.open(profileURL)
                }
            }
        }
    }
}

/// Keeps the device menu subscribed to product/auth changes. Reading the model
/// directly from `App.body` produced a one-time title and left a dead reconnect
/// action visible when an A2345 account had not been saved yet.
private struct DeviceCommands: Commands {
    @ObservedObject var model: AppModel
    let openMainWindow: () -> Void

    var body: some Commands {
        CommandMenu("设备") {
            if !model.usesA2345 {
                Button("重新连接充电器") { model.reconnect() }
                    .keyboardShortcut("r", modifiers: .command)
            } else if model.a2345Snapshot.isDemo {
                Button("退出模拟") { model.exitDemoMode() }
                    .keyboardShortcut("r", modifiers: .command)
            } else if model.canRetryA2345 {
                Button("重新连接充电器") { model.retryA2345Connection() }
                    .keyboardShortcut("r", modifiers: .command)
            } else {
                Button(a2345ConnectionActionTitle) { showConnection() }
                    .keyboardShortcut("r", modifiers: .command)
            }

            if !model.usesA2345 || model.canRetryA2345 {
                Button(L10n.text(model.usesA2345 ? "打开云端连接" : "重新扫描附近设备")) {
                    selectDevices()
                    if !model.usesA2345 { model.browse() }
                    openMainWindow()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }

    private var a2345ConnectionActionTitle: String {
        guard model.supportsA2345Cloud else { return L10n.text("查看系统要求") }
        return model.hasRememberedCharger
            ? L10n.text("查看连接状态")
            : L10n.text("登录并连接")
    }

    private func showConnection() {
        selectDevices()
        openMainWindow()
    }

    private func selectDevices() {
        withAnimation(Motion.reduced(Motion.ui, Motion.systemReducesMotion)) {
            model.selectedSection = .devices
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let mainWindowID = "main"

    let model = AppModel()
    private var statusItem: StatusItemController?
    private var sizingObservers: [AnyCancellable] = []
    /// The window instance last fitted on opening; a reopened scene is a new one.
    private weak var fittedWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The charger accepts one client and stops advertising while held, so a
        // second copy of Charker would make the charger invisible to both.
        let others = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
        ).filter { $0 != .current }
        if !others.isEmpty {
            others.first?.activate()
            NSApp.terminate(nil)
            return
        }
        // A dev build run straight from the repo has no bundle and would show
        // the generic executable icon in the Dock and app switcher; hand AppKit
        // the real one.
        if Bundle.main.bundleIdentifier == nil, let icon = AppIconImage.image {
            NSApp.applicationIconImage = icon
        }
        statusItem = StatusItemController(model: model, openMainWindow: { [weak self] in
            self?.openMainWindow()
        })
        observeWindowSizing()
        model.start()
    }

    /// Opens every main window at a size where the overview and 设备与连接
    /// need no scrolling, and grows it again when the product changes.
    private func observeWindowSizing() {
        model.mainWindowDidOpen = { [weak self] window in
            self?.fitOnOpen(window)
        }
        // Fallback for a window whose content attached before the restored
        // frame settled; fitting is once per window instance either way.
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .compactMap { $0.object as? NSWindow }
            .sink { [weak self] window in self?.fitOnOpen(window) }
            .store(in: &sizingObservers)
        // `$preferences` fires before the new value is stored, so the product
        // is derived from the emitted value rather than read back.
        model.$preferences
            .map(AppModel.product(for:))
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] product in
                guard let window = self?.mainWindow(), window.isVisible else { return }
                MainWindowSizing.fit(window, for: product, exact: true, animate: true)
            }
            .store(in: &sizingObservers)
    }

    /// Quit waits (briefly) for the BLE goodbye: the charger stops advertising
    /// while it thinks a client still holds it, so a dropped-not-closed link
    /// delays it reappearing for other clients. Capped in `shutdown()` so a hung
    /// transport can never wedge quitting.
    private func fitOnOpen(_ window: NSWindow) {
        guard window.identifier?.rawValue.hasPrefix(Self.mainWindowID) == true,
              fittedWindow !== window else { return }
        fittedWindow = window
        // The first launch of this sizing opens at the overview's size once,
        // whatever an older version left behind; after that a window the user
        // made larger stays larger.
        let defaults = UserDefaults.standard
        let exact = defaults.integer(forKey: Self.windowSizingVersionKey) < Self.windowSizingVersion
        defaults.set(Self.windowSizingVersion, forKey: Self.windowSizingVersionKey)
        let before = window.frame
        MainWindowSizing.fit(window, for: model.activeProduct, exact: exact, animate: false)
        model.recordDiagnostic(
            "UI",
            String(
                format: "main window %.0fx%.0f -> %.0fx%.0f (%@)",
                before.width, before.height, window.frame.width, window.frame.height,
                exact ? "exact" : "grow"
            )
        )
    }

    private static let windowSizingVersionKey = "mainWindowSizingVersion"
    private static let windowSizingVersion = 2

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await model.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// DO NOT REMOVE. With a `Window` scene and an AppKit `NSStatusItem` — and no
    /// `MenuBarExtra` scene — closing the main window terminates the process and
    /// takes the menu bar readout with it. A status item does not keep a SwiftUI
    /// app alive on its own. Measured: without this override the process is gone
    /// one close-button click after launch.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { openMainWindow() }
        return true
    }

    func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = mainWindow() {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // The scene was closed. RootView bridges @Environment(\.openWindow) into
        // the model on first render — the supported way to re-materialise a
        // SwiftUI Window — with the legacy responder-chain poke as the fallback
        // for the never-rendered edge case.
        if let openWindow = model.openMainWindowAction {
            openWindow()
        } else {
            NSApp.sendAction(#selector(NSWindow.newWindowForTab(_:)), to: nil, from: nil)
        }
        mainWindow()?.makeKeyAndOrderFront(nil)
    }

    private func mainWindow() -> NSWindow? {
        NSApp.windows.first {
            $0.identifier?.rawValue.hasPrefix(Self.mainWindowID) == true
        }
    }
}
