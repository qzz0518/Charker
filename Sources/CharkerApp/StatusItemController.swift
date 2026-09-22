import AppKit
import CharkerCore
import Combine
import SwiftUI

/// Owns the menu bar item, its popover and its context menu.
///
/// The title is only pushed to AppKit when the rendered string actually changes,
/// so a once-a-second telemetry stream does not thrash the menu bar layout.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    /// One hosting controller for the popover's whole life, its root view
    /// swapped between the readout (open) and an EmptyView (closed). Nil-ing
    /// `contentViewController` on close could drop the content view while the
    /// close animation still ran it, and rebuilding the controller per open
    /// paid the AppKit hosting setup on every click.
    private let hosting: NSHostingController<AnyView>
    private let model: AppModel
    private let openMainWindow: () -> Void
    private var cancellables = Set<AnyCancellable>()
    private var lastTitle: String?
    private var lastSymbol: String?
    private var lastToolTip: String?
    /// Transient popovers dismiss on the mouse-DOWN of the very status-item
    /// click whose mouse-UP would then re-show them. The close timestamp is how
    /// "click to dismiss" actually dismisses.
    private var popoverClosedAt = Date.distantPast

    init(model: AppModel, openMainWindow: @escaping () -> Void) {
        self.model = model
        self.openMainWindow = openMainWindow
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        hosting = NSHostingController(rootView: AnyView(EmptyView()))
        super.init()

        popover.behavior = .transient
        // Assigned once, here — the show path only touches rootView.
        popover.contentViewController = hosting
        popover.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }

        // Only the inputs the status item actually renders. Subscribing to
        // objectWillChange redrew the title for every keystroke in every text
        // field, and RunLoop.main delivery froze updates during menu tracking.
        model.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        model.$a2345Snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        model.$preferences
            // Joined into one change-key: tuples stop synthesising == beyond
            // six elements, and the title depends on all seven of these.
            .map {
                [
                    $0.menuBarItemsJSON, String($0.decimals), String($0.hideIdlePorts),
                    String($0.showIconOnly), String($0.showsMenuBarIcon), $0.menuBarIconSymbol,
                    $0.portNicknames.joined(separator: "\u{1F}"), $0.connectionMode,
                    $0.demoProduct.rawValue, String($0.demoMode),
                    // `{device}` shows a saved charger's own name.
                    $0.savedChargers.map { "\($0.id.uuidString)=\($0.nickname)" }
                        .joined(separator: "\u{1F}"),
                ].joined(separator: "\u{1E}")
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        refresh()
    }

    private func refresh() {
        guard let button = statusItem.button else { return }
        let title = model.statusTitle
        if title != lastTitle {
            lastTitle = title
            // Tabular figures keep the width steady as the wattage changes.
            button.attributedTitle = NSAttributedString(
                string: title.isEmpty ? "" : " \(title)",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(
                        ofSize: NSFont.systemFontSize(for: .small), weight: .regular
                    ),
                ]
            )
        }
        // "" is the sentinel for a hidden image; a real symbol name never is.
        let symbol = model.statusShowsIcon ? model.statusSymbolName : ""
        if symbol != lastSymbol {
            lastSymbol = symbol
            if symbol.isEmpty {
                button.image = nil
            } else {
                let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Charker")
                image?.isTemplate = true
                button.image = image
            }
        }
        let toolTip = L10n.format("Charker · %@", model.activeStatusDetail)
        if toolTip != lastToolTip {
            lastToolTip = toolTip
            button.toolTip = toolTip
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        // An accessibility press (VoiceOver, AXPress) has no current event —
        // bailing out on nil made the readout unopenable for exactly those users.
        let event = NSApp.currentEvent
        if let event, event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
        } else {
            togglePopover(sender)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        // Only a close caused by a click on the status button itself needs the
        // reopen guard. Stamping every close (Esc, 打开主窗口, focus loss) made
        // the icon dead for 250ms afterwards — a swallowed legitimate click.
        let event = NSApp.currentEvent
        let closedByStatusClick = event.map { candidate in
            (candidate.type == .leftMouseDown || candidate.type == .leftMouseUp)
                && candidate.window === statusItem.button?.window
        } ?? false
        popoverClosedAt = closedByStatusClick ? Date() : .distantPast
        // The readout lives only while visible: a closed popover keeps its
        // _NSPopoverWindow, so a retained MenuBarReadout kept observing the
        // model and re-rendered the sparkline and three port rows on every
        // telemetry publish. It showed up in a sample with the popover closed.
        // didClose fires after the close animation has finished, so swapping
        // the root view here does not touch a view that is still animating out.
        hosting.rootView = AnyView(EmptyView())
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // The transient dismissal already ran on this click's mouse-down; showing
        // again on its mouse-up would make the icon impossible to close with.
        guard Date().timeIntervalSince(popoverClosedAt) > 0.25 else { return }
        // The rebuild lives here, not in statusItemClicked — that also fires
        // for right-clicks (routed to showMenu) and for clicks the reopen
        // guard above swallows.
        hosting.rootView = AnyView(MenuBarReadout(model: model, openMainWindow: { [weak self] in
            self?.popover.performClose(nil)
            self?.openMainWindow()
        }))
        // Re-read reduce-motion every time; the user can toggle it while we run.
        popover.animates = !Motion.systemReducesMotion
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        // Key the popover's own window rather than activating the app — a glance
        // at the readout must not yank the main window above other apps.
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: model.activeStatusDetail, action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        add(to: menu, L10n.text("打开主窗口"), #selector(openWindow), "o")
        if !model.usesA2345 {
            add(to: menu, L10n.text("重新连接"), #selector(reconnect), "r")
            addChargerSwitcher(to: menu)
        } else if model.a2345Snapshot.isDemo {
            add(to: menu, L10n.text("退出模拟"), #selector(exitDemo), "")
        } else if model.canRetryA2345 {
            add(to: menu, L10n.text("重新连接"), #selector(reconnect), "r")
        } else {
            add(to: menu, a2345ConnectionActionTitle, #selector(openConnection), "r")
        }
        menu.addItem(.separator())
        add(to: menu, L10n.text("退出 Charker"), #selector(quit), "q")

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// Two saved chargers in range at once is the one case automatic
    /// reconnection cannot settle for the user; this puts the choice one
    /// right-click away.
    private func addChargerSwitcher(to menu: NSMenu) {
        let chargers = model.savedChargersInUseOrder
        guard !model.preferences.demoMode, chargers.count > 1 else { return }
        let blocked = model.chargerSwitchBlocker != nil
        let submenu = NSMenu()
        for charger in chargers {
            let item = NSMenuItem(
                title: charger.displayName,
                action: blocked ? nil : #selector(switchCharger(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = charger.id
            item.state = charger.id == model.snapshot.peripheralID ? .on : .off
            submenu.addItem(item)
        }
        let parent = NSMenuItem(title: L10n.text("切换充电器"), action: nil, keyEquivalent: "")
        parent.submenu = submenu
        menu.addItem(parent)
    }

    @objc private func switchCharger(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        model.connect(to: id)
    }

    private func add(to menu: NSMenu, _ title: String, _ action: Selector, _ key: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    private var a2345ConnectionActionTitle: String {
        guard model.supportsA2345Cloud else { return L10n.text("查看系统要求") }
        return model.hasRememberedCharger
            ? L10n.text("查看连接状态")
            : L10n.text("登录并连接")
    }

    @objc private func reconnect() {
        if model.usesA2345 {
            model.retryA2345Connection()
        } else {
            model.reconnect()
        }
    }
    @objc private func exitDemo() { model.exitDemoMode() }
    @objc private func openConnection() {
        model.selectedSection = .devices
        openMainWindow()
    }
    @objc private func openWindow() { openMainWindow() }
    @objc private func quit() { NSApp.terminate(nil) }
}
