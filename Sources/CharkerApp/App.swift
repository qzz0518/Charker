import AppKit
import CharkerCore
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
                .frame(minWidth: 820, minHeight: 520)
        }
        // 969 × 882 reproduces the comfortable 969 × 914 window frame chosen
        // during live review: the overview keeps its two-column instrument and
        // remains a one-screen canvas without carrying unnecessary width.
        // AppKit adds the compact 32 pt title bar outside this content size.
        // This remains only the first/new-window default; macOS should continue
        // restoring a user's later resize rather than fighting it on launch.
        .defaultSize(width: 969, height: 882)
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
            // Device actions belong in their own menu, not the app menu.
            CommandMenu("设备") {
                Button("重新连接充电器") { appDelegate.model.reconnect() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("重新扫描附近设备") {
                    Self.select(.devices, in: appDelegate.model)
                    appDelegate.model.browse()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let mainWindowID = "main"

    let model = AppModel()
    private var statusItem: StatusItemController?

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
        model.start()
    }

    /// Quit waits (briefly) for the BLE goodbye: the charger stops advertising
    /// while it thinks a client still holds it, so a dropped-not-closed link
    /// delays it reappearing for other clients. Capped in `shutdown()` so a hung
    /// transport can never wedge quitting.
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
