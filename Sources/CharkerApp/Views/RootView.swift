import Accessibility
import AppKit
import CharkerCore
import SwiftUI

struct RootView: View {
    @ObservedObject var model: AppModel
    @Namespace private var sidebarSelection
    @State private var deviceChipHovering = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if model.needsInitialSetup {
                InitialSetupView(model: model)
                    .toolbarBackground(.hidden, for: .windowToolbar)
            } else {
                NavigationSplitView {
                    sidebar
                        .navigationSplitViewColumnWidth(min: 196, ideal: 208, max: 240)
                } detail: {
                    detail
                        .frame(minWidth: 600, minHeight: 460)
                        // The default toolbar material drew a mismatched band over the
                        // slate; hide it and let the page background run to the top.
                        .toolbarBackground(.hidden, for: .windowToolbar)
                }
            }
        }
        .navigationTitle("")
        .frame(minWidth: 820, minHeight: 520)
        .background(Palette.bg)
        // One saturated hue in the whole app — that includes system controls.
        .tint(Palette.accent)
        .onAppear {
            // Bridges scene re-creation to AppKit: the status item and Dock menu
            // need a way to reopen this window after the user closes it.
            model.openMainWindowAction = { openWindow(id: AppDelegate.mainWindowID) }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            deviceChip
                .padding(.horizontal, Space.m)
                .padding(.top, Space.m)
                .padding(.bottom, Space.m)

            ForEach(AppModel.Section.allCases) { section in
                SidebarRow(
                    section: section,
                    isSelected: model.selectedSection == section,
                    namespace: sidebarSelection,
                    select: { select(section) }
                )
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, Space.s)
        .padding(.bottom, Space.m)
        .background(VibrancyBacking(material: .sidebar).ignoresSafeArea())
    }

    private func select(_ section: AppModel.Section) {
        guard model.selectedSection != section else { return }
        withAnimation(Motion.reduced(Motion.ui, reduceMotion)) {
            model.selectedSection = section
        }
    }

    /// Doubles as a shortcut to the connection page — a bordered chip that does
    /// nothing on click reads as broken.
    private var deviceChip: some View {
        Button {
            select(.devices)
        } label: {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.s) {
                    AnkerBrandMark()
                    Spacer(minLength: Space.xs)
                    if model.usesA2345 {
                        A2345CompactConnectionStatus(
                            phase: model.a2345Snapshot.phase,
                            stale: model.a2345Snapshot.isStale,
                            isDemo: model.a2345Snapshot.isDemo,
                            label: model.activeStatusLabel
                        )
                    } else {
                        CompactConnectionStatus(phase: model.snapshot.phase)
                    }
                }

                HStack(spacing: Space.s) {
                    Text(deviceTitle)
                        .font(Typo.label)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.86)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Palette.textTertiary)
                        .opacity(deviceChipHovering ? 0.9 : 0.45)
                        .offset(x: deviceChipHovering && !reduceMotion ? 1 : 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous)
                    .fill(
                        deviceChipHovering
                            ? Palette.surfaceRaised.opacity(0.82)
                            : Palette.surfaceElevated.opacity(0.6)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous)
                    .strokeBorder(
                        deviceChipHovering ? Palette.strokeStrong : Palette.stroke,
                        lineWidth: Stroke.hairline
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L10n.format("%@，%@", deviceTitle, model.activeStatusLabel)))
        .onHover { deviceChipHovering = $0 }
        .animation(Motion.reduced(Motion.ui, reduceMotion), value: deviceChipHovering)
        .help("打开「设备与连接」")
    }

    private var deviceTitle: String {
        if model.preferences.demoMode {
            return model.activeProduct == .a2345
                ? L10n.text("模拟 Prime 250W")
                : L10n.text("模拟 Prime 160W")
        }
        let fallback = model.hasRememberedCharger
            ? L10n.text("未连接")
            : L10n.text("查找充电器")
        let name = model.activeDisplayName ?? fallback
        let prefix = "Anker "
        guard name.hasPrefix(prefix), name.count > prefix.count else { return name }
        return String(name.dropFirst(prefix.count))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if model.preferences.demoMode {
                HStack(spacing: Space.s) {
                    Chip(text: L10n.text("演示模式"), tone: .accent)
                    Button {
                        model.exitDemoMode()
                    } label: {
                        Label("退出", systemImage: "xmark.circle")
                            .font(Typo.micro)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.text("退出模拟并查找真实充电器"))
                }
            }
            Text(model.versionText.map { L10n.format("Charker %@", $0) } ?? L10n.text("Charker 开发构建"))
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(.horizontal, Space.m)
    }

    private var sectionTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .opacity.combined(with: .offset(y: 6)),
                removal: .opacity
            )
    }

    @ViewBuilder
    private var detail: some View {
        ZStack {
            switch model.selectedSection {
            case .dashboard:
                if model.usesA2345 {
                    A2345DashboardView(model: model).transition(sectionTransition)
                } else {
                    DashboardView(model: model).transition(sectionTransition)
                }
            case .energy: EnergyHistoryView(model: model).transition(sectionTransition)
            case .devices:
                if model.usesA2345 {
                    A2345DevicesView(model: model).transition(sectionTransition)
                } else {
                    DevicesView(model: model).transition(sectionTransition)
                }
            case .menuBar: MenuBarSettingsView(model: model).transition(sectionTransition)
            case .advanced: AdvancedView(model: model).transition(sectionTransition)
            case .about: AboutView(model: model).transition(sectionTransition)
            }
        }
        .background(Palette.bg.ignoresSafeArea())
        // Transient transport feedback floats above the page instead of
        // inserting/removing layout space and making the whole dashboard jump.
        .overlay(alignment: .top) {
            if model.usesA2345, let message = model.lastActionMessage {
                actionMessageNotice(message)
                    .padding(.horizontal, Space.xxl)
                    .padding(.vertical, Space.s)
                    .transition(actionMessageTransition)
                    .zIndex(2)
            }
        }
        .animation(Motion.reduced(Motion.ui, reduceMotion), value: model.lastActionMessage)
        .onChange(of: model.lastActionMessage) { _, message in
            guard NSApp.isActive, model.usesA2345, let message else { return }
            AccessibilityNotification.Announcement(message).post()
        }
        .onChange(of: model.a2345Snapshot) { oldSnapshot, snapshot in
            announceA2345Change(from: oldSnapshot, to: snapshot)
        }
    }

    /// Announce milestones, not the transport's implementation ladder. One
    /// snapshot comparison also prevents a fresh frame from speaking both
    /// “connected” and “data restored” when phase and freshness change together.
    private func announceA2345Change(
        from oldSnapshot: A2345ConnectionSnapshot,
        to snapshot: A2345ConnectionSnapshot
    ) {
        guard NSApp.isActive, model.usesA2345 else { return }

        if oldSnapshot.phase != snapshot.phase {
            switch snapshot.phase {
            case .waitingForTelemetry, .monitoring, .failed:
                AccessibilityNotification.Announcement(
                    "\(snapshot.phase.shortLabel)。\(snapshot.phase.detail)"
                ).post()
                return
            case .reconnecting:
                if case .reconnecting = oldSnapshot.phase { return }
                AccessibilityNotification.Announcement(
                    "\(snapshot.phase.shortLabel)。\(snapshot.phase.detail)"
                ).post()
                return
            case .idle, .signingIn, .loadingDevices, .connecting:
                break
            }
        }

        guard oldSnapshot.phase == .monitoring,
              snapshot.phase == .monitoring,
              oldSnapshot.isStale != snapshot.isStale else { return }
        AccessibilityNotification.Announcement(
            snapshot.isStale ? L10n.text("数据已陈旧") : L10n.text("实时数据已恢复")
        ).post()
    }

    private var actionMessageTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .offset(y: -6))
    }

    private func actionMessageNotice(_ message: String) -> some View {
        SlateCard(padding: Space.m) {
            HStack(alignment: .top, spacing: Space.m) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(Palette.accentText)
                    .accessibilityHidden(true)
                Text(message)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .cjkParagraph(11, target: 1.5)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    model.dismissActionMessage()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.textTertiary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Palette.well))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.text("关闭")))
            }
        }
        .frame(maxWidth: 1040)
        .accessibilityElement(children: .contain)
    }
}

/// The supplied Anker wordmark, kept compact so it reads as manufacturer
/// provenance rather than competing with the live device name and status.
private struct AnkerBrandMark: View {
    var body: some View {
        Group {
            if let logo = BrandAssets.ankerLogo {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Text("ANKER")
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .tracking(0.3)
                    .foregroundStyle(Palette.accentText)
            }
        }
        .frame(width: 42, height: 10, alignment: .leading)
        .opacity(0.82)
        .accessibilityHidden(true)
    }
}

private struct CompactConnectionStatus: View {
    let phase: SessionPhase

    var body: some View {
        HStack(spacing: Space.xs) {
            StateDot(phase: phase, diameter: 6, glowsWhenLive: false)
            Text(phase.shortLabel)
                .font(Typo.caption.weight(.medium))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct A2345CompactConnectionStatus: View {
    let phase: A2345ConnectionPhase
    let stale: Bool
    let isDemo: Bool
    let label: String

    var body: some View {
        let tone = A2345StateTone(phase: phase, stale: stale, isDemo: isDemo)
        HStack(spacing: Space.xs) {
            A2345StateDot(
                phase: phase,
                stale: stale,
                isDemo: isDemo,
                diameter: 6,
                glowsWhenLive: false
            )
            Text(label)
                .font(Typo.caption.weight(.medium))
                .foregroundStyle(tone.labelColor)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct SidebarRow: View {
    let section: AppModel.Section
    let isSelected: Bool
    let namespace: Namespace.ID
    let select: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: select) {
            HStack(spacing: Space.m) {
                Image(systemName: section.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(isSelected ? Palette.accentText : Palette.textSecondary)
                Text(section.title)
                    .font(Typo.body)
                    .foregroundStyle(isSelected ? Palette.textPrimary : Palette.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .background {
                // One pill, sliding between rows, instead of five that fade.
                if isSelected {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(Palette.accentWash)
                        .matchedGeometryEffect(id: "sidebar-pill", in: namespace)
                } else if hovering {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(Palette.surfaceRaised.opacity(0.6))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.reduced(Motion.ui, reduceMotion), value: hovering)
    }
}
