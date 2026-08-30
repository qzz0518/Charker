import AppKit
import CharkerCore
import SwiftUI

/// Physical cable state. `nil` keeps "not reported" distinct from a confirmed
/// empty port and prevents the digital twin from inventing a cable.
struct DigitalTwinCableState: Equatable {
    let attached: Bool?
    let capability: String?

    static let unknown = DigitalTwinCableState(attached: nil, capability: nil)
}

enum DigitalTwinLoadState: Equatable {
    case loading
    case ready
    case failed
}

/// Native SceneKit/Metal host for the overview's three-dimensional device.
/// Telemetry stays in Swift and is applied directly to SceneKit nodes—there is
/// no WebKit process, JavaScript bridge, DOM overlay, or CSS cursor involved.
struct DigitalTwinStage: View {
    var portWatts: [Double]
    var portsLit: [Bool]
    var portCables: [DigitalTwinCableState]
    var totalWatts: Double
    var active: Bool
    var highlightedPort: Int?
    var selectedPort: Int?
    @Binding var homeCamera: ModelCameraPose?
    @Binding var screenStyle: ModelScreenStyle
    var customScreenImage: NSImage?
    var screenArtworkRevision: Int
    var onPortTap: (Int) -> Void
    var onPortHover: (Int?) -> Void
    var height: CGFloat = 308

    @State private var loadState: DigitalTwinLoadState = .loading
    @State private var resetGeneration = 0
    @State private var captureGeneration = 0
    @State private var reloadID = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            stageBackground

            if loadState == .failed {
                fallback
                    .transition(.opacity)
            } else {
                NativeChargerSceneView(
                    portWatts: portWatts,
                    portsLit: portsLit,
                    portCables: portCables,
                    totalWatts: totalWatts,
                    active: active,
                    highlightedPort: highlightedPort,
                    selectedPort: selectedPort,
                    reduceMotion: reduceMotion,
                    homeCamera: homeCamera,
                    screenStyle: screenStyle,
                    customScreenImage: customScreenImage,
                    screenArtworkRevision: screenArtworkRevision,
                    resetGeneration: resetGeneration,
                    captureGeneration: captureGeneration,
                    loadState: $loadState,
                    onPortTap: onPortTap,
                    onPortHover: onPortHover,
                    onCameraCapture: { homeCamera = $0 }
                )
                .id(reloadID)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous))
        .overlay(alignment: .topLeading) {
            if loadState == .loading { loadingBadge }
        }
        .overlay(alignment: .topLeading) {
            if loadState == .ready { interactionHint }
        }
        .overlay(alignment: .topTrailing) {
            if loadState == .ready { cameraSettingsMenu }
        }
        .overlay(alignment: .bottomTrailing) {
            if loadState == .ready { resetButton }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous)
                .strokeBorder(Palette.stroke, lineWidth: Stroke.hairline)
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.20), value: loadState)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("充电器三维数字孪生"))
    }

    private var stageBackground: some View {
        LinearGradient(
            colors: [Palette.well, Palette.surfaceElevated],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var loadingBadge: some View {
        HStack(spacing: Space.s) {
            ProgressView().controlSize(.mini)
            Text("载入原生三维设备")
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, 5)
        .background(Capsule().fill(Palette.well.opacity(0.88)))
        .padding(Space.m)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private var interactionHint: some View {
        Label("拖动旋转 · 滚轮或捏合缩放 · 点击端口", systemImage: "move.3d")
            .font(Typo.micro)
            .foregroundStyle(Palette.textTertiary)
            // Match the visible height of the two quiet camera actions so all
            // three labels share one optical centre line across the stage.
            .frame(height: 22)
            .padding(Space.m)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    private var resetButton: some View {
        Button {
            resetGeneration += 1
        } label: {
            Label("归位", systemImage: "view.3d")
                .font(Typo.micro)
        }
        .buttonStyle(GhostButtonStyle())
        .help("恢复保存的归位视角与缩放")
        .padding(Space.m)
        .transition(.opacity)
    }

    private var cameraSettingsMenu: some View {
        Menu {
            Button {
                captureGeneration += 1
            } label: {
                Label("将当前视角设为归位", systemImage: "bookmark.fill")
            }

            Button {
                homeCamera = nil
                resetGeneration += 1
            } label: {
                Label("恢复初始归位视角", systemImage: "arrow.counterclockwise")
            }
            .disabled(homeCamera == nil)
        } label: {
            Label("设定", systemImage: homeCamera == nil ? "viewfinder" : "bookmark.fill")
                .font(Typo.micro)
        }
        .menuIndicator(.hidden)
        .buttonStyle(GhostButtonStyle())
        .help("设置归位视角与缩放")
        .accessibilityLabel(Text(L10n.text(
            homeCamera == nil ? "设定归位视角" : "自定义归位视角已启用"
        )))
        .padding(Space.m)
        .transition(.opacity)
    }

    private var fallback: some View {
        VStack(spacing: Space.s) {
            Group {
                if let art = ProductArt.image {
                    Image(nsImage: art)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .saturation(active ? 0.8 : 0.35)
                } else {
                    ChargerFigure(
                        portsLit: active ? portsLit : [false, false, false],
                        totalFraction: active ? totalWatts / 160 : 0,
                        height: height * 0.54
                    )
                }
            }
            .frame(height: height * 0.58)

            Text("原生三维视图暂不可用，实时数据不受影响")
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
            Button("重新载入") {
                loadState = .loading
                reloadID = UUID()
            }
            .buttonStyle(GhostButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, Space.l)
    }
}
